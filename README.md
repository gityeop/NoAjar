# NoAjar

NoAjar is a small macOS menu bar app for keeping coding agents alive without
walking around with a MacBook slightly ajar.

It is built for local-agent workflows such as Remodex, Claude Code, OpenCode,
OpenClaw, Codex, SSH, and background build/test work.

## Modes

NoAjar has two user-facing modes:

| Mode | What it does |
| --- | --- |
| Awake Mode | Keeps the Mac awake while the lid is open. This uses a normal macOS sleep assertion and does not change lid-close behavior. |
| No Ajar Mode | Keeps the Mac awake even when the lid is fully closed. This enables `pmset disablesleep 1` while the session is active. |

The menu bar app keeps the main menu intentionally small:

```text
💤

Awake Mode
No Ajar Mode
Turn Off
Wi-Fi
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

Wi-Fi includes:

- Wi-Fi Guard: during an active session, return to a pinned Wi-Fi network if
  macOS switches networks or disconnects.
- Pin Current Wi-Fi: save the currently connected network as the preferred network.
- Input Pinned Network: type the network name manually.
- Block Current Wi-Fi: add the currently connected network to the blocked list.
- Input Blocked Networks: type blocked network names manually.
- Blocked Wi-Fi: remove blocked SSIDs from the preferred network list and
  disconnect from them during an active session.
- Allow Wi-Fi Name Access: request permission needed for Personal Hotspot SSID detection.
  This item is hidden once permission is already granted.

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

Hotkey menu navigation:

- Press the configured hotkey to open the menu.
- Press Cmd-1 for Awake Mode or Cmd-2 for No Ajar Mode.
- Press 1, 2, 3, 4, or 5 to start Until Stopped, 30 Minutes, 1 Hour, 4 Hours,
  or 8 Hours.

Wi-Fi Guard uses macOS `networksetup`. It can reconnect to saved networks, but
it cannot connect to a network whose password is not already available to macOS.
Blocked Wi-Fi is best understood as "avoid and remove from preferred networks",
not a kernel-level network ban.

macOS may hide the current Wi-Fi name, especially for Personal Hotspot, unless
NoAjar has Location permission. If permission has not been granted yet, use
`Wi-Fi > Allow Wi-Fi Name Access`, then try `Pin Current Wi-Fi` again.

## Build

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
