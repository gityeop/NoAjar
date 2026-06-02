# NoAjar - Mac Sleep Control for Local Coding Agents

[한국어](README.ko.md) | English

<p align="center">
  <img src="Assets/noajar-icon.png" alt="NoAjar icon" width="220">
</p>

NoAjar is a small macOS menu bar app for keeping local coding agents and
long-running developer workflows alive.

It is built for Codex, Claude Code, OpenCode, OpenClaw, SSH sessions,
background builds, and tests that should keep running even when your Mac would
normally sleep.

## Release Channels

| Channel | Download | Use this when | Current scope |
| --- | --- | --- | --- |
| Stable | [Download latest stable](https://github.com/gityeop/NoAjar/releases/latest/download/NoAjar.zip) | You want the recommended public build. | Core Awake Mode, No Ajar Mode, App Auto Awake, duration controls, battery guard, menu UX, Universal 2 build, and one-time beta update checks. |
| Beta | [Download beta](https://github.com/gityeop/NoAjar/releases/download/beta/NoAjar.zip) | You want to test new features and send feedback. | Everything in stable, plus Keep Hotspot Connected and recurring schedules. |

If you already use the stable app, open `Settings` -> `Try Beta Updates` to
check the beta update feed once. This does not permanently switch the stable
update channel.

## Install

1. Download `NoAjar.zip`.
2. Unzip it.
3. Move `NoAjar.app` to `/Applications`.
4. Open NoAjar and use the menu bar icon.

When No Ajar Mode is first used, NoAjar installs a small helper for closed-lid
sleep control, so administrator permission is required once.

NoAjar requires macOS 13 or later. Current stable and beta builds are Universal
2 apps for Apple Silicon and Intel Macs.

## Modes

NoAjar has two user-facing modes:

| Mode | What it does |
| --- | --- |
| Awake Mode | Keeps the Mac and display awake while the lid is open. This uses normal macOS sleep assertions and does not change lid-close behavior. |
| No Ajar Mode | Keeps the Mac awake even when the lid is fully closed. This enables `pmset disablesleep 1` while allowing the display to sleep by default. |

No Ajar Mode installs the helper once, then later sessions can start without
showing an administrator prompt every time.

## Stable Features

The stable menu is organized around the current state, mode selection, duration,
app automation, and settings.

```text
Status

No Ajar Mode
Awake Mode
Duration

Apps
Settings

Quit
```

The menu bar title changes by state:

- `💤`: inactive.
- `☕`: Awake Mode is active.
- `🚀`: No Ajar Mode is active.

Mode items are toggles. Click the active mode again to stop the current session.

### Duration

`Duration` applies to the next manually started mode, and changing it while a
mode is active restarts that mode with the selected duration.

Duration options:

- Until Stopped
- 30 Minutes
- 1 Hour
- 4 Hours
- 8 Hours
- Stop Below: Keep Running, 20%, 30%, 40%, or 50%

### Apps

`Apps` includes:

- App Auto Awake: start automatically while configured app/process names are running.
- Add Apps: choose `.app` bundles directly.
- Clear Apps: remove the watched app list.
- Mode: choose Awake Mode or No Ajar Mode for App Auto Awake.
- Apps: shows the current watched app names.

### Settings

`Settings` includes:

- Hotkey: opens the NoAjar menu. The default is `Cmd-Opt-L`.
- Hotkey -> Enabled: turns the global hotkey on or off.
- Hotkey -> Set Hotkey: records a new shortcut by pressing the keys directly.
- Launch at Login.
- Check for Updates.
- Automatically Check for Updates.
- Automatically Install Updates.
- Try Beta Updates: checks the beta feed once.
- Version: shows the installed version and build.

The hotkey opens the menu only. It does not currently provide `Cmd-1`, `Cmd-2`,
or number-key shortcuts for selecting menu items.

## Beta Features

The beta channel currently adds Keep Hotspot Connected and recurring schedules.
These features are still being tested, especially across different Mac models
and iPhone hotspot conditions.

### Keep Hotspot Connected

In the beta menu, `Keep Hotspot Connected` appears between `Schedule` and
`Apps`.

It includes:

- Keep Hotspot Connected: turns the feature on or off.
- Hotspot: shows the saved target hotspot name.
- Use Current Wi-Fi as Hotspot: saves the currently connected Wi-Fi name as the target hotspot and turns the feature on.
- Forget Hotspot: clears the saved target hotspot.

While No Ajar Mode is active, NoAjar can keep checking the saved hotspot and
ask macOS to reconnect if Wi-Fi drops or moves to another network. If the saved
hotspot appears only as an Instant Hotspot, the beta uses an experimental macOS
private API fallback before joining the Wi-Fi network.

This helps with iPhone hotspot interruptions, but it cannot force iOS to
advertise a hidden or unavailable hotspot.

When a saved hotspot exists and you manually start No Ajar Mode, NoAjar asks
whether to keep that hotspot connected. Scheduled No Ajar sessions do not show
that prompt; they use the per-schedule hotspot setting.

### Schedule

In the beta menu, `Schedule` appears below `Duration`.

The menu title is:

- `Schedule: Off`
- `Schedule: 1 Rule`
- `Schedule: N Rules`
- `Schedule: Active`

`Schedule` includes:

- Edit Schedules...
- Active or next schedule summary

The schedule editor supports:

- A global Scheduled Mode checkbox.
- Multiple enabled or disabled rules.
- Awake Mode or No Ajar Mode per rule.
- Weekday selection.
- Start and end times.
- Per-rule Hotspot checkbox for No Ajar schedules.
- Delete rule.
- Add Rule, Cancel, and Save.

Rules cannot overlap on the same day. Adjacent rules such as `09:00-12:00` and
`12:00-18:00` are allowed. If an end time is earlier than or equal to the start
time, the rule is treated as an overnight schedule.

Schedules run only while NoAjar is open. Use `Settings` -> `Launch at Login` if
you want schedules to work after reboot/login.

If a scheduled session starts and you manually stop it or switch modes, NoAjar
will not restart that same schedule window until it ends. The next schedule
window works normally.

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

Keep the display awake too:

```sh
noajar start --duration 1h --display-awake
```

Beta CLI hotspot commands:

```sh
noajar start --no-ajar --hotspot-keepalive
noajar start --no-ajar --hotspot-ssid "My iPhone"
noajar hotspot-keepalive --hotspot-ssid "My iPhone" --force-reconnect
```

Check state:

```sh
noajar status
```

Restore normal sleep:

```sh
noajar stop
```

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

## Safety

Do not leave a closed MacBook running in a bag or other enclosed space.
No Ajar Mode can generate heat and drain the battery. Prefer AC power, a stable
surface, and a bounded session time.
