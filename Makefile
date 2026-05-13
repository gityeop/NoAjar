.PHONY: build app install uninstall uninstall-helper status clean

PREFIX ?= /usr/local

build:
	swift build -c release

app:
	swift build -c release --product LidAwakeMenuBar
	swift build -c release --product NoAjarHelper
	rm -rf build/NoAjar.app
	install -d build/NoAjar.app/Contents/MacOS
	install -d build/NoAjar.app/Contents/Resources
	install -d build/NoAjar.app/Contents/Library/LaunchServices
	install -d build/NoAjar.app/Contents/Library/LaunchDaemons
	install -m 0755 .build/release/LidAwakeMenuBar build/NoAjar.app/Contents/MacOS/NoAjar
	install -m 0755 .build/release/NoAjarHelper build/NoAjar.app/Contents/Library/LaunchServices/dev.local.noajar.helper
	install -m 0644 Resources/NoAjarHelper/dev.local.noajar.helper.plist build/NoAjar.app/Contents/Library/LaunchDaemons/dev.local.noajar.helper.plist
	install -m 0644 Resources/LidAwakeApp/Info.plist build/NoAjar.app/Contents/Info.plist
	codesign --force --identifier dev.local.noajar.helper --sign - build/NoAjar.app/Contents/Library/LaunchServices/dev.local.noajar.helper
	codesign --force --deep --sign - build/NoAjar.app

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
