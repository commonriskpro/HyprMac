<div align="center">

# HyprMac

**Hyprland-grade compositor composition & tiling for macOS on Apple Silicon.**

*Accessibility handles the layout. WindowServer handles the visual engine.*

<img src="assets/hyprmac_bar_rendered.png" alt="HyprBar — Waybar-style status bar on macOS" width="850"/>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014%2B%20(Apple%20Silicon)-black?style=flat-square&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Architecture-ARM64e%20PAC-blue?style=flat-square" alt="ARM64e">
  <img src="https://img.shields.io/badge/Swift-6%20Strict%20Concurrency-orange?style=flat-square&logo=swift" alt="Swift 6">
  <img src="https://img.shields.io/badge/Idle%20CPU-0.0%25%20(Event--driven)-brightgreen?style=flat-square" alt="0% Idle CPU">
  <img src="https://img.shields.io/badge/Security-SIP%20Disabled%20Required-red?style=flat-square" alt="SIP Required">
</p>

</div>

---

## The Pitch

On Linux, a Hyprland rice gives you total control: square corners, zero shadows, Waybar, Rofi, and organic Fibonacci tiling. On macOS, tiling managers (like yabai, Amethyst, or Aerospace) are forced to operate strictly from user-space via Accessibility APIs. While Accessibility is great at moving window frames, it cannot touch the compositor buffer: macOS continues to draw 14px rounded corners, massive drop shadows, and titlebars, resulting in a 1-frame visual flicker whenever a new window spawns.

**HyprMac uses a hybrid architecture:**
- **Accessibility (`AXObserver`)** handles what it does best: window movement, focus detection, and reactive event listening with **0.0% CPU in idle**.
- **In-Situ Compositor Hook (`libhyprserver.dylib`)** handles what Accessibility cannot: interposing `SLSNewWindow` directly inside `WindowServer` so windows are born square, shadowless, and frameless from microsecond zero.
- **Client AppKit Hook (`libhyprclient.dylib`)** strips internal titlebars and injects modern desktop enhancements (like the auto-collapsing Zen Drawer for Finder).
- **A Complete Linux Rice Suite**: You don't need to stitch together 4 disconnected tools. HyprMac ships with a native Waybar status bar, Rofi modal launcher, Wlogout power menu, and FSEvents wallpaper watcher out of the box.

---

## The 4 Core Pillars

1. **Zero-Flicker Window Styling**  
   Windows are born square and shadowless at `SLSNewWindow` interposition time directly inside the root compositor daemon (`WindowServer`, UID 88). No 1-frame cosmetic flash.

2. **Efficient Hybrid Architecture (0.0% Idle CPU)**  
   Zero polling loops. Window movements, title changes, tab switches, and minimization are streamed via native macOS `AXObserver` and `NSWorkspace` notifications. Dual lock-free shared memory (`/tmp/hyprmac-ipc.shm`) bridges Swift and the compositor without sandbox violations.

3. **Complete Wayland Rice Suite Built-in**  
   - **HyprBar**: Translucent floating Waybar capsules with background blur, active window title/icon, battery, volume, Wi-Fi, hardware load (CPU/RAM), and notification center indicator.
   - **Rofi Launcher**: Fuzzy application finder, system command runner, math calculator, and window switcher.
   - **Wlogout**: Fullscreen Wayland-style power menu modal (Lock, Sleep, Logout, Reboot, Shutdown).
   - **Wallpaper Gallery & Watcher**: Visual wallpaper grid with automatic Pywal/Matugen palette generation on change.
   - **Zen Drawer**: Auto-collapsing floating sidebar drawer for Finder.

4. **Native `hyprland.conf` Parsing**  
   Bring your existing Hyprland keybinds, modifiers, gaps, and rules directly into macOS without learning a new configuration language.

---

## Technical Comparison

| Feature | **HyprMac** | **yabai** | **Aerospace** | **Amethyst** |
| :--- | :---: | :---: | :---: | :---: |
| **Architecture** | **Hybrid (In-situ `WindowServer` + Reactive AX)** | User-space + Scripting Addon | User-space (AX API) | User-space (AX API) |
| **Window Layout Engine** | **Accessibility API (`setWindowFrame`)** | Accessibility API | Accessibility API | Accessibility API |
| **Corner & Shadow Styling** | **Compositor Hook (`SLSNewWindow`)** | Delayed cosmetic overlay | Unmodified macOS Aqua | Unmodified macOS Aqua |
| **New Window Flicker** | **Zero (styled at creation time)** | 1-frame visible flash | N/A | N/A |
| **Menu Bar Suppression** | **Native reveal = 0.0 (`WindowServer`)** | macOS auto-hide setting | macOS auto-hide setting | None |
| **Full Wayland Suite** | **Built-in (Bar, Rofi, Wlogout, Gallery)** | Tiling only (needs external tools) | Tiling only | Tiling only |
| **Tiling Engine** | **Dwindle / Fibonacci (Hyprland)** | BSP / Float / Stack | i3-style tree | Predefined columns |
| **Idle CPU Utilization** | **0.0% (100% Event-driven `AXObserver`)** | Periodic polling & AX queries | Polling / IPC | Continuous polling |
| **Config Syntax** | **`hyprland.conf` compatible** | Custom CLI commands | Custom TOML | macOS GUI prefs |

---

## Architecture Overview

```
┌────────────────────────────────────────────────────────────────────────┐
│                         macOS Desktop Session                          │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  ┌───────────────────────┐   Lock-Free SHM Ring   ┌─────────────────┐  │
│  │     HyprMac CLI       │◄── /tmp/hyprmac-ipc ──►│ libhyprserver   │  │
│  │    (Swift 6 Daemon)   │       .shm (64KB)      │ .dylib (Inside  │  │
│  │                       │                        │  WindowServer)  │  │
│  │  • Dwindle Layout     │  ┌──────────────────┐  │                 │  │
│  │  • AXEventObserver    │  │   Command Ring   │  │ • SLSNewWindow  │  │
│  │  • HyprBar Window     │─►│   28KB Swift→WS  │─►│   Interposition │  │
│  │  • Rofi & Wlogout     │  └──────────────────┘  │ • Square Corners│  │
│  │  • Session Manager    │  ┌──────────────────┐  │ • Strip Shadows │  │
│  │  • Effects Manager    │◄─│   Response Ring  │◄─│ • MenuBar Lock  │  │
│  │    (Opacity/Blur)     │  │   28KB WS→Swift  │  │ • GPU Transforms│  │
│  └───────────────────────┘  └──────────────────┘  └─────────────────┘  │
│             ▲                                              ▲           │
│             │                                              │           │
│  ┌──────────┴───────────┐                         ┌────────┴────────┐  │
│  │       AXObserver     │                         │   hypr-inject   │  │
│  │  (Reactive OS Events)│                         │  (Mach Loader)  │  │
│  └──────────────────────┘                         └─────────────────┘  │
│             ▲                                              ▲           │
│             │                                              │           │
│  ┌──────────┴───────────┐                         ┌────────┴────────┐  │
│  │       CGEventTap     │                         │ libhyprclient   │  │
│  │  (Global Hotkeys)    │                         │ (Per-App Hook)  │  │
│  └──────────────────────┘                         │ • Strip Titlebar│  │
│                                                   │ • Zen Drawer    │  │
│                                                   └─────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

- **macOS 14+ (Sonoma or Sequoia)** on Apple Silicon (arm64e)
- **SIP disabled** (`csrutil disable` from Recovery Mode — required for `WindowServer` task port access)
- **Xcode Command Line Tools**

---

## Installation & Build

```bash
# 1. Clone repository
git clone https://github.com/commonriskpro/HyprMac.git
cd HyprMac

# 2. Build native ARM64e injector, compositor hook, and Swift application
make all
```

This compiles:
- `build/hypr-inject`: Two-stage PAC-signed remote thread loader.
- `build/libhyprserver.dylib`: In-situ WindowServer compositor interposer.
- `build/libhyprclient.dylib`: AppKit titlebar & Zen drawer interposer.
- `/Applications/HyprMac.app`: Release Swift package with Developer ID signature.

---

## Quickstart

### 1. Load the Compositor Hook

```bash
# Clean any stale IPC state
sudo rm -f /tmp/hyprmac-ipc.shm /tmp/hyprserver.ready

# Attach in-situ hook into WindowServer (requires root)
sudo ./build/hypr-inject

# Verify status
HyprMac server-status
```

### 2. Start the Desktop Session

```bash
# Start Dwindle tiling engine + HyprBar + global hotkeys
HyprMac daemon
```

---

## Key Features

### 🪟 Fibonacci / Dwindle Tiling
Windows automatically tile in organic binary-tree spirals according to aspect ratio. Supports directional focus (`Alt + H/J/K/L`), window swaps (`Alt + Shift + H/J/K/L`), fullscreen toggle (`Alt + F`), floating toggle (`Alt + V`), split ratio adjustments, and smooth mouse drag-and-drop.

<p align="center">
  <img src="assets/showcase/01_dwindle_tiling.png" alt="Dwindle Tiling on macOS" width="850"/>
</p>

### 📊 HyprBar (Waybar for macOS)
Floating translucent pill bar rendered with native AppKit and behind-window blur. Displays:
- Workspaces 1–9 (Arabic or Kanji numerals) with active indicator
- Active application icon and window title
- Battery status & charging indicator
- Clock (12h or 24h custom strftime)
- Live CPU & RAM hardware load
- Volume and Wi-Fi SSID
- Notification badge

<p align="center">
  <img src="assets/hyprmac_bar_rendered.png" alt="HyprBar Waybar status bar" width="850"/>
</p>

### 🚀 Built-in Rofi Launcher (`HyprMac launcher`)
Modal fuzzy launcher (`Alt + Space`) scanning macOS applications, command-line binaries, math expressions (`= 24 * 1024`), system power commands, and wallpaper switcher.

<p align="center">
  <img src="assets/showcase/02_rofi_launcher.png" alt="Rofi Modal Application Launcher" width="850"/>
</p>

### ⚡ Wlogout Power Menu (`HyprMac powermenu`)
Modal fullscreen overlay providing Lock, Suspend, Logout, Reboot, and Shutdown actions.

<p align="center">
  <img src="assets/showcase/03_wlogout_power.png" alt="Wlogout Power Menu Modal" width="850"/>
</p>

### 🖼️ Dynamic Wallpaper Theming & Gallery (`HyprMac wallpaper`)
Watches `~/Library/Application Support/com.apple.wallpaper/Store` using kernel `FSEvents` (0% CPU). On wallpaper change, it extracts dominant palette colors and regenerates live themes. Includes a visual modal gallery to preview and switch backgrounds.

<p align="center">
  <img src="assets/showcase/04_wallpaper_gallery.png" alt="Wallpaper Gallery Selector" width="850"/>
</p>

---

## Verification & Tests

HyprMac includes an extensive test suite verifying mathematical tiling bounds, IPC protocol framing, config parsing, and event handling:

```bash
# Run complete test suite (271 tests)
swift test

# Run C harness for SHM IPC ring buffer
make -C tests
./tests/test_ipc --self-test
```

---

## License

This project is intended for development and educational purposes on Apple Silicon hardware with user-authorized SIP modifications.
