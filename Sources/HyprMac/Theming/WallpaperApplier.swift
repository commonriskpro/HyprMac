import Cocoa

/// Centralized desktop wallpaper application helper for HyprMac.
///
/// Updates `~/.cache/current_wallpaper` and applies the image across all active `NSScreen` instances
/// via `NSWorkspace.shared.setDesktopImageURL`.
///
/// Strictly adheres to Section 4.7 (Kernel SSOT): client UI does NOT execute `wallset.sh` directly;
/// kernel FSEvents monitors the wallpaper store and triggers theme propagation.
@MainActor
public enum WallpaperApplier {
    public static func apply(path: String) {
        let cachePath = NSString(string: "~/.cache/current_wallpaper").expandingTildeInPath
        let cacheDir = (cachePath as NSString).deletingLastPathComponent

        do {
            if !FileManager.default.fileExists(atPath: cacheDir) {
                try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            }
            try path.write(toFile: cachePath, atomically: true, encoding: .utf8)
        } catch {
            fputs("[-] [WallpaperApplier] Failed to write cache to \(cachePath): \(error)\n", stderr)
        }

        let fileURL = URL(fileURLWithPath: path)
        for screen in NSScreen.screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(fileURL, for: screen, options: [:])
            } catch {
                fputs("[-] [WallpaperApplier] Failed to set desktop image for screen '\(screen.localizedName)': \(error)\n", stderr)
            }
        }
    }
}
