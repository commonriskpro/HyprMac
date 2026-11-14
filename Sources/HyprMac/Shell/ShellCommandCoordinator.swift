import Cocoa

/// Coordinates in-daemon lifecycle and presentation of built-in shell UI components
/// (Rofi launcher, Wallpaper gallery, Wlogout power menu).
@MainActor
public final class ShellCommandCoordinator {
    public static let shared = ShellCommandCoordinator()

    private var activeGalleryWindow: WallpaperGalleryWindow?
    private var activeRofiWindow: RofiWindow?
    private var activeWlogoutWindow: WlogoutWindow?

    public init() {}

    public func handleAction(_ action: BuiltinShellAction) {
        switch action {
        case .launcher:
            showLauncher()
        case .wallpaperGallery:
            showWallpaperGallery()
        case .powerMenu:
            showPowerMenu()
        }
    }

    public func showWallpaperGallery() {
        if let current = WallpaperGalleryWindow.current {
            current.showGallery()
        } else {
            let win = WallpaperGalleryWindow(initialQuery: nil, synchronousLoad: false)
            self.activeGalleryWindow = win
            win.showGallery()
        }
    }

    public func showLauncher() {
        if let current = RofiWindow.current {
            current.showLauncher()
        } else {
            let win = RofiWindow()
            self.activeRofiWindow = win
            win.showLauncher()
        }
    }

    public func showPowerMenu() {
        if let current = WlogoutWindow.current {
            current.showMenu()
        } else {
            let win = WlogoutWindow()
            self.activeWlogoutWindow = win
            win.showMenu()
        }
    }
}
