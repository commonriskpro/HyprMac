#!/usr/bin/env python3
import json
import colorsys
import os
import re
import sys

def main():
    colors_json_path = os.path.expanduser("~/.cache/wal/colors.json")
    if not os.path.exists(colors_json_path):
        return

    try:
        with open(colors_json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"[-] Failed to read {colors_json_path}: {e}", file=sys.stderr)
        return

    colors = data.get("colors", {})
    scored = []

    for i in range(1, 15):
        k = f"color{i}"
        hex_val = colors.get(k, "").lstrip("#")
        if len(hex_val) != 6:
            continue
        try:
            r, g, b = (int(hex_val[j:j+2], 16) / 255.0 for j in (0, 2, 4))
            h, s, v = colorsys.rgb_to_hsv(r, g, b)
            score = s * v
            scored.append((score, f"#{hex_val.upper()}", h * 360, s, v))
        except ValueError:
            continue

    scored.sort(key=lambda x: x[0], reverse=True)

    default_primary = colors.get("color4", "#E4A136").upper()
    accent1 = scored[0][1] if scored else default_primary
    accent2 = scored[1][1] if len(scored) > 1 else accent1
    for item in scored[1:]:
        if item[1] != accent1:
            accent2 = item[1]
            break

    accent3 = scored[2][1] if len(scored) > 2 else accent2
    for item in scored[2:]:
        if item[1] != accent1 and item[1] != accent2:
            accent3 = item[1]
            break

    print(f"    [+] Dynamic Primary Accent   (Rank 1): {accent1}")
    print(f"    [+] Dynamic Secondary Accent (Rank 2): {accent2}")
    print(f"    [+] Dynamic Tertiary Accent  (Rank 3): {accent3}")

    a1_raw = accent1.lstrip("#")
    a2_raw = accent2.lstrip("#")

    # 1. Update ~/.config/hypr/colors.conf with dynamic accents
    hypr_colors_path = os.path.expanduser("~/.config/hypr/colors.conf")
    if os.path.exists(hypr_colors_path):
        try:
            with open(hypr_colors_path, "r", encoding="utf-8") as f:
                clines = f.readlines()
            out_lines = []
            for cl in clines:
                if cl.startswith("$active_border_1"):
                    out_lines.append(f"$active_border_1 = rgba({a1_raw}ee)\n")
                elif cl.startswith("$active_border_2"):
                    out_lines.append(f"$active_border_2 = rgba({a2_raw}ee)\n")
                elif not cl.startswith("$accent"):
                    out_lines.append(cl)
            out_lines.append(f"$accent = rgba({a1_raw}ee)\n")
            out_lines.append(f"$accent_secondary = rgba({a2_raw}ee)\n")
            with open(hypr_colors_path, "w", encoding="utf-8") as f:
                f.writelines(out_lines)
            print("[+] Updated ~/.config/hypr/colors.conf with dynamic active_border accents")
        except Exception as e:
            print(f"[-] Failed to update hypr colors: {e}", file=sys.stderr)

    # 2. Update ~/.config/hyprmac/colors.json
    hyprmac_json_path = os.path.expanduser("~/.config/hyprmac/colors.json")
    if os.path.exists(hyprmac_json_path):
        try:
            with open(hyprmac_json_path, "r", encoding="utf-8") as f:
                hdata = json.load(f)
            hdata["primary"] = accent1
            hdata["secondary"] = accent2
            hdata["tertiary"] = accent3
            hdata["accent"] = accent1
            with open(hyprmac_json_path, "w", encoding="utf-8") as f:
                json.dump(hdata, f, indent=2)
            print("[+] Updated ~/.config/hyprmac/colors.json with dynamic primary/secondary accents")
        except Exception as e:
            print(f"[-] Failed to update hyprmac colors: {e}", file=sys.stderr)

    # 3. Synchronize all Waybar color definitions (colors.css and colors-waybar.css)
    waybar_targets = [
        os.path.expanduser("~/.config/waybar/colors.css"),
        os.path.expanduser("~/.config/waybar/colors-waybar.css"),
        os.path.expanduser("~/.cache/colors-waybar.css")
    ]
    for waybar_css_path in waybar_targets:
        if os.path.exists(waybar_css_path):
            try:
                with open(waybar_css_path, "r", encoding="utf-8") as f:
                    css_text = f.read()
                css_text = re.sub(r"@define-color\s+primary\s+[^;]+;", f"@define-color primary {accent1};", css_text)
                css_text = re.sub(r"@define-color\s+secondary\s+[^;]+;", f"@define-color secondary {accent2};", css_text)
                css_text = re.sub(r"@define-color\s+tertiary\s+[^;]+;", f"@define-color tertiary {accent3};", css_text)
                if "@define-color accent" not in css_text:
                    css_text += f"\n@define-color accent {accent1};\n"
                else:
                    css_text = re.sub(r"@define-color\s+accent\s+[^;]+;", f"@define-color accent {accent1};", css_text)
                with open(waybar_css_path, "w", encoding="utf-8") as f:
                    f.write(css_text)
                print(f"[+] Synchronized {waybar_css_path} with dynamic primary/secondary accents")
            except Exception as e:
                print(f"[-] Failed to update {waybar_css_path}: {e}", file=sys.stderr)

if __name__ == "__main__":
    main()
