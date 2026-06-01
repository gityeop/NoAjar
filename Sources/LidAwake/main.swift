import Darwin
import Foundation
import LidAwakeCore

private func printUsage() {
    print("""
    Usage:
      noajar start [--awake|--no-ajar] [--allow-battery] [--no-battery-guard] [--min-battery PERCENT] [--duration 2h|30m|1800] [--display-awake] [--hotspot-keepalive] [--hotspot-ssid SSID]
      noajar stop
      noajar status
      noajar hotspot-keepalive [--hotspot-ssid SSID] [--force-reconnect]

    Examples:
      noajar start --no-ajar --duration 8h
      noajar start --awake --duration 1h
      noajar start --duration 1h --display-awake
      noajar start --allow-battery --min-battery 40
      noajar start --no-ajar --hotspot-keepalive
      noajar start --no-ajar --hotspot-ssid "My iPhone"
      noajar hotspot-keepalive --hotspot-ssid "My iPhone" --force-reconnect
      noajar stop
    """)
}

private func parseOptions(_ args: [String]) throws -> LidAwakeOptions {
    var options = LidAwakeOptions()
    var index = 0

    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--awake":
            options.mode = .awake
            index += 1
        case "--no-ajar":
            options.mode = .noAjar
            index += 1
        case "--allow-battery":
            options.allowBattery = true
            index += 1
        case "--no-battery-guard":
            options.batteryGuardEnabled = false
            index += 1
        case "--display-awake":
            options.preventDisplaySleep = true
            index += 1
        case "--hotspot-keepalive":
            options.hotspotKeepaliveEnabled = true
            index += 1
        case "--hotspot-ssid":
            guard index + 1 < args.count else {
                throw LidAwakeError("Expected --hotspot-ssid to be followed by a Wi-Fi network name.")
            }
            let ssid = args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ssid.isEmpty else {
                throw LidAwakeError("Expected --hotspot-ssid to be followed by a Wi-Fi network name.")
            }
            options.hotspotSSID = ssid
            options.hotspotKeepaliveEnabled = true
            index += 2
        case "--min-battery":
            guard index + 1 < args.count, let percent = Int(args[index + 1]), (1...100).contains(percent) else {
                throw LidAwakeError("Expected --min-battery to be an integer from 1 to 100.")
            }
            options.minBatteryPercent = percent
            index += 2
        case "--duration":
            guard index + 1 < args.count, let seconds = parseDuration(args[index + 1]) else {
                throw LidAwakeError("Expected --duration like 30m, 2h, or 1800.")
            }
            options.durationSeconds = seconds
            index += 2
        default:
            throw LidAwakeError("Unknown option: \(arg)")
        }
    }

    return options
}

private func start(_ options: LidAwakeOptions) throws -> Never {
    let session = LidAwakeSession(options: options)
    try session.start()
    let signalSources = installSignalCleanup {
        session.stop()
    }

    print("\(options.mode.displayName) is active.")
    print("Sleep assertion active. Press Ctrl-C or run `noajar stop` to restore.")
    runHotspotKeepaliveIfEnabled(options)

    while true {
        withExtendedLifetime(signalSources) {}
        Thread.sleep(forTimeInterval: 30)
        runHotspotKeepaliveIfEnabled(options)

        if let reason = session.safetyStopReason() {
            fputs("\(reason) Stopping for safety.\n", stderr)
            session.stop()
            exit(0)
        }
    }
}

private func runHotspotKeepaliveIfEnabled(_ options: LidAwakeOptions) {
    guard options.hotspotKeepaliveEnabled,
          options.mode == .noAjar else { return }
    let result = performHotspotKeepalive(
        targetSSID: options.hotspotSSID,
        forceReconnect: options.hotspotSSID != nil
    )
    if !result.success || result.didReconnect {
        fputs("\(result.message)\n", stderr)
    }
}

private func runHotspotKeepaliveCommand(_ args: [String]) throws -> Never {
    var targetSSID: String?
    var forceReconnect = false
    var index = 0

    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--hotspot-ssid":
            guard index + 1 < args.count else {
                throw LidAwakeError("Expected --hotspot-ssid to be followed by a Wi-Fi network name.")
            }
            let ssid = args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ssid.isEmpty else {
                throw LidAwakeError("Expected --hotspot-ssid to be followed by a Wi-Fi network name.")
            }
            targetSSID = ssid
            index += 2
        case "--force-reconnect":
            forceReconnect = true
            index += 1
        default:
            throw LidAwakeError("Unknown option: \(arg)")
        }
    }

    performHotspotKeepaliveAndExit(
        targetSSID: targetSSID,
        forceReconnect: forceReconnect,
        exitHandler: printHotspotKeepaliveResultAndExit
    )
}

private func printHotspotKeepaliveResultAndExit(_ result: HotspotKeepaliveResult) -> Never {
    print("success=\(result.success ? 1 : 0)")
    print("didReconnect=\(result.didReconnect ? 1 : 0)")
    print("message=\(result.message)")
    fflush(stdout)
    fflush(stderr)
    _exit(result.success ? 0 : 1)
}

private func status() {
    let snapshot = statusSnapshot()

    print("disablesleep: \(snapshot.disableSleep.map(String.init) ?? "not set")")
    print("power: \(snapshot.power.source)\(snapshot.power.percent.map { " \($0)%" } ?? "")")
    let wifi = wifiStatus()
    let wifiLabel = wifi.currentSSID ?? (wifi.linkActive ? "name unavailable" : "not connected")
    print("wi-fi: \(wifiLabel)\(wifi.interface.map { " (\($0))" } ?? "")")

    if let state = snapshot.state {
        print("state file: \(lidAwakeStateURL.path)")
        print("started: \(state.startedAt)")
        print("pid: \(state.pid) \(snapshot.isStateProcessRunning ? "running" : "not running")")
        print("previous disablesleep: \(state.previousDisableSleep.map(String.init) ?? "not set")")
    } else {
        print("state file: none")
    }
}

let args = Array(CommandLine.arguments.dropFirst())

do {
    guard let command = args.first else {
        printUsage()
        exit(2)
    }

    switch command {
    case "start":
        let options = try parseOptions(Array(args.dropFirst()))
        try start(options)
    case "stop":
        stopExistingSessionOrRestore()
    case "status":
        status()
    case "hotspot-keepalive":
        try runHotspotKeepaliveCommand(Array(args.dropFirst()))
    case "-h", "--help", "help":
        printUsage()
    default:
        throw LidAwakeError("Unknown command: \(command)")
    }
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
