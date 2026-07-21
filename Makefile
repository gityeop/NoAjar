.PHONY: build app notarize appcast install uninstall uninstall-helper status clean

PREFIX ?= /usr/local
APP_BUNDLE ?= build/NoAjar.app
APP_ARCHIVE ?= build/NoAjar.zip
APPCAST_FILE ?= build/appcast.xml
SPARKLE_ARCHIVES_DIR ?= build/sparkle
SPARKLE_PRIVATE_KEY_FILE = $(HOME)/.config/noajar/sparkle_ed25519_private_key
SPARKLE_BIN_DIR ?= .build/artifacts/sparkle/Sparkle/bin
SPARKLE_GENERATE_APPCAST ?= $(SPARKLE_BIN_DIR)/generate_appcast
VERSION ?= $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/LidAwakeApp/Info.plist)
UPDATE_DOWNLOAD_PREFIX ?= https://github.com/gityeop/NoAjar/releases/download/v$(VERSION)/
NOTARY_PROFILE ?= FlowClip-Notary
SIGN_IDENTITY ?= $(shell /usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -F\" '/Developer ID Application:/ { print $$2; exit }')
CODESIGN_FLAGS := --force --options runtime --timestamp --sign "$(SIGN_IDENTITY)"
SWIFT_BUILD_FLAGS ?= -c release --arch arm64 --arch x86_64

build:
	swift build $(SWIFT_BUILD_FLAGS)

app:
	@test -n "$(SIGN_IDENTITY)" || (echo "Developer ID Application signing identity is required." >&2; exit 2)
	swift build $(SWIFT_BUILD_FLAGS) --product noajar
	swift build $(SWIFT_BUILD_FLAGS) --product noajar-hotspot
	swift build $(SWIFT_BUILD_FLAGS) --product LidAwakeMenuBar
	swift build $(SWIFT_BUILD_FLAGS) --product NoAjarHelper
	rm -rf "$(APP_BUNDLE)"
	install -d "$(APP_BUNDLE)/Contents/MacOS"
	install -d "$(APP_BUNDLE)/Contents/Resources"
	install -d "$(APP_BUNDLE)/Contents/Helpers"
	install -d "$(APP_BUNDLE)/Contents/Frameworks"
	install -d "$(APP_BUNDLE)/Contents/Library/LaunchServices"
	install -d "$(APP_BUNDLE)/Contents/Library/LaunchDaemons"
	set -e; \
	SWIFT_RELEASE_BIN_DIR="$$(swift build $(SWIFT_BUILD_FLAGS) --show-bin-path)"; \
	install -m 0755 "$$SWIFT_RELEASE_BIN_DIR/LidAwakeMenuBar" "$(APP_BUNDLE)/Contents/MacOS/NoAjar"; \
	install -m 0755 "$$SWIFT_RELEASE_BIN_DIR/noajar" "$(APP_BUNDLE)/Contents/Helpers/noajar"; \
	install -m 0755 "$$SWIFT_RELEASE_BIN_DIR/noajar-hotspot" "$(APP_BUNDLE)/Contents/Helpers/noajar-hotspot"; \
	install -m 0755 "$$SWIFT_RELEASE_BIN_DIR/NoAjarHelper" "$(APP_BUNDLE)/Contents/Library/LaunchServices/dev.local.noajar.helper"; \
	test -d "$$SWIFT_RELEASE_BIN_DIR/Sparkle.framework"; \
	ditto "$$SWIFT_RELEASE_BIN_DIR/Sparkle.framework" "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"
	install -m 0644 Resources/NoAjarHelper/dev.local.noajar.helper.plist "$(APP_BUNDLE)/Contents/Library/LaunchDaemons/dev.local.noajar.helper.plist"
	install -m 0644 Resources/LidAwakeApp/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	install -m 0644 Resources/LidAwakeApp/NoAjar.icns "$(APP_BUNDLE)/Contents/Resources/NoAjar.icns"
	install_name_tool -add_rpath "@executable_path/../Frameworks" "$(APP_BUNDLE)/Contents/MacOS/NoAjar"
	codesign $(CODESIGN_FLAGS) --identifier dev.local.noajar.helper "$(APP_BUNDLE)/Contents/Library/LaunchServices/dev.local.noajar.helper"
	codesign $(CODESIGN_FLAGS) "$(APP_BUNDLE)/Contents/Helpers/noajar"
	codesign $(CODESIGN_FLAGS) "$(APP_BUNDLE)/Contents/Helpers/noajar-hotspot"
	codesign $(CODESIGN_FLAGS) --deep "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"
	codesign $(CODESIGN_FLAGS) --deep "$(APP_BUNDLE)"

notarize:
	@test -n "$(NOTARY_PROFILE)" || (echo "Set NOTARY_PROFILE to a stored notarytool keychain profile." >&2; exit 2)
	$(MAKE) app
	rm -f "$(APP_ARCHIVE)"
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(APP_ARCHIVE)"
	xcrun notarytool submit "$(APP_ARCHIVE)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP_BUNDLE)"
	xcrun stapler validate -v "$(APP_BUNDLE)"
	spctl -a -vvv --type execute "$(APP_BUNDLE)"
	rm -f "$(APP_ARCHIVE)"
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(APP_ARCHIVE)"

appcast: notarize
	@test -x "$(SPARKLE_GENERATE_APPCAST)" || (echo "Sparkle generate_appcast not found. Run swift package resolve first." >&2; exit 2)
	@test -f "$(SPARKLE_PRIVATE_KEY_FILE)" || (echo "Sparkle private key not found at $(SPARKLE_PRIVATE_KEY_FILE)." >&2; exit 2)
	rm -rf "$(SPARKLE_ARCHIVES_DIR)"
	install -d "$(SPARKLE_ARCHIVES_DIR)"
	install -m 0644 "$(APP_ARCHIVE)" "$(SPARKLE_ARCHIVES_DIR)/NoAjar.zip"
	if [ -n "$(RELEASE_NOTES_FILE)" ]; then install -m 0644 "$(RELEASE_NOTES_FILE)" "$(SPARKLE_ARCHIVES_DIR)/NoAjar.md"; fi
	"$(SPARKLE_GENERATE_APPCAST)" --ed-key-file "$(SPARKLE_PRIVATE_KEY_FILE)" --download-url-prefix "$(UPDATE_DOWNLOAD_PREFIX)" --embed-release-notes --maximum-versions 1 "$(SPARKLE_ARCHIVES_DIR)"
	install -m 0644 "$(SPARKLE_ARCHIVES_DIR)/appcast.xml" "$(APPCAST_FILE)"

install: build
	install -d "$(PREFIX)/bin"
	install -m 0755 "$(SWIFT_RELEASE_BIN_DIR)/noajar" "$(PREFIX)/bin/noajar"

uninstall:
	rm -f "$(PREFIX)/bin/noajar"

uninstall-helper:
	sudo launchctl bootout system /Library/LaunchDaemons/dev.local.noajar.helper.plist 2>/dev/null || true
	sudo rm -f /Library/LaunchDaemons/dev.local.noajar.helper.plist
	sudo rm -f /Library/PrivilegedHelperTools/dev.local.noajar.helper
	sudo rm -f /Library/PrivilegedHelperTools/dev.local.noajar.helper.clientreq
	sudo rm -f /Library/PrivilegedHelperTools/dev.local.noajar.helper.state.json

status:
	swift run noajar status

clean:
	rm -rf .build build
