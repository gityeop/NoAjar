# NoAjar - Mac Sleep Control for Local Coding Agents

[한국어](README.ko.md) | English

<p align="center">
  <img src="Assets/noajar-icon.png" alt="NoAjar icon" width="220">
</p>

NoAjar is a small macOS menu bar app for keeping coding agents alive without
walking around with a MacBook slightly ajar.

Use your MacBook with the lid closed.

It is built for local-agent workflows such as Codex, Claude Code, OpenCode,
OpenClaw, SSH, and background build/test work.

## Download

Download the latest release from GitHub:

[Download NoAjar.zip](https://github.com/gityeop/NoAjar/releases/latest/download/NoAjar.zip)

Install it:

1. Download `NoAjar.zip`.
2. Unzip it.
3. Move `NoAjar.app` to `/Applications`.
4. Open NoAjar and use the menu bar icon.

When No Ajar Mode is first used, NoAjar installs a small helper for closed-lid
sleep control, so administrator permission is required.

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

No Ajar Mode installs a helper once, then starts later sessions without showing
an administrator prompt every time.

Settings includes:

- Hotkey: opens the NoAjar menu. The default is Cmd-Opt-L and can be changed.
  Use Set Hotkey to record a shortcut by pressing the keys directly.
- Launch at Login.
- Check for Updates: opens the update checker.
- Automatically Check for Updates: checks for updates once per day.
- Automatically Install Updates: downloads and installs updates in the background when possible.
- Version: shows the installed app version and build.

Hotkey menu navigation:

- Press the configured hotkey to open the menu.
- Press Cmd-1 for Awake Mode or Cmd-2 for No Ajar Mode.
- Press 1, 2, 3, 4, or 5 to start Until Stopped, 30 Minutes, 1 Hour, 4 Hours,
  or 8 Hours.

## Build from Source

Build everything:

```sh
make build
```

Build the app bundle:

```sh
make app
```

The app bundle is created at:

```text
build/NoAjar.app
```

Run it:

```sh
open build/NoAjar.app
```

Remove the helper:

```sh
make uninstall-helper
```

## CLI

The app bundle includes the `noajar` CLI.

Run it directly from the downloaded app:

```sh
/Applications/NoAjar.app/Contents/Helpers/noajar status
```

To make `noajar` available from any terminal:

```sh
sudo ln -sf /Applications/NoAjar.app/Contents/Helpers/noajar /usr/local/bin/noajar
```

No Ajar Mode for eight hours:

```sh
noajar start --no-ajar --duration 8h
```

Awake Mode for one hour:

```sh
noajar start --awake --duration 1h
```

Allow battery use, but stop at 40%:

```sh
noajar start --no-ajar --allow-battery --min-battery 40
```

Check state:

```sh
noajar status
```

Restore normal sleep:

```sh
noajar stop
```

## Safety

Do not leave a closed MacBook running in a bag or other enclosed space.
No Ajar Mode can generate heat and drain the battery. Prefer AC power, a stable
surface, and a bounded session time.
