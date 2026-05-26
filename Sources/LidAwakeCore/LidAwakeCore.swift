import Dispatch
import CoreWLAN
import Foundation
import IOKit.pwr_mgt

public let noAjarHelperLabel = "dev.local.noajar.helper"
public let noAjarHelperToolURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/\(noAjarHelperLabel)")
public let noAjarHelperClientRequirementURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/\(noAjarHelperLabel).clientreq")
public let noAjarHelperStateURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/\(noAjarHelperLabel).state.json")
public let noAjarHelperLaunchDaemonURL = URL(fileURLWithPath: "/Library/LaunchDaemons/\(noAjarHelperLabel).plist")

public let lidAwakeStateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".noajar-state.json")

@objc(NoAjarHelperProtocol)
public protocol NoAjarHelperProtocol {
    func enableNoAjar(withReply reply: @escaping (Bool, NSString?) -> Void)
    func disableNoAjar(withReply reply: @escaping (Bool, NSString?) -> Void)
    func status(withReply reply: @escaping (Bool, NSString?) -> Void)
}

public enum AwakeMode: String, CaseIterable, Codable {
    case awake
    case noAjar

    public var displayName: String {
        switch self {
        case .awake:
            "Awake Mode"
        case .noAjar:
            "No Ajar Mode"
        }
    }

    public var preventsLidSleep: Bool {
        self == .noAjar
    }

    public var preventsDisplaySleep: Bool {
        switch self {
        case .awake:
            true
        case .noAjar:
            false
        }
    }
}

public struct LidAwakeState: Codable {
    public let previousDisableSleep: Int?
    public let startedAt: Date
    public let pid: Int32
}

public struct LidAwakeOptions {
    public var mode: AwakeMode
    public var allowBattery: Bool
    public var batteryGuardEnabled: Bool
    public var minBatteryPercent: Int
    public var durationSeconds: TimeInterval?
    public var preventDisplaySleep: Bool
    public var manageLidSleepOverride: Bool
    public var reason: String

    public init(
        mode: AwakeMode = .noAjar,
        allowBattery: Bool = false,
        batteryGuardEnabled: Bool = true,
        minBatteryPercent: Int = 30,
        durationSeconds: TimeInterval? = nil,
        preventDisplaySleep: Bool = false,
        manageLidSleepOverride: Bool = true,
        reason: String = "NoAjar"
    ) {
        self.mode = mode
        self.allowBattery = allowBattery
        self.batteryGuardEnabled = batteryGuardEnabled
        self.minBatteryPercent = minBatteryPercent
        self.durationSeconds = durationSeconds
        self.preventDisplaySleep = preventDisplaySleep
        self.manageLidSleepOverride = manageLidSleepOverride
        self.reason = reason
    }
}

public struct LidAwakePowerStatus {
    public let source: String
    public let percent: Int?
}

public struct LidAwakeStatus {
    public let disableSleep: Int?
    public let power: LidAwakePowerStatus
    public let state: LidAwakeState?

    public var isStateProcessRunning: Bool {
        guard let state else { return false }
        return processIsRunning(pid: state.pid)
    }
}

public struct WiFiStatus {
    public let interface: String?
    public let currentSSID: String?
    public let linkActive: Bool
}

public final class LidAwakeSession {
    private let options: LidAwakeOptions
    private var systemAssertionID = IOPMAssertionID(0)
    private var displayAssertionID = IOPMAssertionID(0)
    private var startedAt: Date?
    private var didOverrideLidSleep = false
    private var lidSleepMarkerURL: URL?
    private var lidSleepHelper: Process?

    public init(options: LidAwakeOptions) {
        self.options = options
    }

    public func start() throws {
        let initialPower = powerStatus()
        if !options.allowBattery, initialPower.source == "Battery Power" {
            throw LidAwakeError("Refusing to start on battery power. Enable battery mode to override.")
        }
        if options.batteryGuardEnabled,
           let percent = initialPower.percent,
           percent <= options.minBatteryPercent {
            throw LidAwakeError("Refusing to start because battery is \(percent)%, at or below \(options.minBatteryPercent)%.")
        }

        var didSaveState = false
        do {
            if options.mode.preventsLidSleep && options.manageLidSleepOverride {
                let previous = currentDisableSleep()
                try saveState(previousDisableSleep: previous)
                didSaveState = true
                try startPrivilegedLidSleepHelper(previousDisableSleep: previous ?? 0)
                didOverrideLidSleep = true
            }
            systemAssertionID = try createSleepAssertion(
                type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                reason: options.reason
            )
            if options.preventDisplaySleep || options.mode.preventsDisplaySleep {
                displayAssertionID = try createSleepAssertion(
                    type: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    reason: "\(options.reason) Display"
                )
            }
            startedAt = Date()
        } catch {
            if displayAssertionID != 0 {
                IOPMAssertionRelease(displayAssertionID)
                displayAssertionID = 0
            }
            if systemAssertionID != 0 {
                IOPMAssertionRelease(systemAssertionID)
                systemAssertionID = 0
            }
            if didSaveState {
                stopPrivilegedLidSleepHelper()
                removeState()
            }
            throw error
        }
    }

    public func stop() {
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
        if systemAssertionID != 0 {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
        }
        if didOverrideLidSleep {
            stopPrivilegedLidSleepHelper()
            removeState()
            didOverrideLidSleep = false
        }
    }

    public func safetyStopReason() -> String? {
        if let duration = options.durationSeconds,
           let startedAt,
           Date().timeIntervalSince(startedAt) >= duration {
            return "Duration reached."
        }

        let status = powerStatus()
        if !options.allowBattery, status.source == "Battery Power" {
            return "Power source changed to battery."
        }

        if options.batteryGuardEnabled,
           let percent = status.percent,
           percent <= options.minBatteryPercent {
            return "Battery is \(percent)%, at or below \(options.minBatteryPercent)%."
        }

        return nil
    }

    public func repairPowerSettingsIfNeeded() -> String? {
        guard options.mode.preventsLidSleep,
              options.manageLidSleepOverride,
              currentDisableSleep() != 1 else { return nil }

        if lidSleepHelper?.isRunning == true {
            return "Waiting for No Ajar authorization."
        }

        return "No Ajar helper stopped. Turn the mode off and on."
    }

    private func startPrivilegedLidSleepHelper(previousDisableSleep: Int) throws {
        let markerURL = URL(fileURLWithPath: "/tmp/noajar-session-\(UUID().uuidString).hold")
        FileManager.default.createFile(atPath: markerURL.path, contents: Data())

        let shellScript = """
        marker=\(shellSingleQuoted(markerURL.path))
        previous=\(previousDisableSleep)
        /usr/bin/pmset -a disablesleep 1
        while /bin/test -e "$marker"; do /bin/sleep 2; done
        /usr/bin/pmset -a disablesleep "$previous"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"\(appleScriptEscaped(shellScript))\" with administrator privileges"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        lidSleepMarkerURL = markerURL
        lidSleepHelper = process
    }

    private func stopPrivilegedLidSleepHelper() {
        if let lidSleepMarkerURL {
            try? FileManager.default.removeItem(at: lidSleepMarkerURL)
        }
        lidSleepMarkerURL = nil

        guard let lidSleepHelper else { return }
        if lidSleepHelper.isRunning {
            for _ in 0..<20 where lidSleepHelper.isRunning {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        if lidSleepHelper.isRunning {
            lidSleepHelper.terminate()
        }
        self.lidSleepHelper = nil
    }
}

public struct LidAwakeError: LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public func statusSnapshot() -> LidAwakeStatus {
    LidAwakeStatus(
        disableSleep: currentDisableSleep(),
        power: powerStatus(),
        state: loadState()
    )
}

public func repairStaleStateIfNeeded() {
    guard let state = loadState(), !processIsRunning(pid: state.pid) else { return }
    guard currentDisableSleep() == 1 else {
        removeState()
        return
    }
}

public func stopExistingSessionOrRestore() {
    if let state = loadState(), state.pid != getpid(), processIsRunning(pid: state.pid) {
        if kill(state.pid, SIGTERM) == 0 {
            print("Sent stop signal to pid \(state.pid).")
            return
        }
    }

    restoreDisableSleep()
}

public func isAnyProcessRunning(matching names: [String]) -> Bool {
    let terms = names
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
    guard !terms.isEmpty,
          let result = try? run("/bin/ps", ["-axo", "comm=,args="]) else {
        return false
    }

    let lines = result.output.lowercased().split(separator: "\n")
    return lines.contains { line in
        terms.contains { term in line.contains(term) }
    }
}

public func wifiStatus() -> WiFiStatus {
    guard let interface = wifiInterface() else {
        return WiFiStatus(interface: nil, currentSSID: nil, linkActive: false)
    }

    return WiFiStatus(
        interface: interface,
        currentSSID: currentWiFiSSID(interface: interface),
        linkActive: wifiLinkIsActive(interface: interface)
    )
}

public final class DownloadActivityMonitor {
    private let folder: URL
    private let fileManager: FileManager
    private var previousSizes: [String: UInt64] = [:]

    public init(
        folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
        fileManager: FileManager = .default
    ) {
        self.folder = folder
        self.fileManager = fileManager
    }

    public func isActive() -> Bool {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        var currentSizes: [String: UInt64] = [:]
        var active = false

        for url in urls {
            let path = url.path
            let name = url.lastPathComponent.lowercased()
            if name.hasSuffix(".download")
                || name.hasSuffix(".crdownload")
                || name.hasSuffix(".part")
                || name.hasSuffix(".opdownload") {
                active = true
            }

            let size = fileSize(at: url)
            currentSizes[path] = size
            if let previous = previousSizes[path], previous != size {
                active = true
            }
        }

        previousSizes = currentSizes
        return active
    }
}

public struct LaunchAgent {
    public let label: String

    public init(label: String = "dev.local.lidawake") {
        self.label = label
    }

    public var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    public var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    public func setEnabled(_ enabled: Bool, executablePath: String) throws {
        if enabled {
            try enable(executablePath: executablePath)
        } else {
            try disable()
        }
    }

    private func enable(executablePath: String) throws {
        let directory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: [.atomic])
    }

    private func disable() throws {
        _ = try? run("/bin/launchctl", ["bootout", "gui/\(getuid())", plistURL.path])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}

@discardableResult
public func installSignalCleanup(_ cleanup: @escaping () -> Void) -> [DispatchSourceSignal] {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    let signalQueue = DispatchQueue(label: "noajar.signals")
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)

    let handler = {
        cleanup()
        exit(0)
    }

    interrupt.setEventHandler(handler: handler)
    terminate.setEventHandler(handler: handler)
    interrupt.resume()
    terminate.resume()
    return [interrupt, terminate]
}

public func parseDuration(_ raw: String) -> TimeInterval? {
    guard let last = raw.last else { return nil }
    let valuePart: Substring
    let multiplier: Double

    switch last {
    case "s":
        valuePart = raw.dropLast()
        multiplier = 1
    case "m":
        valuePart = raw.dropLast()
        multiplier = 60
    case "h":
        valuePart = raw.dropLast()
        multiplier = 60 * 60
    default:
        valuePart = Substring(raw)
        multiplier = 1
    }

    guard let value = Double(valuePart), value > 0 else { return nil }
    return value * multiplier
}

private struct CommandResult {
    let status: Int32
    let output: String
    let error: String

    func errorOrOutput(defaultMessage: String) -> String {
        let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            return message
        }
        let outputMessage = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return outputMessage.isEmpty ? defaultMessage : outputMessage
    }
}

@discardableResult
private func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus, output: output, error: error)
}

private func currentDisableSleep() -> Int? {
    guard let result = try? run("/usr/bin/pmset", ["-g", "custom"]) else { return nil }
    for line in result.output.split(separator: "\n") {
        let parts = line.split { $0 == " " || $0 == "\t" }
        if parts.first == "disablesleep", parts.count >= 2 {
            return Int(parts[1])
        }
    }
    return nil
}

private func setDisableSleep(_ value: Int) throws {
    let command = "/usr/bin/pmset -a disablesleep \(value)"

    if geteuid() == 0 {
        let result = try run("/usr/bin/pmset", ["-a", "disablesleep", "\(value)"])
        guard result.status == 0 else {
            throw LidAwakeError("pmset failed: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return
    }

    let escapedCommand = command.replacingOccurrences(of: "\"", with: "\\\"")
    let script = "do shell script \"\(escapedCommand)\" with administrator privileges"
    let result = try run("/usr/bin/osascript", ["-e", script])
    guard result.status == 0 else {
        let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        throw LidAwakeError(message.isEmpty ? "Administrator authorization was cancelled or failed." : message)
    }
}

private func saveState(previousDisableSleep: Int?) throws {
    let state = LidAwakeState(
        previousDisableSleep: previousDisableSleep,
        startedAt: Date(),
        pid: getpid()
    )
    let data = try JSONEncoder().encode(state)
    try data.write(to: lidAwakeStateURL, options: [.atomic])
}

private func loadState() -> LidAwakeState? {
    guard let data = try? Data(contentsOf: lidAwakeStateURL) else { return nil }
    return try? JSONDecoder().decode(LidAwakeState.self, from: data)
}

private func removeState() {
    try? FileManager.default.removeItem(at: lidAwakeStateURL)
}

private func restoreDisableSleep() {
    let previous = loadState()?.previousDisableSleep ?? 0
    do {
        try setDisableSleep(previous)
        removeState()
        print("Restored disablesleep=\(previous).")
    } catch {
        fputs("Failed to restore disablesleep: \(error.localizedDescription)\n", stderr)
    }
}

private func createSleepAssertion(type: CFString, reason: String) throws -> IOPMAssertionID {
    var assertionID = IOPMAssertionID(0)
    let result = IOPMAssertionCreateWithName(
        type,
        IOPMAssertionLevel(kIOPMAssertionLevelOn),
        reason as CFString,
        &assertionID
    )

    guard result == kIOReturnSuccess else {
        throw LidAwakeError("IOPMAssertionCreateWithName failed with code \(result).")
    }

    return assertionID
}

private func powerStatus() -> LidAwakePowerStatus {
    guard let result = try? run("/usr/bin/pmset", ["-g", "batt"]) else {
        return LidAwakePowerStatus(source: "unknown", percent: nil)
    }

    var source = "unknown"
    if result.output.contains("AC Power") {
        source = "AC Power"
    } else if result.output.contains("Battery Power") {
        source = "Battery Power"
    }

    let percent = result.output
        .split(separator: "\n")
        .compactMap { line -> Int? in
            guard let prefix = line.split(separator: "%", maxSplits: 1).first else { return nil }
            let digits = prefix.reversed().prefix { $0.isNumber }.reversed()
            return Int(String(digits))
        }
        .first

    return LidAwakePowerStatus(source: source, percent: percent)
}

private func wifiInterface() -> String? {
    guard let result = try? run("/usr/sbin/networksetup", ["-listallhardwareports"]) else {
        return nil
    }

    let lines = result.output.split(separator: "\n").map(String.init)
    for (index, line) in lines.enumerated() where line == "Hardware Port: Wi-Fi" {
        guard index + 1 < lines.count else { return nil }
        let deviceLine = lines[index + 1]
        let prefix = "Device: "
        if deviceLine.hasPrefix(prefix) {
            return String(deviceLine.dropFirst(prefix.count))
        }
    }

    return nil
}

private func currentWiFiSSID(interface: String) -> String? {
    if let ssid = CWWiFiClient.shared().interface(withName: interface)?.ssid(),
       !ssid.isEmpty {
        return ssid
    }

    guard let result = try? run("/usr/sbin/networksetup", ["-getairportnetwork", interface]),
          result.status == 0 else {
        return currentWiFiSSIDFromIPConfig(interface: interface)
    }

    let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "Current Wi-Fi Network: "
    guard output.hasPrefix(prefix) else {
        return currentWiFiSSIDFromIPConfig(interface: interface)
    }

    let ssid = output.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    return ssid.isEmpty ? currentWiFiSSIDFromIPConfig(interface: interface) : ssid
}

private func currentWiFiSSIDFromIPConfig(interface: String) -> String? {
    guard let output = ipconfigSummary(interface: interface) else {
        return nil
    }

    for rawLine in output.split(separator: "\n").map(String.init) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("SSID :") else { continue }
        let ssid = line.dropFirst("SSID :".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if !ssid.isEmpty && ssid != "<redacted>" {
            return ssid
        }
    }

    return nil
}

private func wifiLinkIsActive(interface: String) -> Bool {
    guard let output = ipconfigSummary(interface: interface) else {
        return false
    }

    return output.contains("LinkStatusActive : TRUE")
}

private func ipconfigSummary(interface: String) -> String? {
    guard let result = try? run("/usr/sbin/ipconfig", ["getsummary", interface]),
          result.status == 0 else {
        return nil
    }

    return result.output
}

private func processIsRunning(pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

private func fileSize(at url: URL) -> UInt64 {
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]) else {
        return 0
    }

    if let size = values.fileSize {
        return UInt64(size)
    }
    if let size = values.totalFileAllocatedSize {
        return UInt64(size)
    }
    return 0
}

private func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func appleScriptEscaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "; ")
}
