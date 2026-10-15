import re

with open('Sources/HyprMac/main.swift', 'r', encoding='utf-8') as f:
    s = f.read()

s = re.sub(r'print("[
]+[+] All ConfigParser', 'print("[+] All ConfigParser', s)
s = re.sub(r'print("[
]+[-] ConfigParser', 'print("[-] ConfigParser', s)
s = re.sub(r'print("[
]+[+] All KeybindManager', 'print("[+] All KeybindManager', s)
s = re.sub(r'print("[
]+[-] KeybindManager', 'print("[-] KeybindManager', s)

with open('Sources/HyprMac/main.swift', 'w', encoding='utf-8') as f:
    f.write(s)

print("FIXED")

