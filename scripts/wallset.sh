#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_WALLPAPER="$REPO_ROOT/assets/gray3.png"
if [[ -f "$REPO_ROOT/reference/mxmrn/desktop.png" ]]; then
    DEFAULT_WALLPAPER="$REPO_ROOT/reference/mxmrn/desktop.png"
elif [[ -f "$REPO_ROOT/reference/mxmrn/.github/desktop.png" ]]; then
    DEFAULT_WALLPAPER="$REPO_ROOT/reference/mxmrn/.github/desktop.png"
fi

WALLPAPER_INPUT="${1:-"$DEFAULT_WALLPAPER"}"

if [[ -d "$WALLPAPER_INPUT" ]]; then
    ABS_PATH="$(cd "$WALLPAPER_INPUT" 2>/dev/null && pwd -P)"
elif [[ -f "$WALLPAPER_INPUT" ]]; then
    ABS_DIR="$(cd "$(dirname "$WALLPAPER_INPUT")" 2>/dev/null && pwd -P)"
    ABS_PATH="$ABS_DIR/$(basename "$WALLPAPER_INPUT")"
else
    ABS_PATH="$WALLPAPER_INPUT"
fi

if [[ ! -f "$ABS_PATH" ]]; then
    echo "Error: Image file not found at $ABS_PATH" >&2
    exit 1
fi

echo "==> Processing theme extraction for wallpaper: $ABS_PATH"

echo "==> Running pywal16 (wal -i \"$ABS_PATH\" -q)..."
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
WAL_BIN="$(command -v wal || true)"
if [[ -z "$WAL_BIN" && -x "$HOME/.local/bin/wal" ]]; then
    WAL_BIN="$HOME/.local/bin/wal"
fi

if [[ -z "$WAL_BIN" ]]; then
    echo "Error: pywal16 (wal) executable not found in PATH or ~/.local/bin" >&2
    exit 1
fi

"$WAL_BIN" -i "$ABS_PATH" -n --cols16 darken --backend wal -q

echo "==> Exporting pywal16 generated configs..."
WAL_CACHE="$HOME/.cache/wal"
mkdir -p "$HOME/.config/hypr"
mkdir -p "$HOME/.config/ghostty"
mkdir -p "$HOME/.config/kitty/colors"
mkdir -p "$HOME/.config/hyprmac"

if [[ -f "$WAL_CACHE/colors-hyprland.conf" ]]; then
    cp "$WAL_CACHE/colors-hyprland.conf" "$HOME/.config/hypr/colors.conf"
    echo "[+] Exported ~/.config/hypr/colors.conf"
fi

if [[ -f "$WAL_CACHE/colors-ghostty" ]]; then
    cp "$WAL_CACHE/colors-ghostty" "$HOME/.config/ghostty/theme-wal"
    echo "[+] Exported ~/.config/ghostty/theme-wal"
fi

if [[ -f "$WAL_CACHE/colors-kitty.conf" ]]; then
    cp "$WAL_CACHE/colors-kitty.conf" "$HOME/.config/kitty/colors/colors.conf"
    echo "[+] Exported ~/.config/kitty/colors/colors.conf"
fi

if [[ -f "$WAL_CACHE/colors-hyprmac.json" ]]; then
    cp "$WAL_CACHE/colors-hyprmac.json" "$HOME/.config/hyprmac/colors.json"
    echo "[+] Exported ~/.config/hyprmac/colors.json"
fi

if [[ -f "$WAL_CACHE/colors-waybar.css" ]]; then
    mkdir -p "$HOME/.config/waybar"
    mkdir -p "$HOME/.cache"
    cp "$WAL_CACHE/colors-waybar.css" "$HOME/.config/waybar/colors.css"
    cp "$WAL_CACHE/colors-waybar.css" "$HOME/.config/waybar/colors-waybar.css"
    cp "$WAL_CACHE/colors-waybar.css" "$HOME/.cache/colors-waybar.css"
    echo "[+] Exported Waybar colors to ~/.config/waybar/ and ~/.cache/"
    pkill -USR2 waybar 2>/dev/null || true
fi

echo "==> Ensuring terminal configurations..."
GHOSTTY_CONFIG="$HOME/.config/ghostty/config"
if [[ -f "$GHOSTTY_CONFIG" ]]; then
    if ! grep -q "theme-wal" "$GHOSTTY_CONFIG"; then
        echo "config-file = theme-wal" >> "$GHOSTTY_CONFIG"
    fi
    touch "$GHOSTTY_CONFIG"
    echo "[+] Updated Ghostty live configuration via touch"
fi

KITTY_CONFIG="$HOME/.config/kitty/kitty.conf"
if [[ -f "$KITTY_CONFIG" ]]; then
    if ! grep -q "colors/colors.conf" "$KITTY_CONFIG"; then
        echo "include colors/colors.conf" >> "$KITTY_CONFIG"
    fi
    killall -SIGUSR1 kitty 2>/dev/null || true
fi

echo "==> Extracting dynamic vibrancy accent and broadcasting terminal palette..."
python3 - "$SCRIPT_DIR" << 'PYEOF'
import sys, os, glob, json

# 1. Execute dynamic vibrancy accent extraction
script_dir = sys.argv[1]
sys.path.insert(0, script_dir)
try:
    import extract_accents
    extract_accents.main()
except Exception as e:
    print(f"[-] Accent extraction failed: {e}", file=sys.stderr)

# 2. Broadcast standard Xterm OSC palette (OSC 11, 10, 12, 4) to active terminals
colors_json = os.path.expanduser("~/.cache/wal/colors.json")
if os.path.exists(colors_json):
    try:
        with open(colors_json, 'r', encoding='utf-8') as f:
            data = json.load(f)

        special = data.get("special", {})
        colors = data.get("colors", {})

        bg = special.get("background", "#000000")
        fg = special.get("foreground", "#ffffff")
        cursor = special.get("cursor", fg)

        # Standard Xterm Operating System Commands (OSC 11=bg, 10=fg, 12=cursor, 4=palette)
        seq = [
            f"]11;{bg}",
            f"]10;{fg}",
            f"]12;{cursor}",
        ]
        for i in range(16):
            c = colors.get(f"color{i}")
            if c:
                seq.append(f"]4;{i};{c}")

        full_seq = "".join(seq)

        with open(os.path.expanduser("~/.cache/wal/sequences.xterm"), 'w', encoding='utf-8') as f:
            f.write(full_seq)

        # Broadcast directly to all user-owned active PTS sessions (Ghostty, etc.)
        for dev in glob.glob("/dev/ttys00[0-9]*"):
            try:
                if os.access(dev, os.W_OK):
                    with open(dev, 'w') as tty:
                        tty.write(full_seq)
            except Exception:
                pass
    except Exception as e:
        print(f"[-] Terminal palette broadcast failed: {e}", file=sys.stderr)
PYEOF

echo "==> Wallset theming applied successfully!"

