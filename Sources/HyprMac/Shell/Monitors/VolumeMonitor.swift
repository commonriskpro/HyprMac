import Cocoa
import CoreAudio
import AudioToolbox

/// Represents a hardware or virtual audio output device
public struct AudioOutputDevice: Equatable, Identifiable, Sendable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let transportType: UInt32
    public let isDefault: Bool

    public init(id: AudioDeviceID, name: String, uid: String, transportType: UInt32, isDefault: Bool) {
        self.id = id
        self.name = name
        self.uid = uid
        self.transportType = transportType
        self.isDefault = isDefault
    }

    public var icon: String {
        let lower = name.lowercased()
        if lower.contains("headphone") || lower.contains("headset") || lower.contains("airpod") || lower.contains("earbuds") || lower.contains("virtuoso") || lower.contains("buds") {
            return "󰋋"
        }
        if lower.contains("display") || lower.contains("monitor") || lower.contains("tv") || lower.contains("hdmi") || lower.contains("kc242") {
            return "󰍹"
        }
        switch transportType {
        case 1651275109 /* 'blue' */, 0x626c6561 /* 'blea' */:
            return "󰂯"
        case 1751412073 /* 'hdmi' */, 0x64707274 /* 'dprt' */:
            return "󰍹"
        case 0x61697270 /* 'airp' */:
            return "󰀃"
        case 1651274862 /* 'bltn' */:
            return "󰓃"
        case 1970496032 /* 'usb ' */:
            return "󰋋"
        default:
            return "󰕾"
        }
    }
}

/// Reader and controller for system output volume and output audio devices via CoreAudio
public enum VolumeMonitor {
    public static var shared: VolumeMonitor.Type { VolumeMonitor.self }

    public static let didChangeNotification = Notification.Name("HyprMacVolumeMonitorDidChange")

    nonisolated(unsafe) private static var trackedSystemBlock: AudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private static var trackedDevicesBlock: AudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private static var trackedDeviceBlock: AudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private static var trackedDeviceID: AudioDeviceID?

    public static func defaultOutputDeviceID() -> AudioDeviceID {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultOutputDeviceID
        )
        guard status == noErr else { return 0 }
        return defaultOutputDeviceID
    }

    public static func currentVolume() -> Int {
        let defaultOutputDeviceID = defaultOutputDeviceID()
        guard defaultOutputDeviceID != 0 else {
            fputs("VolumeMonitor: default output device ID is 0\n", stderr)
            return 0
        }

        var volume = Float32(0.0)
        var propertySize = UInt32(MemoryLayout<Float32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let volStatus = AudioObjectGetPropertyData(
            defaultOutputDeviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &volume
        )
        guard volStatus == noErr else {
            fputs("VolumeMonitor: failed to get volume for device \(defaultOutputDeviceID), status: \(volStatus)\n", stderr)
            return 0
        }

        return Int((volume * 100.0).rounded())
    }

    public static func setVolume(_ volume: Int) {
        let clamped = max(0, min(100, volume))
        let defaultOutputDeviceID = defaultOutputDeviceID()
        guard defaultOutputDeviceID != 0 else {
            let script = "set volume output volume \(clamped)"
            NSAppleScript(source: script)?.executeAndReturnError(nil)
            return
        }

        var volFloat = Float32(clamped) / 100.0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let propertySize = UInt32(MemoryLayout<Float32>.size)
        let setStatus = AudioObjectSetPropertyData(
            defaultOutputDeviceID,
            &propertyAddress,
            0,
            nil,
            propertySize,
            &volFloat
        )
        if setStatus != noErr {
            let script = "set volume output volume \(clamped)"
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    public static func outputDevices() -> [AudioOutputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        let currentDefaultID = defaultOutputDeviceID()
        var result: [AudioOutputDevice] = []

        for dev in deviceIDs {
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(dev, &streamAddr, 0, nil, &streamSize)
            guard status == noErr, streamSize > 0 else { continue }

            let rawBuffer = UnsafeMutableRawPointer.allocate(
                byteCount: Int(streamSize),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            status = AudioObjectGetPropertyData(dev, &streamAddr, 0, nil, &streamSize, rawBuffer)
            var totalChannels = 0
            if status == noErr {
                let bufferListPtr = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
                let numBuffers = Int(bufferListPtr.pointee.mNumberBuffers)
                if numBuffers > 0 {
                    withUnsafePointer(to: &bufferListPtr.pointee.mBuffers) { firstBufPtr in
                        let bufferBuf = UnsafeBufferPointer<AudioBuffer>(start: firstBufPtr, count: numBuffers)
                        for b in bufferBuf {
                            totalChannels += Int(b.mNumberChannels)
                        }
                    }
                }
            }
            rawBuffer.deallocate()
            guard totalChannels > 0 else { continue }

            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameUnmanaged: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var devName = "Audio Output"
            if withUnsafeMutablePointer(to: &nameUnmanaged, { ptr in
                AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &nameSize, ptr)
            }) == noErr, let cf = nameUnmanaged?.takeRetainedValue() {
                devName = cf as String
            }

            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidUnmanaged: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var devUID = "\(dev)"
            if withUnsafeMutablePointer(to: &uidUnmanaged, { ptr in
                AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &uidSize, ptr)
            }) == noErr, let cf = uidUnmanaged?.takeRetainedValue() {
                devUID = cf as String
            }

            var transAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transType: UInt32 = 0
            var transSize = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(dev, &transAddr, 0, nil, &transSize, &transType)

            let isDefault = (dev == currentDefaultID)
            result.append(AudioOutputDevice(
                id: dev,
                name: devName,
                uid: devUID,
                transportType: transType,
                isDefault: isDefault
            ))
        }

        return result
    }

    @discardableResult
    public static func setOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var devID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)

        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultStatus = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            0,
            nil,
            size,
            &devID
        )

        var systemOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemStatus = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &systemOutputAddress,
            0,
            nil,
            size,
            &devID
        )

        if defaultStatus != noErr || systemStatus != noErr {
            let fallbackURL = URL(fileURLWithPath: "/opt/homebrew/bin/SwitchAudioSource")
            if FileManager.default.isExecutableFile(atPath: fallbackURL.path) {
                let process = Process()
                process.executableURL = fallbackURL
                process.arguments = ["-t", "output", "-i", "\(deviceID)"]
                process.terminationHandler = { proc in
                    if proc.terminationStatus == 0 {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: didChangeNotification, object: nil)
                        }
                    } else {
                        fputs("VolumeMonitor: SwitchAudioSource failed with exit code \(proc.terminationStatus)\n", stderr)
                    }
                }
                do {
                    try process.run()
                } catch {
                    fputs("VolumeMonitor: failed to run SwitchAudioSource: \(error)\n", stderr)
                }
            } else {
                fputs("VolumeMonitor: CoreAudio setOutputDevice failed (default: \(defaultStatus), system: \(systemStatus))\n", stderr)
            }
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: didChangeNotification, object: nil)
            }
        }
        return true
    }

    public static func stopMonitoring() {
        if let block = trackedSystemBlock {
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                DispatchQueue.main,
                block
            )
            trackedSystemBlock = nil
        }
        if let block = trackedDevicesBlock {
            var devicesAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                DispatchQueue.main,
                block
            )
            trackedDevicesBlock = nil
        }
        if let block = trackedDeviceBlock, let deviceID = trackedDeviceID, deviceID != 0 {
            var volAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                deviceID,
                &volAddress,
                DispatchQueue.main,
                block
            )
            trackedDeviceBlock = nil
            trackedDeviceID = nil
        }
    }

    public static func startMonitoring(onChange: @escaping @Sendable (Int) -> Void) {
        stopMonitoring()

        func attachDeviceListener() {
            if let block = trackedDeviceBlock, let deviceID = trackedDeviceID, deviceID != 0 {
                var volAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectRemovePropertyListenerBlock(deviceID, &volAddress, DispatchQueue.main, block)
                trackedDeviceBlock = nil
                trackedDeviceID = nil
            }

            let defaultOutputDeviceID = defaultOutputDeviceID()
            if defaultOutputDeviceID != 0 {
                var volAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                )
                let devBlock: AudioObjectPropertyListenerBlock = { _, _ in
                    let vol = currentVolume()
                    onChange(vol)
                    NotificationCenter.default.post(name: didChangeNotification, object: nil)
                }
                trackedDeviceBlock = devBlock
                trackedDeviceID = defaultOutputDeviceID
                AudioObjectAddPropertyListenerBlock(
                    defaultOutputDeviceID,
                    &volAddress,
                    DispatchQueue.main,
                    devBlock
                )
            }
        }

        var systemAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let sysBlock: AudioObjectPropertyListenerBlock = { _, _ in
            attachDeviceListener()
            let vol = currentVolume()
            onChange(vol)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
        trackedSystemBlock = sysBlock

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &systemAddress,
            DispatchQueue.main,
            sysBlock
        )

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let devicesBlock: AudioObjectPropertyListenerBlock = { _, _ in
            attachDeviceListener()
            let vol = currentVolume()
            onChange(vol)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
        trackedDevicesBlock = devicesBlock

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            devicesBlock
        )

        attachDeviceListener()
        onChange(currentVolume())
    }
}
