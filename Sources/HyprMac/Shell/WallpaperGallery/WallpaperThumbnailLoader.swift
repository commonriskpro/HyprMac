import Cocoa
import CoreGraphics
import ImageIO
import CryptoKit

/// Opaque cancellation token allowing callers to cancel pending thumbnail requests
public final class ThumbnailCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var onCancel: (() -> Void)?

    init(onCancel: (() -> Void)? = nil) {
        self.onCancel = onCancel
    }

    public func cancel() {
        lock.lock()
        let handler = onCancel
        let alreadyCancelled = isCancelled
        isCancelled = true
        onCancel = nil
        lock.unlock()

        if !alreadyCancelled {
            handler?()
        }
    }

    public var isCanceled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }
}

/// High-performance asynchronous thumbnail loader with bounded concurrency,
/// in-flight deduplication, cancellation tokens, byte-budgeted memory cache, and persistent disk cache.
public final class WallpaperThumbnailLoader: @unchecked Sendable {
    public static let shared = WallpaperThumbnailLoader()

    public typealias CompletionHandler = @MainActor (NSImage?) -> Void

    private let memoryCache = NSCache<NSString, NSImage>()
    private let operationQueue = OperationQueue()
    private let lock = NSLock()
    public let diskCacheDirectory: String

    private struct InFlightRequest {
        let operation: Operation
        var callbacks: [UUID: CompletionHandler]
    }
    private var inFlightRequests: [String: InFlightRequest] = [:]

    public init(maxConcurrentOperations: Int = 4, memoryByteLimit: Int = 128 * 1024 * 1024) {
        memoryCache.totalCostLimit = memoryByteLimit
        memoryCache.countLimit = 500

        operationQueue.name = "com.hyprmac.thumbnail.loader"
        operationQueue.maxConcurrentOperationCount = maxConcurrentOperations
        operationQueue.qualityOfService = .userInitiated

        let cacheDir = NSString(string: "~/.cache/hyprmac/thumbnails").expandingTildeInPath
        self.diskCacheDirectory = cacheDir
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
    }

    /// Loads or generates a downsampled thumbnail asynchronously with bounded concurrency,
    /// in-flight deduplication, and persistent disk cache fallback.
    @discardableResult
    public func loadThumbnail(
        for path: String,
        targetSize: NSSize = NSSize(width: 250, height: 145),
        completion: @escaping CompletionHandler
    ) -> ThumbnailCancellationToken? {
        let cacheKey = "\(path)@\(Int(targetSize.width))x\(Int(targetSize.height))"

        // 1. Fast-path: Check memory cache
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            DispatchQueue.main.async {
                completion(cached)
            }
            return nil
        }

        // 2. Check in-flight requests or schedule
        lock.lock()
        let callbackID = UUID()

        if var existing = inFlightRequests[cacheKey] {
            existing.callbacks[callbackID] = completion
            inFlightRequests[cacheKey] = existing
            lock.unlock()

            return ThumbnailCancellationToken { [weak self] in
                self?.cancelCallback(cacheKey: cacheKey, callbackID: callbackID)
            }
        }

        // 3. Create new Operation with bounded concurrency
        let requestOperation = BlockOperation()
        requestOperation.addExecutionBlock { [weak self] in
            guard let self = self else { return }
            self.executeThumbnailGeneration(path: path, targetSize: targetSize, cacheKey: cacheKey)
        }

        let request = InFlightRequest(operation: requestOperation, callbacks: [callbackID: completion])
        inFlightRequests[cacheKey] = request
        lock.unlock()

        operationQueue.addOperation(requestOperation)

        return ThumbnailCancellationToken { [weak self] in
            self?.cancelCallback(cacheKey: cacheKey, callbackID: callbackID)
        }
    }

    private func cancelCallback(cacheKey: String, callbackID: UUID) {
        lock.lock()
        guard var request = inFlightRequests[cacheKey] else {
            lock.unlock()
            return
        }

        request.callbacks.removeValue(forKey: callbackID)

        if request.callbacks.isEmpty {
            request.operation.cancel()
            inFlightRequests.removeValue(forKey: cacheKey)
            lock.unlock()
        } else {
            inFlightRequests[cacheKey] = request
            lock.unlock()
        }
    }

    private func executeThumbnailGeneration(path: String, targetSize: NSSize, cacheKey: String) {
        // Check cancellation
        lock.lock()
        let isCancelled = inFlightRequests[cacheKey]?.operation.isCancelled ?? true
        lock.unlock()
        if isCancelled { return }

        // 1. Check persistent disk cache
        let diskPath = persistentDiskCachePath(for: path, targetSize: targetSize)
        if FileManager.default.fileExists(atPath: diskPath),
           let diskImage = NSImage(contentsOfFile: diskPath) {
            let cost = Int(targetSize.width * targetSize.height * 4)
            memoryCache.setObject(diskImage, forKey: cacheKey as NSString, cost: max(cost, 1))
            finishRequest(cacheKey: cacheKey, image: diskImage)
            return
        }

        // 2. Decode downsampled thumbnail from original image file
        guard FileManager.default.fileExists(atPath: path) else {
            finishRequest(cacheKey: cacheKey, image: nil)
            return
        }

        let fileURL = URL(fileURLWithPath: path)
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            finishRequest(cacheKey: cacheKey, image: nil)
            return
        }

        // Check cancellation before heavy decode
        lock.lock()
        let stillActive = !(inFlightRequests[cacheKey]?.operation.isCancelled ?? true)
        lock.unlock()
        if !stillActive { return }

        let maxPixelSize = max(targetSize.width, targetSize.height) * 2.0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
        ]

        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            finishRequest(cacheKey: cacheKey, image: nil)
            return
        }

        let thumbImage = NSImage(cgImage: cgThumb, size: targetSize)

        // 3. Save to persistent disk cache as JPEG
        saveToDiskCache(cgImage: cgThumb, at: diskPath)

        // 4. Store in memory cache with byte cost: width * height * 4
        let cost = Int(targetSize.width * targetSize.height * 4)
        memoryCache.setObject(thumbImage, forKey: cacheKey as NSString, cost: max(cost, 1))

        // 5. Deliver result to callbacks
        finishRequest(cacheKey: cacheKey, image: thumbImage)
    }

    private func finishRequest(cacheKey: String, image: NSImage?) {
        lock.lock()
        let callbacks = inFlightRequests.removeValue(forKey: cacheKey)?.callbacks.values
        lock.unlock()

        guard let callbacks = callbacks, !callbacks.isEmpty else { return }

        DispatchQueue.main.async {
            for callback in callbacks {
                callback(image)
            }
        }
    }

    public func persistentDiskCachePath(for path: String, targetSize: NSSize) -> String {
        let key = "\(path)_\(Int(targetSize.width))x\(Int(targetSize.height))"
        let hash = SHA256.hash(data: Data(key.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        return (diskCacheDirectory as NSString).appendingPathComponent("\(hash).jpg")
    }

    private func saveToDiskCache(cgImage: CGImage, at diskPath: String) {
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: diskPath) as CFURL, "public.jpeg" as CFString, 1, nil) else {
            return
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ]
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    public func clearCache(clearDisk: Bool = false) {
        lock.lock()
        memoryCache.removeAllObjects()
        lock.unlock()

        if clearDisk {
            try? FileManager.default.removeItem(atPath: diskCacheDirectory)
            try? FileManager.default.createDirectory(atPath: diskCacheDirectory, withIntermediateDirectories: true)
        }
    }
}
