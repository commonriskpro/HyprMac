<div align="center">

# HyprMac

**Hyprland-grade window composition for macOS — from inside WindowServer.**

<img src="assets/hyprmac_bar_rendered.png" alt="HyprBar — Waybar-style status bar" width="800"/>

*Not another tiling manager. A full compositor-level reimagination of the macOS desktop.*

</div>

---

## Why

On Linux, a Hyprland rice gives you total control: square corners, no shadows, pixel-perfect neon borders, Waybar, Fibonacci tiling — everything feels like one cohesive system. On macOS, that doesn't exist. Every "tiling window manager" (yabai, Amethyst, Rectangle) just moves windows around — but the windows themselves still look like macOS. Round corners peek through, shadows persist, title bars stay, and any attempt to style them is a cosmetic overlay that flickers for a frame on every new window.

**HyprMac takes a different approach.** Instead of fighting the compositor from the outside, it loads a dynamic library *directly into* `WindowServer` — macOS's root compositor daemon — and modifies windows at the source. The result: zero-compromise visual parity with a Hyprland Wayland setup, running natively on Apple Silicon.

### What you get

- **Square corners, no shadows, no title bars** — applied at window *creation* time via `SLSNewWindow` interposition. No 1-frame flicker. No cosmetic overlays.
- **Native compositor borders** — colored border overlays rendered server-side inside WindowServer, with automatic active/inactive color switching on focus changes.
- **Fibonacci / Dwindle tiling** — the same organic binary-tree layout algorithm from Hyprland, not a generic grid.
- **Waybar-style status bar** — workspaces, system stats, and theming via an AppKit implementation that looks and feels like Waybar.
- **hyprland.conf parsing** — bring your existing Hyprland config and keybinds.
- **Aqua ↔ HyprMac session switching** — toggle between stock macOS and full rice mode.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                        macOS Desktop Session                        │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────────┐    SHM Ring Buffer IPC    ┌──────────────────┐  │
│  │   HyprMac CLI   │◄──── /tmp/hyprmac-ipc ───►│ libhyprserver    │  │
│  │   (Swift)        │      .shm (64KB)          │ .dylib           │  │
│  │                  │                            │ (inside          │  │
│  │  • DwindleEngine │   ┌──────────────────┐    │  WindowServer)   │  │
│  │  • ConfigParser  │   │  Command Ring    │    │                  │  │
│  │  • KeybindMgr    │──►│  28KB Swift→Hook │───►│ • SLSNewWindow   │  │
│  │  • HyprBar       │   └──────────────────┘    │   interposition  │  │
│  │  • SessionMgr    │   ┌──────────────────┐    │ • CGS border     │  │
│  │  • BorderWindow  │◄──│  Response Ring   │◄───│   overlays       │  │
│  │    (fallback)    │   │  28KB Hook→Swift │    │ • Corner/shadow/ │  │
│  └─────────────────┘   └──────────────────┘    │   titlebar mods  │  │
│                                                  └──────────────────┘  │
│         ▲                                               ▲              │
│         │                                               │              │
│  ┌──────┴──────┐                                ┌───────┴───────┐    │
│  │  CGEventTap  │                                │  hypr-inject   │    │
│  │  (hotkeys)   │                                │  (Mach loader) │    │
│  └─────────────┘                                └───────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

### The four pillars

#### 1. Mach Task Port Loader (`hypr-inject`)

Two-stage ARM64e remote thread loader running as root. Stage 1 bootstraps on a raw Mach thread to establish TLS via `pthread_create_from_mach_thread`; Stage 2 calls `dlopen()` from a real POSIX pthread. All pointers are PAC-signed, addresses are corrected via cross-process ASLR slide deltas, and the dylib is staged to `/Library/GPUBundles/` to satisfy WindowServer's sandbox.

#### 2. In-Situ Compositor Hook (`libhyprserver.dylib`)

A dynamic library running *inside* `WindowServer` (PID varies, UID 88). Interposes `SLSNewWindow`/`CGSNewWindow` to apply decoration policy at window creation — zero-flicker. Drives all window modifications (corners, shadows, titlebars, borders) through private SkyLight/CGS APIs using the root compositor connection (`SLSMainConnectionID()`). Includes a safe-mode circuit breaker (`/tmp/hyprmac.safemode`) to prevent bootloops.

#### 3. Shared Memory IPC

Dual lock-free ring buffers over a 64KB mmap'd file (`/tmp/hyprmac-ipc.shm`) with atomic acquire/release synchronization. Replaced Unix domain sockets because WindowServer's kernel sandbox blocks all BSD socket operations. Sub-millisecond latency with <0.5% CPU in idle polling.

#### 4. User-Space Swift Manager

Complete client suite: Fibonacci/Dwindle binary-tree tiling, `hyprland.conf` parser, `CGEventTap` global hotkeys, Waybar-style AppKit status bar, Aqua ↔ HyprMac session persistence, and fallback border overlays (Glass Halo / Neon / Outline) with automatic hook coordination.

---

## Prerequisites

- **macOS 14+** on Apple Silicon (arm64e)
- **SIP disabled** (`csrutil disable` from Recovery Mode)
- **Xcode Command Line Tools** (for `clang` with `-arch arm64e` and `swift`)

---

## Build

```bash
# Native components (libhyprserver.dylib + hypr-inject)
make all

# Swift package (HyprMac CLI + tiling engine + bar + config)
swift build
```

Both build systems produce ARM64e binaries with pointer authentication.

---

## Usage

### Load library into WindowServer

```bash
# Clean any stale state from a previous session
sudo rm -f /tmp/hyprmac-ipc.shm /tmp/hyprserver.ready

# Attach module (requires root — will modify the running compositor)
sudo ./build/hypr-inject

# Verify hook is active
swift run HyprMac server-status
```

> **Warning**: Updating the hook requires restarting WindowServer (`sudo killall WindowServer`), which logs you out and closes all windows. The login session restores automatically via `launchd`.

### Window operations

```bash
# Square corners on a specific window
swift run HyprMac square <window_id>

# Strip shadows
swift run HyprMac strip-shadow <window_id>

# Apply borders (Glass Halo / Neon / Outline)
swift run HyprMac border <mode>

# Probe visible windows
swift run HyprMac probe
```

### Tiling

```bash
# Start Dwindle tiling daemon with hotkeys
swift run HyprMac daemon

# Tile current windows once
swift run HyprMac tile
```

### Status bar & session

```bash
# Launch Waybar-style status bar
swift run HyprMac bar

# Switch to HyprMac mode (persists across restarts)
swift run HyprMac session hypr

# Switch back to stock Aqua
swift run HyprMac session aqua
```

### Install as LaunchDaemon

```bash
# Install and auto-start on boot
sudo make install-daemon

# Remove
sudo make uninstall-daemon
```

---

## Tests

```bash
# Swift unit tests (XCTest — bridge, ring buffer, protocol constants)
swift test

# Embedded CLI test suites
swift run HyprMac test-border     # 15 assertions — Glass Halo, Neon, Outline
swift run HyprMac test-config     # hyprland.conf parser
swift run HyprMac test-keys       # 35 assertions — modifier masks, keycodes
swift run HyprMac test-bar        # HyprBar status bar
swift run HyprMac test-session    # Session mode switching
swift run HyprMac test-dwindle    # 37 assertions — Fibonacci layout
swift run HyprMac test-bridge     # 35 assertions — SHM IPC, wire protocol

# Native C test harness (SHM ring buffer IPC, 13 tests with mock server)
make -C tests
./tests/test_ipc --self-test
```

---

## Project Structure

```
Sources/HyprMac/
├── main.swift                  # CLI entry point
├── Core/WindowDetector.swift   # AXUIElement + CGWindowList discovery
├── Config/                     # hyprland.conf parser
├── Input/                      # CGEventTap hotkey manager
├── Shell/                      # Waybar-style AppKit status bar
├── Bridge/                     # SHM ring buffer IPC + SkyLight C bridge
├── Layout/                     # Fibonacci / Dwindle binary-tree tiling
├── Render/                     # Fallback AppKit border overlays
└── Session/                    # Aqua ↔ HyprMac mode persistence

native/
├── injector/                   # hypr-inject (Mach task port loader)
├── server_hook/hook.c          # libhyprserver.dylib (in-situ compositor hook)
└── shared/protocol.h           # Binary wire protocol & SHM layout

tests/                          # C test harness (SHM IPC)
scripts/                        # E2E verification & stress testing
docs/                           # Architecture spec
openspec/                       # Design docs & task tracking
```

---

## How is this different from yabai?

| | yabai / Amethyst / Rectangle | HyprMac |
|---|---|---|
| **Window styling** | Can't modify — macOS controls corners, shadows, titlebars | Modifies at compositor level inside WindowServer |
| **Borders** | AppKit overlay windows (always one layer above) | Server-side CGS overlays synchronized to window lifecycle |
| **Flicker** | 1-frame decoration flash on new windows | Zero — `SLSNewWindow` interposition applies policy at creation |
| **IPC** | Accessibility API polling or Unix sockets | Lock-free SHM ring buffers (sub-ms, sandbox-safe) |
| **Tiling** | BSP grid | Fibonacci / Dwindle binary tree (Hyprland-native) |
| **Config** | Custom format | `hyprland.conf` compatible |
| **Status bar** | External (SketchyBar, etc.) | Built-in Waybar-style bar |

---

## References

- [Hyprland](https://hyprland.org/) — the Wayland compositor this project aims to replicate on macOS
- [noro18/linux-ricing-dotfiles](https://github.com/Noro18/linux-ricing-dotfiles) — reference rice for target aesthetic

---

## License

This project is for personal use and educational purposes. It relies on private macOS APIs and requires SIP to be disabled. Use at your own risk.
