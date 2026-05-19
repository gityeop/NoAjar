# NoAjar

NoAjar is a small macOS menu bar app for keeping coding agents alive without
walking around with a MacBook slightly ajar.

It is built for local-agent workflows such as Remodex, Claude Code, OpenCode,
OpenClaw, Codex, SSH, and background build/test work.

## Modes

NoAjar has two user-facing modes:

| Mode | What it does |
| --- | --- |
| Awake Mode | Keeps the Mac and display awake while the lid is open. This uses normal macOS sleep assertions and does not change lid-close behavior. |
| No Ajar Mode | Keeps the Mac awake even when the lid is fully closed. This enables `pmset disablesleep 1` while allowing the display to sleep by default. |

The menu bar app keeps the main menu intentionally small:

```text
💤

Awake Mode
No Ajar Mode
Turn Off
Apps
Settings
Quit
```

## Menus

The menu bar title changes by state:

- `💤`: inactive.
- `☕`: Awake Mode is active.
- `🚀`: No Ajar Mode is active.

Awake Mode and No Ajar Mode each include:

- Start Until Stopped.
- Start 30 Minutes.
- Start 1 Hour.
- Start 4 Hours.
- Start 8 Hours.
- Stop Below: select the battery percentage where NoAjar automatically ends the session.
- Keep Running: keep the session active without battery-percentage auto stop.

Apps includes:

- App Auto Awake: start automatically while configured app/process names are running.
- Add Apps: choose `.app` bundles directly instead of typing process names.
- Clear Apps: remove the watched app list.
- Mode: choose Awake Mode or No Ajar Mode for App Auto Awake.

When No Ajar Mode is first used, NoAjar installs a small privileged helper.
After that, the app talks to the helper over XPC so No Ajar sessions do not
show administrator prompts every time.

The helper is deliberately narrow:

- It accepts only `enable`, `disable`, and `status`.
- It runs `/usr/bin/pmset` with fixed arguments only.
- It stores the installing app's code signing requirement and rejects XPC
  clients that do not match it.
- It stores its temporary state under `/Library/PrivilegedHelperTools`, not in
  the user's home directory.

Settings includes:

- Hotkey: opens the NoAjar menu. The default is Cmd-Opt-L and can be changed.
  Use Set Hotkey to record a shortcut by pressing the keys directly.
- Launch at Login.
- Check for Updates: opens Sparkle's update checker.
- Automatically Check for Updates: lets Sparkle check the appcast once per day.
- Automatically Install Updates: lets Sparkle download and install updates in the background when possible.
- Version: shows the installed app version and build.

Hotkey menu navigation:

- Press the configured hotkey to open the menu.
- Press Cmd-1 for Awake Mode or Cmd-2 for No Ajar Mode.
- Press 1, 2, 3, 4, or 5 to start Until Stopped, 30 Minutes, 1 Hour, 4 Hours,
  or 8 Hours.

## Build

Build everything:

```sh
make build
```

Build the app bundle:

```sh
make app
```

If a Developer ID Application certificate is installed, `make app` signs the
app and privileged helper with Hardened Runtime enabled. Otherwise it falls
back to ad-hoc signing for local development.

Notarize a Developer ID build:

```sh
make notarize
```

This uses the `FlowClip-Notary` notarytool keychain profile by default. Override
it with `NOTARY_PROFILE=...` if needed. Notarization is required for Gatekeeper
to fully accept a Developer ID build distributed outside your own Mac.

Generate a notarized Sparkle update archive and appcast:

```sh
make appcast RELEASE_NOTES_FILE=/tmp/noajar-release.md
```

Sparkle updates use:

- `SUFeedURL`: `https://github.com/gityeop/NoAjar/releases/latest/download/appcast.xml`
- `SUPublicEDKey`: stored in `Resources/LidAwakeApp/Info.plist`
- private EdDSA key file: `~/.config/noajar/sparkle_ed25519_private_key`

Upload both `build/NoAjar.zip` and `build/appcast.xml` to the GitHub Release.
The first Sparkle-enabled version must still be installed manually; later
versions can update through Sparkle.

The app bundle is created at:

```text
build/NoAjar.app
```

Run it:

```sh
open build/NoAjar.app
```

Remove the privileged helper:

```sh
make uninstall-helper
```

## CLI

The CLI is still named `lid-awake` for now.

No Ajar Mode for eight hours:

```sh
.build/release/lid-awake start --no-ajar --duration 8h
```

Awake Mode for one hour:

```sh
.build/release/lid-awake start --awake --duration 1h
```

Allow battery use, but stop at 40%:

```sh
.build/release/lid-awake start --no-ajar --allow-battery --min-battery 40
```

Check state:

```sh
.build/release/lid-awake status
```

Restore normal sleep:

```sh
.build/release/lid-awake stop
```

## Safety

Do not leave a closed MacBook running in a bag or other enclosed space.
No Ajar Mode can generate heat and drain the battery. Prefer AC power, a stable
surface, and a bounded session time.
