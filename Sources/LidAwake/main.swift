import Foundation
import LidAwakeCore

private func printUsage() {
    print("""
    Usage:
      lid-awake start [--awake|--no-ajar] [--allow-battery] [--no-battery-guard] [--min-battery PERCENT] [--duration 2h|30m|1800] [--display-awake]
      lid-awake stop
      lid-awake status

    Examples:
      lid-awake start --no-ajar --duration 8h
      lid-awake start --awake --duration 1h
      lid-awake start --duration 1h --display-awake
      lid-awake start --allow-battery --min-battery 40
      lid-awake stop
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
    print("Sleep assertion active. Press Ctrl-C or run `lid-awake stop` to restore.")

    while true {
        withExtendedLifetime(signalSources) {}
        Thread.sleep(forTimeInterval: 30)

        if let reason = session.safetyStopReason() {
            fputs("\(reason) Stopping for safety.\n", stderr)
            session.stop()
            exit(0)
        }
    }
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
    case "-h", "--help", "help":
        printUsage()
    default:
        throw LidAwakeError("Unknown command: \(command)")
    }
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
