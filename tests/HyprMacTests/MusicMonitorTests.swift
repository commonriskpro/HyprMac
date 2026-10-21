import XCTest
import Cocoa
@testable import HyprMac

@MainActor
final class MusicMonitorTests: XCTestCase {

    // MARK: - Bundle ID Whitelist and Browser Rejection Tests

    func testEligibleMusicPlayers() {
        // Authorized native music players
        XCTAssertTrue(MusicMonitor.isEligibleMusicPlayer(bundleID: "com.spotify.client"))
        XCTAssertTrue(MusicMonitor.isEligibleMusicPlayer(bundleID: "com.apple.Music"))
        XCTAssertTrue(MusicMonitor.isEligibleMusicPlayer(bundleID: "co.brushedtype.doppler-macos"))
        XCTAssertTrue(MusicMonitor.isEligibleMusicPlayer(bundleID: "com.coppertino.Vox"))
        XCTAssertTrue(MusicMonitor.isEligibleMusicPlayer(bundleID: "com.swinsian.Swinsian"))
        XCTAssertTrue(MusicMonitor.isEligibleMusicPlayer(bundleID: "com.tidal.desktop"))
        XCTAssertTrue(MusicMonitor.isEligibleMusicPlayer(bundleID: "com.deezer.deezer-desktop"))

        // Strictly excluded web browsers
        XCTAssertFalse(MusicMonitor.isEligibleMusicPlayer(bundleID: "com.apple.Safari"))
        XCTAssertFalse(MusicMonitor.isEligibleMusicPlayer(bundleID: "com.google.Chrome"))
        XCTAssertFalse(MusicMonitor.isEligibleMusicPlayer(bundleID: "company.thebrowser.Browser"))
        XCTAssertFalse(MusicMonitor.isEligibleMusicPlayer(bundleID: "com.brave.Browser"))
        XCTAssertFalse(MusicMonitor.isEligibleMusicPlayer(bundleID: "org.mozilla.firefox"))
        XCTAssertFalse(MusicMonitor.isEligibleMusicPlayer(bundleID: "com.microsoft.edgemac"))
        XCTAssertFalse(MusicMonitor.isEligibleMusicPlayer(bundleID: "com.vivaldi.Vivaldi"))
        XCTAssertFalse(MusicMonitor.isEligibleMusicPlayer(bundleID: "com.operasoftware.Opera"))
        XCTAssertFalse(MusicMonitor.isEligibleMusicPlayer(bundleID: "app.zen-browser.zen"))

        // Arbitrary unwhitelisted application
        XCTAssertFalse(MusicMonitor.isEligibleMusicPlayer(bundleID: "com.example.unrelated"))
    }

    // MARK: - Spotify Notification Parsing Tests

    func testParseSpotifyNotificationPlaying() {
        let userInfo: [AnyHashable: Any] = [
            "Player State": "Playing",
            "Name": "Bohemian Rhapsody",
            "Artist": "Queen",
            "Album": "A Night at the Opera"
        ]
        let track = MusicMonitor.parseSpotifyNotification(userInfo: userInfo)
        XCTAssertNotNil(track)
        XCTAssertEqual(track?.player, "Spotify")
        XCTAssertEqual(track?.bundleID, "com.spotify.client")
        XCTAssertEqual(track?.title, "Bohemian Rhapsody")
        XCTAssertEqual(track?.artist, "Queen")
        XCTAssertEqual(track?.album, "A Night at the Opera")
        XCTAssertEqual(track?.isPlaying, true)
        XCTAssertEqual(track?.formattedText, "Queen — Bohemian Rhapsody")
    }

    func testParseSpotifyNotificationPaused() {
        let userInfo: [AnyHashable: Any] = [
            "Player State": "Paused",
            "Name": "Starman",
            "Artist": "David Bowie",
            "Album": "Ziggy Stardust"
        ]
        let track = MusicMonitor.parseSpotifyNotification(userInfo: userInfo)
        XCTAssertNotNil(track)
        XCTAssertEqual(track?.player, "Spotify")
        XCTAssertEqual(track?.title, "Starman")
        XCTAssertEqual(track?.isPlaying, false)
        XCTAssertEqual(track?.formattedText, "David Bowie — Starman")
    }

    func testParseSpotifyNotificationStopped() {
        let userInfo: [AnyHashable: Any] = [
            "Player State": "Stopped",
            "Name": "Starman",
            "Artist": "David Bowie"
        ]
        let track = MusicMonitor.parseSpotifyNotification(userInfo: userInfo)
        XCTAssertNil(track, "Stopped state must return nil")
    }

    func testParseSpotifyNotificationEmptyName() {
        let userInfo: [AnyHashable: Any] = [
            "Player State": "Playing",
            "Name": "   ",
            "Artist": "Unknown"
        ]
        let track = MusicMonitor.parseSpotifyNotification(userInfo: userInfo)
        XCTAssertNil(track, "Empty track title must return nil")
    }

    // MARK: - Apple Music Notification Parsing Tests

    func testParseAppleMusicNotificationPlaying() {
        let userInfo: [AnyHashable: Any] = [
            "Player State": "Playing",
            "Name": "Clair de Lune",
            "Artist": "Claude Debussy",
            "Album": "Suite bergamasque"
        ]
        let track = MusicMonitor.parseAppleMusicNotification(userInfo: userInfo)
        XCTAssertNotNil(track)
        XCTAssertEqual(track?.player, "Music")
        XCTAssertEqual(track?.bundleID, "com.apple.Music")
        XCTAssertEqual(track?.title, "Clair de Lune")
        XCTAssertEqual(track?.artist, "Claude Debussy")
        XCTAssertEqual(track?.album, "Suite bergamasque")
        XCTAssertEqual(track?.isPlaying, true)
        XCTAssertEqual(track?.formattedText, "Claude Debussy — Clair de Lune")
    }

    func testParseAppleMusicNotificationPaused() {
        let userInfo: [AnyHashable: Any] = [
            "Player State": "Paused",
            "Name": "Gymnopédie No. 1",
            "Artist": "Erik Satie",
            "Album": "Gymnopédies"
        ]
        let track = MusicMonitor.parseAppleMusicNotification(userInfo: userInfo)
        XCTAssertNotNil(track)
        XCTAssertEqual(track?.player, "Music")
        XCTAssertEqual(track?.title, "Gymnopédie No. 1")
        XCTAssertEqual(track?.isPlaying, false)
        XCTAssertEqual(track?.formattedText, "Erik Satie — Gymnopédie No. 1")
    }

    func testParseAppleMusicNotificationStopped() {
        let userInfo: [AnyHashable: Any] = [
            "Player State": "Stopped"
        ]
        let track = MusicMonitor.parseAppleMusicNotification(userInfo: userInfo)
        XCTAssertNil(track, "Stopped state must return nil")
    }

    func testMusicTrackInfoFormattedTextWithoutArtist() {
        let track = MusicTrackInfo(
            player: "Music",
            bundleID: "com.apple.Music",
            title: "Solo Piano Improvisation",
            artist: "",
            album: "",
            isPlaying: true
        )
        XCTAssertEqual(track.formattedText, "Solo Piano Improvisation")
    }

    // MARK: - BarView Music Module Integration Tests

    func testBarViewUpdateMusicTrackTransitionsVisibilityAndText() {
        let barView = BarView(frame: .zero, workspaceCount: 6)
        defer { barView.stopTimers() }

        // 1. Initial state: musicCapsule is hidden
        XCTAssertTrue(barView.musicCapsule.isHidden, "Music capsule must initially be hidden")

        // 2. Calling with nil remains hidden
        barView.updateMusicTrack(nil)
        XCTAssertTrue(barView.musicCapsule.isHidden)
        XCTAssertEqual(barView.musicTrackLabel.stringValue, "")

        // 3. Passing active track reveals capsule and sets label text
        let activeTrack = MusicTrackInfo(
            player: "Spotify",
            bundleID: "com.spotify.client",
            title: "Midnight City",
            artist: "M83",
            album: "Hurry Up, We're Dreaming",
            isPlaying: true
        )
        barView.updateMusicTrack(activeTrack)
        XCTAssertFalse(barView.musicCapsule.isHidden, "Music capsule must be visible when playing")
        XCTAssertEqual(barView.musicTrackLabel.stringValue, "M83 — Midnight City")
        XCTAssertEqual(barView.musicStatusLabel.stringValue, "󰝚")
        XCTAssertEqual(barView.musicPlayPauseLabel.stringValue, "󰏤")

        // 4. Pausing track updates icons
        let pausedTrack = MusicTrackInfo(
            player: "Spotify",
            bundleID: "com.spotify.client",
            title: "Midnight City",
            artist: "M83",
            album: "Hurry Up, We're Dreaming",
            isPlaying: false
        )
        barView.updateMusicTrack(pausedTrack)
        XCTAssertFalse(barView.musicCapsule.isHidden)
        XCTAssertEqual(barView.musicStatusLabel.stringValue, "󰏤")
        XCTAssertEqual(barView.musicPlayPauseLabel.stringValue, "󰐊")

        // 5. Stopping track re-hides capsule
        barView.updateMusicTrack(nil)
        XCTAssertTrue(barView.musicCapsule.isHidden, "Music capsule must hide when track becomes nil")
        XCTAssertEqual(barView.musicTrackLabel.stringValue, "")
    }
}
