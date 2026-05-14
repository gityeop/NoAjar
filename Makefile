.PHONY: build app notarize install uninstall uninstall-helper status clean

PREFIX ?= /usr/local
APP_BUNDLE ?= build/NoAjar.app
APP_ARCHIVE ?= build/NoAjar.zip
NOTARY_PROFILE ?= FlowClip-Notary
SIGN_IDENTITY ?= $(shell /usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/awk -F\" '/Developer ID Application:/ { print $$2; exit }')
SIGN_IDENTITY := $(if $(strip $(SIGN_IDENTITY)),$(SIGN_IDENTITY),-)
TIMESTAMP_FLAG := $(if $(filter -,$(SIGN_IDENTITY)),,--timestamp)
CODESIGN_FLAGS := --force --options runtime $(TIMESTAMP_FLAG) --sign "$(SIGN_IDENTITY)"

build:
	swift build -c release

app:
	swift build -c release --product LidAwakeMenuBar
	swift build -c release --product NoAjarHelper
	rm -rf "$(APP_BUNDLE)"
	install -d "$(APP_BUNDLE)/Contents/MacOS"
	install -d "$(APP_BUNDLE)/Contents/Resources"
	install -d "$(APP_BUNDLE)/Contents/Library/LaunchServices"
	install -d "$(APP_BUNDLE)/Contents/Library/LaunchDaemons"
	install -m 0755 .build/release/LidAwakeMenuBar "$(APP_BUNDLE)/Contents/MacOS/NoAjar"
	install -m 0755 .build/release/NoAjarHelper "$(APP_BUNDLE)/Contents/Library/LaunchServices/dev.local.noajar.helper"
	install -m 0644 Resources/NoAjarHelper/dev.local.noajar.helper.plist "$(APP_BUNDLE)/Contents/Library/LaunchDaemons/dev.local.noajar.helper.plist"
	install -m 0644 Resources/LidAwakeApp/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	install -m 0644 Resources/LidAwakeApp/NoAjar.icns "$(APP_BUNDLE)/Contents/Resources/NoAjar.icns"
	codesign $(CODESIGN_FLAGS) --identifier dev.local.noajar.helper "$(APP_BUNDLE)/Contents/Library/LaunchServices/dev.local.noajar.helper"
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

install: build
	install -d "$(PREFIX)/bin"
	install -m 0755 .build/release/lid-awake "$(PREFIX)/bin/lid-awake"

uninstall:
	rm -f "$(PREFIX)/bin/lid-awake"

uninstall-helper:
	sudo launchctl bootout system /Library/LaunchDaemons/dev.local.noajar.helper.plist 2>/dev/null || true
	sudo rm -f /Library/LaunchDaemons/dev.local.noajar.helper.plist
	sudo rm -f /Library/PrivilegedHelperTools/dev.local.noajar.helper
	sudo rm -f /Library/PrivilegedHelperTools/dev.local.noajar.helper.clientreq
	sudo rm -f /Library/PrivilegedHelperTools/dev.local.noajar.helper.state.json

status:
	swift run lid-awake status

clean:
	rm -rf .build build
