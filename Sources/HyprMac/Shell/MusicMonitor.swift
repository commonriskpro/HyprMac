import Cocoa
import Foundation

/// Data representation of an active music track from a native media player.
public struct MusicTrackInfo: Equatable, Sendable {
    public let player: String
    public let bundleID: String
    public let title: String
    public let artist: String
    public let album: String
    public let isPlaying: Bool

    public init(
        player: String,
        bundleID: String,
        title: String,
        artist: String,
        album: String,
        isPlaying: Bool
    ) {
        self.player = player
        self.bundleID = bundleID
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
    }

    /// Formatted display text: "Artist — Title" if artist is present, otherwise "Title".
    public var formattedText: String {
        if !artist.isEmpty {
            return "\(artist) — \(title)"
        } else {
            return title
        }
    }
}

/// Event-driven monitor tracking native macOS music players (Spotify & Apple Music).
/// Strictly excludes web browsers to prevent tab/video title pollution in HyprBar.
@MainActor
public final class MusicMonitor: NSObject {
    public static let shared = MusicMonitor()

    /// Whitelist of strictly native macOS music applications.
    public nonisolated static let allowedMusicBundleIDs: Set<String> = [
        "com.spotify.client",
        "com.apple.Music",
        "co.brushedtype.doppler-macos",
        "com.coppertino.Vox",
        "com.swinsian.Swinsian",
        "com.tidal.desktop",
        "com.deezer.deezer-desktop"
    ]

    /// Blacklist of browsers and multi-purpose runtimes to never treat as music players.
    public nonisolated static let excludedBrowserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "app.zen-browser.zen"
    ]

    /// Validates whether a given bundle identifier belongs to an authorized native music player.
    public nonisolated static func isEligibleMusicPlayer(bundleID: String) -> Bool {
        allowedMusicBundleIDs.contains(bundleID) && !excludedBrowserBundleIDs.contains(bundleID)
    }

    /// Currently tracked active music track.
    public private(set) var currentTrack: MusicTrackInfo? {
        didSet {
            if currentTrack != oldValue {
                onTrackChange?(currentTrack)
            }
        }
    }

    /// Callback triggered whenever active music track info changes.
    public var onTrackChange: (@MainActor (MusicTrackInfo?) -> Void)?

    public override init() {
        super.init()
    }

    deinit {
        // Symmetrical cleanup handled via explicit stop()
    }

    // MARK: - Pure Notification Parsers

    /// Parses Spotify's PlaybackStateChanged distributed notification dictionary.
    public nonisolated static func parseSpotifyNotification(userInfo: [AnyHashable: Any]) -> MusicTrackInfo? {
        let state = (userInfo["Player State"] as? String) ?? (userInfo["PlayerState"] as? String) ?? ""
        let cleanState = state.trimmingCharacters(in: .whitespaces).lowercased()
        if cleanState == "stopped" || cleanState.isEmpty {
            return nil
        }
        let isPlaying = (cleanState == "playing")
        guard let name = userInfo["Name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        let artist = (userInfo["Artist"] as? String) ?? ""
        let album = (userInfo["Album"] as? String) ?? ""

        return MusicTrackInfo(
            player: "Spotify",
            bundleID: "com.spotify.client",
            title: name.trimmingCharacters(in: .whitespaces),
            artist: artist.trimmingCharacters(in: .whitespaces),
            album: album.trimmingCharacters(in: .whitespaces),
            isPlaying: isPlaying
        )
    }

    /// Parses Apple Music's playerInfo distributed notification dictionary.
    public nonisolated static func parseAppleMusicNotification(userInfo: [AnyHashable: Any]) -> MusicTrackInfo? {
        let state = (userInfo["Player State"] as? String) ?? (userInfo["PlayerState"] as? String) ?? ""
        let cleanState = state.trimmingCharacters(in: .whitespaces).lowercased()
        if cleanState == "stopped" || cleanState.isEmpty {
            return nil
        }
        let isPlaying = (cleanState == "playing")
        guard let name = userInfo["Name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        let artist = (userInfo["Artist"] as? String) ?? ""
        let album = (userInfo["Album"] as? String) ?? ""

        return MusicTrackInfo(
            player: "Music",
            bundleID: "com.apple.Music",
            title: name.trimmingCharacters(in: .whitespaces),
            artist: artist.trimmingCharacters(in: .whitespaces),
            album: album.trimmingCharacters(in: .whitespaces),
            isPlaying: isPlaying
        )
    }

    // MARK: - Lifecycle Management

    @objc private func handleSpotifyNotification(_ notif: Notification) {
        if let track = Self.parseSpotifyNotification(userInfo: notif.userInfo ?? [:]) {
            self.currentTrack = track
        } else if self.currentTrack?.bundleID == "com.spotify.client" {
            self.currentTrack = nil
        }
    }

    @objc private func handleAppleMusicNotification(_ notif: Notification) {
        if let track = Self.parseAppleMusicNotification(userInfo: notif.userInfo ?? [:]) {
            self.currentTrack = track
        } else if self.currentTrack?.bundleID == "com.apple.Music" {
            self.currentTrack = nil
        }
    }

    @objc private func handleApplicationTermination(_ notif: Notification) {
        if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           let bundleID = app.bundleIdentifier,
           self.currentTrack?.bundleID == bundleID {
            self.currentTrack = nil
        }
    }

    /// Starts event-driven distributed notification listening and checks running status.
    public func start() {
        stop()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSpotifyNotification(_:)),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleAppleMusicNotification(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleApplicationTermination(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        queryInitialTrackIfRunning()
    }

    /// Stops observing distributed notifications and terminates event listening.
    public func stop() {
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil
        )
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    /// Explicitly updates tracked music track info (used by tests and manual updates).
    public func setTrack(_ track: MusicTrackInfo?) {
        self.currentTrack = track
    }

    // MARK: - Initial Non-Blocking Track Query

    private func queryInitialTrackIfRunning() {
        let runningSpotify = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
        let runningAppleMusic = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Music" }

        guard runningSpotify || runningAppleMusic else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if runningSpotify {
                let script = """
                tell application "Spotify"
                    if player state is not stopped then
                        return (player state as string) & "|||" & (name of current track) & "|||" & (artist of current track) & "|||" & (album of current track)
                    end if
                end tell
                """
                if let s = NSAppleScript(source: script) {
                    var err: NSDictionary?
                    let res = s.executeAndReturnError(&err)
                    if let str = res.stringValue {
                        let parts = str.components(separatedBy: "|||")
                        if parts.count >= 4 {
                            let state = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                            let name = parts[1].trimmingCharacters(in: .whitespaces)
                            let artist = parts[2].trimmingCharacters(in: .whitespaces)
                            let album = parts[3].trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty && state != "stopped" {
                                let isPlaying = (state == "playing")
                                let track = MusicTrackInfo(
                                    player: "Spotify",
                                    bundleID: "com.spotify.client",
                                    title: name,
                                    artist: artist,
                                    album: album,
                                    isPlaying: isPlaying
                                )
                                Task { @MainActor [weak self] in
                                    guard let self = self else { return }
                                    if self.currentTrack == nil {
                                        self.currentTrack = track
                                    }
                                }
                                return
                            }
                        }
                    }
                }
            }

            if runningAppleMusic {
                let script = """
                tell application "Music"
                    if player state is not stopped then
                        return (player state as string) & "|||" & (name of current track) & "|||" & (artist of current track) & "|||" & (album of current track)
                    end if
                end tell
                """
                if let s = NSAppleScript(source: script) {
                    var err: NSDictionary?
                    let res = s.executeAndReturnError(&err)
                    if let str = res.stringValue {
                        let parts = str.components(separatedBy: "|||")
                        if parts.count >= 4 {
                            let state = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                            let name = parts[1].trimmingCharacters(in: .whitespaces)
                            let artist = parts[2].trimmingCharacters(in: .whitespaces)
                            let album = parts[3].trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty && state != "stopped" {
                                let isPlaying = (state == "playing")
                                let track = MusicTrackInfo(
                                    player: "Music",
                                    bundleID: "com.apple.Music",
                                    title: name,
                                    artist: artist,
                                    album: album,
                                    isPlaying: isPlaying
                                )
                                Task { @MainActor [weak self] in
                                    guard let self = self else { return }
                                    if self.currentTrack == nil {
                                        self.currentTrack = track
                                    }
                                }
                                return
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Playback Controls

    private func executeAppleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let script = NSAppleScript(source: source) {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
            }
        }
    }

    private func activeMusicPlayerBundleID() -> String? {
        let running = NSWorkspace.shared.runningApplications
        if running.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) {
            return "com.spotify.client"
        }
        if running.contains(where: { $0.bundleIdentifier == "com.apple.Music" }) {
            return "com.apple.Music"
        }
        return nil
    }

    public func togglePlayPause() {
        guard let bundle = currentTrack?.bundleID ?? activeMusicPlayerBundleID() else { return }
        let appName = (bundle == "com.spotify.client") ? "Spotify" : "Music"
        executeAppleScript("tell application \"" + appName + "\" to playpause")
        if let cur = currentTrack {
            self.currentTrack = MusicTrackInfo(
                player: cur.player,
                bundleID: cur.bundleID,
                title: cur.title,
                artist: cur.artist,
                album: cur.album,
                isPlaying: !cur.isPlaying
            )
        }
    }

    public func nextTrack() {
        guard let bundle = currentTrack?.bundleID ?? activeMusicPlayerBundleID() else { return }
        let appName = (bundle == "com.spotify.client") ? "Spotify" : "Music"
        executeAppleScript("tell application \"" + appName + "\" to next track")
    }

    public func previousTrack() {
        guard let bundle = currentTrack?.bundleID ?? activeMusicPlayerBundleID() else { return }
        let appName = (bundle == "com.spotify.client") ? "Spotify" : "Music"
        executeAppleScript("tell application \"" + appName + "\" to previous track")
    }

    public func activatePlayerApp() {
        guard let bundle = currentTrack?.bundleID ?? activeMusicPlayerBundleID() else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            app.activate()
        }
    }
}
