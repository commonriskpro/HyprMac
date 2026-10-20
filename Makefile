# HyprMac Native Build System
# Builds hypr-inject (Mach injector) and libhyprserver.dylib (WindowServer hook)
# This is parallel to the Swift Package Manager build for HyprMac.app

CC = clang
AS = clang

ARCH_FLAGS = -arch arm64e -target arm64e-apple-macos27.0
PAC_FLAGS = -fptrauth-calls -fptrauth-intrinsics
CFLAGS = $(ARCH_FLAGS) $(PAC_FLAGS) -std=c11 -Wall -Wextra -Werror -O2 -fvisibility=hidden
DYLIB_FLAGS = -dynamiclib -install_name @rpath/libhyprserver.dylib

# Code signing identity
# Automatically detects valid Developer ID Application or Apple Development certificate; falls back to ad-hoc (-)
AUTO_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application:" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
ifeq ($(strip $(AUTO_IDENTITY)),)
AUTO_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development:" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
endif

SIGN_IDENTITY ?= $(if $(strip $(AUTO_IDENTITY)),$(AUTO_IDENTITY),-)

CODESIGN_FLAGS = --force
ifneq ($(SIGN_IDENTITY),-)
CODESIGN_FLAGS += --timestamp
endif

BUILD_DIR = build

.PHONY: all clean hook injector client install install-daemon uninstall-daemon app install-app install-agent uninstall package

install: install-daemon install-agent

install-agent: app
	@mkdir -p $(HOME)/Library/LaunchAgents
	cp -f native/daemon/com.hyprmac.daemon.plist $(HOME)/Library/LaunchAgents/com.hyprmac.daemon.plist
	launchctl bootout gui/$$(id -u)/com.hyprmac.daemon 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) $(HOME)/Library/LaunchAgents/com.hyprmac.daemon.plist 2>/dev/null || \
	launchctl load -w $(HOME)/Library/LaunchAgents/com.hyprmac.daemon.plist
	@sudo ln -sf /Applications/HyprMac.app/Contents/MacOS/HyprMac /usr/local/bin/hyprmac
	@sudo ln -sf /Applications/HyprMac.app/Contents/MacOS/HyprMac /usr/local/bin/HyprMac

uninstall:
	@./uninstall.sh

package: all
	@mkdir -p dist/package/build dist/package/native/injector dist/package/native/daemon
	@cp -R /Applications/HyprMac.app dist/package/build/HyprMac.app
	@cp $(BUILD_DIR)/hypr-inject dist/package/build/hypr-inject
	@cp $(BUILD_DIR)/libhyprserver.dylib dist/package/build/libhyprserver.dylib
	@cp $(BUILD_DIR)/libhyprclient.dylib dist/package/build/libhyprclient.dylib
	@cp native/injector/com.hyprmac.inject.plist dist/package/native/injector/
	@cp native/daemon/com.hyprmac.daemon.plist dist/package/native/daemon/
	@cp install.sh dist/package/
	@cp uninstall.sh dist/package/
	@tar -czf dist/HyprMac-arm64e.tar.gz -C dist/package .
	@rm -rf dist/package
	@echo "✓ Distribution bundle packaged at dist/HyprMac-arm64e.tar.gz"

all: hook injector client app

app: client
	swift build -c release
	@mkdir -p /Applications/HyprMac.app/Contents/MacOS
	@cp .build/release/HyprMac /Applications/HyprMac.app/Contents/MacOS/HyprMac
	@cp $(BUILD_DIR)/libhyprclient.dylib /Applications/HyprMac.app/Contents/MacOS/libhyprclient.dylib
	codesign -s "$(SIGN_IDENTITY)" $(CODESIGN_FLAGS) /Applications/HyprMac.app/Contents/MacOS/libhyprclient.dylib
	codesign -s "$(SIGN_IDENTITY)" $(CODESIGN_FLAGS) /Applications/HyprMac.app/Contents/MacOS/HyprMac
	codesign -s "$(SIGN_IDENTITY)" $(CODESIGN_FLAGS) /Applications/HyprMac.app

install-app: app
	launchctl kickstart -k gui/$$(id -u)/com.hyprmac.daemon

hook: $(BUILD_DIR)/libhyprserver.dylib

injector: $(BUILD_DIR)/hypr-inject

client: $(BUILD_DIR)/libhyprclient.dylib

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/libhyprclient.dylib: native/client_hook/client.m | $(BUILD_DIR)
	$(CC) -arch arm64e -target arm64e-apple-macos27.0 -fobjc-arc -O2 -dynamiclib \
		-framework AppKit -framework Foundation -framework QuartzCore \
		-o $@ native/client_hook/client.m
	codesign -s "$(SIGN_IDENTITY)" $(CODESIGN_FLAGS) $@

$(BUILD_DIR)/libhyprserver.dylib: native/server_hook/hook.c native/shared/protocol.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(DYLIB_FLAGS) \
		-framework CoreFoundation \
		-o $@ native/server_hook/hook.c
	codesign -s "$(SIGN_IDENTITY)" $(CODESIGN_FLAGS) $@

$(BUILD_DIR)/hypr-inject: native/injector/main.c native/shared/protocol.h native/injector/entitlements.plist | $(BUILD_DIR)
	$(CC) $(CFLAGS) \
		-o $@ native/injector/main.c
	codesign -s "$(SIGN_IDENTITY)" $(CODESIGN_FLAGS) --entitlements native/injector/entitlements.plist $@

install-daemon: $(BUILD_DIR)/hypr-inject $(BUILD_DIR)/libhyprserver.dylib
	sudo cp $(BUILD_DIR)/hypr-inject /usr/local/bin/
	sudo cp $(BUILD_DIR)/libhyprserver.dylib /usr/local/lib/
	sudo cp native/injector/com.hyprmac.inject.plist /Library/LaunchDaemons/
	sudo launchctl load /Library/LaunchDaemons/com.hyprmac.inject.plist

uninstall-daemon:
	-sudo launchctl unload /Library/LaunchDaemons/com.hyprmac.inject.plist
	-sudo rm /Library/LaunchDaemons/com.hyprmac.inject.plist
	-sudo rm /usr/local/bin/hypr-inject
	-sudo rm /usr/local/lib/libhyprserver.dylib

clean:
	rm -rf $(BUILD_DIR)

