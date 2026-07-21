import Dispatch
import CoreWLAN
import Darwin
import Foundation
import IOKit.pwr_mgt
import ObjectiveC

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
    func statusV2(withReply reply: @escaping (Bool, Bool, NSString?) -> Void)
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
    public var hotspotKeepaliveEnabled: Bool
    public var hotspotSSID: String?
    public var reason: String

    public init(
        mode: AwakeMode = .noAjar,
        allowBattery: Bool = false,
        batteryGuardEnabled: Bool = true,
        minBatteryPercent: Int = 30,
        durationSeconds: TimeInterval? = nil,
        preventDisplaySleep: Bool = false,
        manageLidSleepOverride: Bool = true,
        hotspotKeepaliveEnabled: Bool = false,
        hotspotSSID: String? = nil,
        reason: String = "NoAjar"
    ) {
        self.mode = mode
        self.allowBattery = allowBattery
        self.batteryGuardEnabled = batteryGuardEnabled
        self.minBatteryPercent = minBatteryPercent
        self.durationSeconds = durationSeconds
        self.preventDisplaySleep = preventDisplaySleep
        self.manageLidSleepOverride = manageLidSleepOverride
        self.hotspotKeepaliveEnabled = hotspotKeepaliveEnabled
        self.hotspotSSID = hotspotSSID
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

struct HotspotLinkSignals: Sendable {
    let usesIPv6Translation: Bool
    let hasConstrainedHotspotAddress: Bool

    var hasHotspotSignature: Bool {
        usesIPv6Translation || hasConstrainedHotspotAddress
    }

    init(ipconfigSummary: String?, ifconfigOutput: String?) {
        let ipconfigSummary = ipconfigSummary ?? ""
        let ifconfigOutput = ifconfigOutput ?? ""
        usesIPv6Translation = ipconfigSummary.contains("CLAT46Active : TRUE") ||
            ifconfigOutput.contains("nat64 prefix")
        hasConstrainedHotspotAddress = ifconfigOutput.contains("constrained") &&
            ifconfigOutput.contains("inet 192.0.0.2")
    }
}

public struct HotspotConnectionHealth: Sendable {
    public let interface: String
    public let currentSSID: String?
    public let targetSSID: String?
    public let linkActive: Bool
    public let gateway: String?
    public let internetReachable: Bool
    public let usesIPv6Translation: Bool
    public let hasConstrainedHotspotAddress: Bool

    public var hasHotspotSignature: Bool {
        usesIPv6Translation || hasConstrainedHotspotAddress
    }

    public var hasDifferentSSID: Bool {
        guard let currentSSID, let targetSSID else { return false }
        return currentSSID != targetSSID
    }

    public var confirmsTargetConnection: Bool {
        guard let targetSSID else { return false }
        if currentSSID == targetSSID {
            return linkActive && internetReachable
        }
        guard currentSSID == nil else {
            return false
        }
        return linkActive && internetReachable && hasHotspotSignature
    }
}

public struct HotspotKeepaliveResult: Sendable {
    public let success: Bool
    public let message: String
    public let didReconnect: Bool

    public init(success: Bool, message: String, didReconnect: Bool = false) {
        self.success = success
        self.message = message
        self.didReconnect = didReconnect
    }
}

public func performHotspotKeepalive(
    targetSSID rawTargetSSID: String? = nil,
    forceReconnect: Bool = false
) -> HotspotKeepaliveResult {
    guard let interface = wifiInterface() else {
        return HotspotKeepaliveResult(success: false, message: "Hotspot Keepalive: no Wi-Fi interface found.")
    }

    let targetSSID = rawTargetSSID?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty
    var health = hotspotConnectionHealth(interface: interface, targetSSID: targetSSID)

    if let targetSSID {
        health = healthForTargetConfirmation(interface: interface, targetSSID: targetSSID, current: health)
        if let result = successfulKeepaliveResult(from: health) {
            return result
        }
        if !health.linkActive {
            return reconnectToWiFi(interface: interface, ssid: targetSSID)
        }
        if forceReconnect || health.hasDifferentSSID || health.currentSSID == nil || !health.internetReachable {
            return reconnectToWiFi(interface: interface, ssid: targetSSID)
        }
    }

    guard health.linkActive else {
        return HotspotKeepaliveResult(success: false, message: "Hotspot Keepalive: Wi-Fi is not connected.")
    }
    guard let result = successfulKeepaliveResult(from: health) else {
        if let gateway = health.gateway {
            return HotspotKeepaliveResult(success: false, message: "Hotspot Keepalive: gateway \(gateway) did not respond.")
        }
        return HotspotKeepaliveResult(success: false, message: "Hotspot Keepalive: internet did not respond.")
    }
    return result
}

public func performHotspotKeepaliveAndExit(
    targetSSID rawTargetSSID: String? = nil,
    forceReconnect: Bool = false,
    exitHandler: @escaping @Sendable (HotspotKeepaliveResult) -> Never
) -> Never {
    guard let interface = wifiInterface() else {
        exitHandler(HotspotKeepaliveResult(success: false, message: "Hotspot Keepalive: no Wi-Fi interface found."))
    }

    let targetSSID = rawTargetSSID?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty
    var health = hotspotConnectionHealth(interface: interface, targetSSID: targetSSID)

    if let targetSSID {
        health = healthForTargetConfirmation(interface: interface, targetSSID: targetSSID, current: health)
        if let result = successfulKeepaliveResult(from: health) {
            exitHandler(result)
        }
        if !health.linkActive {
            reconnectToWiFiAndExit(interface: interface, ssid: targetSSID, exitHandler: exitHandler)
        }
        if forceReconnect || health.hasDifferentSSID || health.currentSSID == nil || !health.internetReachable {
            reconnectToWiFiAndExit(interface: interface, ssid: targetSSID, exitHandler: exitHandler)
        }
    }

    guard health.linkActive else {
        exitHandler(HotspotKeepaliveResult(success: false, message: "Hotspot Keepalive: Wi-Fi is not connected."))
    }
    guard let result = successfulKeepaliveResult(from: health) else {
        if let gateway = health.gateway {
            exitHandler(HotspotKeepaliveResult(success: false, message: "Hotspot Keepalive: gateway \(gateway) did not respond."))
        }
        exitHandler(HotspotKeepaliveResult(success: false, message: "Hotspot Keepalive: internet did not respond."))
    }
    exitHandler(result)
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
                let previous = try readSleepDisabled()
                try saveState(previousDisableSleep: previous)
                didSaveState = true
                try startPrivilegedLidSleepHelper(previousDisableSleep: previous)
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

public func repairStaleStateIfNeeded() throws {
    guard let state = loadState(), !processIsRunning(pid: state.pid) else { return }
    guard try readSleepDisabled() == 1 else {
        removeState()
        return
    }
}

public func stopExistingSessionOrRestore() throws {
    if let state = loadState(), state.pid != getpid(), processIsRunning(pid: state.pid) {
        if kill(state.pid, SIGTERM) == 0 {
            print("Sent stop signal to pid \(state.pid).")
            return
        }
    }

    try restoreDisableSleep()
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

public func currentWiFiNetworkName(allowSlowLookup: Bool = false) -> String? {
    guard let interface = wifiInterface() else { return nil }
    return currentWiFiSSID(interface: interface, allowSlowLookup: allowSlowLookup)
}

public func currentHotspotConnectionHealth(targetSSID rawTargetSSID: String? = nil) -> HotspotConnectionHealth? {
    guard let interface = wifiInterface() else { return nil }
    let targetSSID = rawTargetSSID?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty
    return hotspotConnectionHealth(interface: interface, targetSSID: targetSSID)
}

public func currentHotspotConnectionConfirmsTarget(targetSSID rawTargetSSID: String?) -> Bool {
    guard let targetSSID = rawTargetSSID?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty else {
        return false
    }
    return currentHotspotConnectionHealth(targetSSID: targetSSID)?.confirmsTargetConnection ?? false
}

public func savedWiFiNetworkNames() -> [String] {
    var names: [String] = []
    if let currentName = currentWiFiNetworkName(allowSlowLookup: false) {
        names.append(currentName)
    }
    if let interface = wifiInterface() {
        names.append(contentsOf: preferredWiFiNetworkNames(interface: interface))
    }
    return sortedUniqueNetworkNames(names)
}

public func availableWiFiNetworkNames(includeInstantHotspots: Bool = true) -> [String] {
    var names = savedWiFiNetworkNames()
    if let interface = wifiInterface() {
        names.append(contentsOf: scannedWiFiNetworkNames(interface: interface))
    }
    if includeInstantHotspots {
        names.append(contentsOf: InstantHotspotNameBrowser().names(timeout: 2))
    }
    return sortedUniqueNetworkNames(names)
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

    func combinedMessage(defaultMessage: String) -> String {
        let message = [output, error]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return message.isEmpty ? defaultMessage : message
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

public func sleepDisabledValue(fromPMSetOutput output: String) throws -> Int {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "System-wide power settings:" }),
          lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Currently in use:" }) else {
        throw LidAwakeError("Unexpected output from /usr/bin/pmset -g.")
    }

    for line in lines {
        let parts = line.split { $0 == " " || $0 == "\t" }
        guard parts.first == "SleepDisabled" else { continue }
        guard parts.count >= 2,
              let value = Int(parts[1]),
              value == 0 || value == 1 else {
            throw LidAwakeError("Invalid SleepDisabled value from /usr/bin/pmset -g: \(line.trimmingCharacters(in: .whitespaces)).")
        }
        return value
    }

    return 0
}

public func readSleepDisabled() throws -> Int {
    let result = try run("/usr/bin/pmset", ["-g"])
    guard result.status == 0 else {
        throw LidAwakeError(result.errorOrOutput(defaultMessage: "/usr/bin/pmset -g failed."))
    }
    return try sleepDisabledValue(fromPMSetOutput: result.output)
}

private func currentDisableSleep() -> Int? {
    try? readSleepDisabled()
}

private func setDisableSleep(_ value: Int) throws {
    let command = "/usr/bin/pmset -a disablesleep \(value)"

    if geteuid() == 0 {
        let result = try run("/usr/bin/pmset", ["-a", "disablesleep", "\(value)"])
        guard result.status == 0 else {
            throw LidAwakeError("pmset failed: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard try readSleepDisabled() == value else {
            throw LidAwakeError("SleepDisabled did not change to \(value).")
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
    guard try readSleepDisabled() == value else {
        throw LidAwakeError("SleepDisabled did not change to \(value).")
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

private func restoreDisableSleep() throws {
    guard FileManager.default.fileExists(atPath: lidAwakeStateURL.path) else {
        throw LidAwakeError("No saved NoAjar state was found; refusing to change SleepDisabled.")
    }
    let data = try Data(contentsOf: lidAwakeStateURL)
    let state = try JSONDecoder().decode(LidAwakeState.self, from: data)
    guard let previous = state.previousDisableSleep else {
        throw LidAwakeError("Saved NoAjar state does not contain the previous SleepDisabled value.")
    }
    try setDisableSleep(previous)
    try FileManager.default.removeItem(at: lidAwakeStateURL)
    print("Restored disablesleep=\(previous).")
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

private func preferredWiFiNetworkNames(interface: String) -> [String] {
    guard let result = try? run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", interface]),
          result.status == 0 else {
        return []
    }

    return result.output
        .split(separator: "\n")
        .dropFirst()
        .compactMap { line in
            String(line)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }
}

private func scannedWiFiNetworkNames(interface: String) -> [String] {
    guard let wifi = CWWiFiClient.shared().interface(withName: interface) else {
        return []
    }
    guard let networks = try? wifi.scanForNetworks(withName: nil) else {
        return []
    }
    return networks.compactMap { network in
        network.ssid?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private func sortedUniqueNetworkNames(_ names: [String]) -> [String] {
    var seen = Set<String>()
    var unique: [String] = []
    for name in names {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let key = trimmed.lowercased()
        guard seen.insert(key).inserted else { continue }
        unique.append(trimmed)
    }
    return unique.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

private func currentWiFiSSID(interface: String, allowSlowLookup: Bool = false) -> String? {
    if let ssid = CWWiFiClient.shared().interface(withName: interface)?.ssid(),
       !ssid.isEmpty {
        return ssid
    }

    guard let result = try? run("/usr/sbin/networksetup", ["-getairportnetwork", interface]),
          result.status == 0 else {
        return fallbackWiFiSSID(interface: interface, allowSlowLookup: allowSlowLookup)
    }

    let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "Current Wi-Fi Network: "
    guard output.hasPrefix(prefix) else {
        return fallbackWiFiSSID(interface: interface, allowSlowLookup: allowSlowLookup)
    }

    let ssid = output.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    if !ssid.isEmpty {
        return ssid
    }

    return fallbackWiFiSSID(interface: interface, allowSlowLookup: allowSlowLookup)
}

private func fallbackWiFiSSID(interface: String, allowSlowLookup: Bool) -> String? {
    if let ipconfigSSID = currentWiFiSSIDFromIPConfig(interface: interface) {
        return ipconfigSSID
    }
    return allowSlowLookup ? currentWiFiSSIDFromSystemProfiler(interface: interface) : nil
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

private func currentWiFiSSIDFromSystemProfiler(interface: String) -> String? {
    guard let result = try? run("/usr/sbin/system_profiler", ["SPAirPortDataType"]),
          result.status == 0 else {
        return nil
    }

    var inTargetInterface = false
    var expectingNetworkName = false

    for rawLine in result.output.split(separator: "\n").map(String.init) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "\(interface):" {
            inTargetInterface = true
            expectingNetworkName = false
            continue
        }
        if inTargetInterface, trimmed.hasSuffix(":"), trimmed != "\(interface):", !rawLine.hasPrefix(" ") {
            inTargetInterface = false
            expectingNetworkName = false
        }
        guard inTargetInterface else { continue }

        if trimmed == "Current Network Information:" {
            expectingNetworkName = true
            continue
        }
        if expectingNetworkName, trimmed == "Other Local Wi-Fi Networks:" {
            return nil
        }

        if expectingNetworkName, trimmed.hasSuffix(":") {
            let ssid = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            return ssid.isEmpty ? nil : ssid
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

private func hotspotConnectionHealth(
    interface: String,
    targetSSID: String?,
    allowSlowSSIDLookup: Bool = false
) -> HotspotConnectionHealth {
    let summary = ipconfigSummary(interface: interface)
    let linkActive = summary?.contains("LinkStatusActive : TRUE") ?? false
    let ifconfigOutput = wifiInterfaceOutput(interface: interface)
    let signals = HotspotLinkSignals(ipconfigSummary: summary, ifconfigOutput: ifconfigOutput)
    let gateway = wifiGateway(interface: interface)
    let internetReachable = linkActive && networkResponds(interface: interface, gateway: gateway)
    return HotspotConnectionHealth(
        interface: interface,
        currentSSID: currentWiFiSSID(interface: interface, allowSlowLookup: allowSlowSSIDLookup),
        targetSSID: targetSSID,
        linkActive: linkActive,
        gateway: gateway,
        internetReachable: internetReachable,
        usesIPv6Translation: signals.usesIPv6Translation,
        hasConstrainedHotspotAddress: signals.hasConstrainedHotspotAddress
    )
}

private func healthForTargetConfirmation(
    interface: String,
    targetSSID: String,
    current health: HotspotConnectionHealth
) -> HotspotConnectionHealth {
    guard health.linkActive, health.currentSSID == nil else {
        return health
    }
    return hotspotConnectionHealth(
        interface: interface,
        targetSSID: targetSSID,
        allowSlowSSIDLookup: true
    )
}

private func successfulKeepaliveResult(from health: HotspotConnectionHealth) -> HotspotKeepaliveResult? {
    guard health.linkActive, health.internetReachable else {
        return nil
    }
    if let targetSSID = health.targetSSID {
        guard health.confirmsTargetConnection else {
            return nil
        }
        if health.currentSSID == targetSSID {
            return HotspotKeepaliveResult(success: true, message: "Hotspot Keepalive: \(targetSSID) is reachable.")
        }
        return HotspotKeepaliveResult(
            success: true,
            message: "Hotspot Keepalive: hotspot link is reachable without a visible SSID."
        )
    }
    if let gateway = health.gateway {
        return HotspotKeepaliveResult(success: true, message: "Hotspot Keepalive: gateway \(gateway) reached.")
    }
    return HotspotKeepaliveResult(success: true, message: "Hotspot Keepalive: internet is reachable.")
}

private func wifiGateway(interface: String) -> String? {
    if let output = ipconfigSummary(interface: interface) {
        for rawLine in output.split(separator: "\n").map(String.init) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("Router :") else { continue }
            let gateway = line.dropFirst("Router :".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !gateway.isEmpty {
                return gateway
            }
        }
    }

    return defaultRouteGateway(interface: interface)
}

private func defaultRouteGateway(interface: String) -> String? {
    guard let result = try? run("/sbin/route", ["-n", "get", "default"]),
          result.status == 0 else {
        return nil
    }

    var gateway: String?
    var routeInterface: String?
    for rawLine in result.output.split(separator: "\n").map(String.init) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("gateway:") {
            gateway = line.dropFirst("gateway:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if line.hasPrefix("interface:") {
            routeInterface = line.dropFirst("interface:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    guard routeInterface == interface else {
        return nil
    }
    return gateway?.nilIfEmpty
}

private func wifiInterfaceOutput(interface: String) -> String? {
    guard let result = try? run("/sbin/ifconfig", [interface]),
          result.status == 0 else {
        return nil
    }
    return result.output
}

private func networkResponds(interface: String, gateway: String?) -> Bool {
    if let gateway, pingResponds(interface: interface, host: gateway) {
        return true
    }
    return pingResponds(interface: interface, host: "1.1.1.1")
}

private func pingResponds(interface: String, host: String) -> Bool {
    guard let result = try? run("/sbin/ping", ["-q", "-n", "-c", "1", "-W", "1000", "-b", interface, host]) else {
        return false
    }
    return result.status == 0
}

private func reconnectToWiFi(interface: String, ssid: String) -> HotspotKeepaliveResult {
    do {
        _ = try? run("/usr/sbin/networksetup", ["-setairportpower", interface, "on"])
        let result = try run("/usr/sbin/networksetup", ["-setairportnetwork", interface, ssid])
        let message = result.combinedMessage(defaultMessage: "networksetup failed.")
        if networkSetupMessageIndicatesMissingNetwork(message) {
            return reconnectToInstantHotspot(interface: interface, deviceName: ssid)
        }
        guard result.status == 0 else {
            return HotspotKeepaliveResult(
                success: false,
                message: "Hotspot Keepalive: reconnect to \(ssid) failed: \(message)"
            )
        }

        let connectedSSID = waitForWiFiConnection(interface: interface, ssid: ssid)
        let health = healthForTargetConfirmation(
            interface: interface,
            targetSSID: ssid,
            current: hotspotConnectionHealth(interface: interface, targetSSID: ssid)
        )
        let connectedToTarget = connectedSSID.map { $0 == ssid } ?? health.confirmsTargetConnection
        guard health.linkActive, health.internetReachable, connectedToTarget else {
            let currentText = connectedSSID.map { " Still on \($0)." } ?? ""
            return HotspotKeepaliveResult(
                success: false,
                message: "Hotspot Keepalive: reconnect to \(ssid) did not become active.\(currentText)"
            )
        }

        return HotspotKeepaliveResult(
            success: true,
            message: "Hotspot Keepalive: reconnected to \(ssid).",
            didReconnect: true
        )
    } catch {
        return HotspotKeepaliveResult(
            success: false,
            message: "Hotspot Keepalive: reconnect to \(ssid) failed: \(error.localizedDescription)"
        )
    }
}

private func reconnectToWiFiAndExit(
    interface: String,
    ssid: String,
    exitHandler: @escaping @Sendable (HotspotKeepaliveResult) -> Never
) -> Never {
    do {
        _ = try? run("/usr/sbin/networksetup", ["-setairportpower", interface, "on"])
        let result = try run("/usr/sbin/networksetup", ["-setairportnetwork", interface, ssid])
        let message = result.combinedMessage(defaultMessage: "networksetup failed.")
        if networkSetupMessageIndicatesMissingNetwork(message) {
            exitHandler(reconnectToInstantHotspot(interface: interface, deviceName: ssid))
        }
        guard result.status == 0 else {
            exitHandler(HotspotKeepaliveResult(
                success: false,
                message: "Hotspot Keepalive: reconnect to \(ssid) failed: \(message)"
            ))
        }

        let connectedSSID = waitForWiFiConnection(interface: interface, ssid: ssid)
        let health = healthForTargetConfirmation(
            interface: interface,
            targetSSID: ssid,
            current: hotspotConnectionHealth(interface: interface, targetSSID: ssid)
        )
        let connectedToTarget = connectedSSID.map { $0 == ssid } ?? health.confirmsTargetConnection
        guard health.linkActive, health.internetReachable, connectedToTarget else {
            let currentText = connectedSSID.map { " Still on \($0)." } ?? ""
            exitHandler(HotspotKeepaliveResult(
                success: false,
                message: "Hotspot Keepalive: reconnect to \(ssid) did not become active.\(currentText)"
            ))
        }

        exitHandler(HotspotKeepaliveResult(
            success: true,
            message: "Hotspot Keepalive: reconnected to \(ssid).",
            didReconnect: true
        ))
    } catch {
        exitHandler(HotspotKeepaliveResult(
            success: false,
            message: "Hotspot Keepalive: reconnect to \(ssid) failed: \(error.localizedDescription)"
        ))
    }
}

private func networkSetupMessageIndicatesMissingNetwork(_ message: String) -> Bool {
    message.localizedCaseInsensitiveContains("could not find network")
}

private func instantHotspotEnableErrorMayHaveStartedHotspot(_ message: String) -> Bool {
    let normalized = message.lowercased()
        .replacingOccurrences(of: "\u{2018}", with: "'")
        .replacingOccurrences(of: "\u{2019}", with: "'")
    return normalized.contains("tmperr") ||
        normalized.contains("couldn't be completed") ||
        normalized.contains("could not be completed") ||
        normalized.contains("did not return wi-fi credentials") ||
        normalized.contains("did not return wifi credentials")
}

private struct InstantHotspotCredentials {
    let networkName: String
    let password: String
}

private enum InstantHotspotCredentialResult {
    case success(InstantHotspotCredentials)
    case failure(String)
}

private func instantHotspotCredentials(deviceName: String) -> InstantHotspotCredentialResult {
    guard let helperURL = instantHotspotHelperURL() else {
        return .failure("Instant Hotspot helper was not found.")
    }

    do {
        let result = try run(helperURL.path, [deviceName])
        let fields = keyValueLines(result.output)
        if result.status == 0,
           fields["success"] == "1",
           let networkName = fields["networkName"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
           let password = fields["password"]?.nilIfEmpty {
            return .success(InstantHotspotCredentials(networkName: networkName, password: password))
        }

        let message = fields["message"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? result.combinedMessage(defaultMessage: "Instant Hotspot helper failed.")
        return .failure(message)
    } catch {
        return .failure("Instant Hotspot helper could not start: \(error.localizedDescription)")
    }
}

private func instantHotspotHelperURL() -> URL? {
    guard let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() else {
        return nil
    }

    for name in ["noajar-hotspot", "NoAjarHotspotHelper"] {
        let url = executableDirectory.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
    }

    return nil
}

private func keyValueLines(_ output: String) -> [String: String] {
    var fields: [String: String] = [:]
    for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        fields[String(parts[0])] = String(parts[1])
    }
    return fields
}

private func reconnectToInstantHotspot(interface: String, deviceName: String) -> HotspotKeepaliveResult {
    let previousGateway = wifiGateway(interface: interface)
    switch instantHotspotCredentials(deviceName: deviceName) {
    case let .success(credentials):
        return joinInstantHotspotNetwork(
            interface: interface,
            deviceName: deviceName,
            networkName: credentials.networkName,
            password: credentials.password
        )
    case let .failure(message):
        if instantHotspotEnableErrorMayHaveStartedHotspot(message) {
            return retryInstantHotspotJoinAfterEnableError(
                interface: interface,
                deviceName: deviceName,
                previousGateway: previousGateway,
                originalMessage: message
            )
        }
        return HotspotKeepaliveResult(success: false, message: "Hotspot Keepalive: \(message)")
    }
}

private func retryInstantHotspotJoinAfterEnableError(
    interface: String,
    deviceName: String,
    previousGateway: String?,
    originalMessage: String
) -> HotspotKeepaliveResult {
    let deadline = Date().addingTimeInterval(28)
    var lastMessage = originalMessage

    while Date() < deadline {
        if currentWiFiSSID(interface: interface, allowSlowLookup: true) == deviceName {
            return HotspotKeepaliveResult(
                success: true,
                message: "Hotspot Keepalive: connected to Instant Hotspot \(deviceName).",
                didReconnect: true
            )
        }

        _ = try? run("/usr/sbin/networksetup", ["-setairportpower", interface, "on"])
        if let result = try? run("/usr/sbin/networksetup", ["-setairportnetwork", interface, deviceName]) {
            let message = result.combinedMessage(defaultMessage: "networksetup failed.")
            if result.status == 0,
               waitForInstantHotspotConnection(
                   interface: interface,
                   ssid: deviceName,
                   previousGateway: previousGateway,
                   timeout: 8
               ) {
                return HotspotKeepaliveResult(
                    success: true,
                    message: "Hotspot Keepalive: connected to Instant Hotspot \(deviceName).",
                    didReconnect: true
                )
            }
            lastMessage = message
        }

        Thread.sleep(forTimeInterval: 2)
    }

    return HotspotKeepaliveResult(
        success: false,
        message: "Hotspot Keepalive: Instant Hotspot \(deviceName) could not start after retry: \(lastMessage)"
    )
}

private func joinInstantHotspotNetwork(
    interface: String,
    deviceName: String,
    networkName: String,
    password: String
) -> HotspotKeepaliveResult {
    let previousGateway = wifiGateway(interface: interface)
    var lastJoinMessage = "Instant Hotspot network was not found in Wi-Fi scan."
    do {
        let result = try run("/usr/sbin/networksetup", ["-setairportnetwork", interface, networkName, password])
        let message = result.combinedMessage(defaultMessage: "networksetup failed.")
        if result.status == 0,
           waitForInstantHotspotConnection(
               interface: interface,
               ssid: networkName,
               previousGateway: previousGateway,
               timeout: 24
           ) {
            return HotspotKeepaliveResult(
                success: true,
                message: "Hotspot Keepalive: connected to Instant Hotspot \(deviceName).",
                didReconnect: true
            )
        }
        if !networkSetupMessageIndicatesMissingNetwork(message) {
            guard instantHotspotEnableErrorMayHaveStartedHotspot(message) else {
                return HotspotKeepaliveResult(
                    success: false,
                    message: "Hotspot Keepalive: Instant Hotspot \(deviceName) was enabled, but Wi-Fi join failed: \(message)."
                )
            }
            lastJoinMessage = message
            if waitForInstantHotspotConnection(
                interface: interface,
                ssid: networkName,
                previousGateway: previousGateway,
                timeout: 24
            ) {
                return HotspotKeepaliveResult(
                    success: true,
                    message: "Hotspot Keepalive: connected to Instant Hotspot \(deviceName).",
                    didReconnect: true
                )
            }
        }
    } catch {
        let message = error.localizedDescription
        guard instantHotspotEnableErrorMayHaveStartedHotspot(message) else {
            return HotspotKeepaliveResult(
                success: false,
                message: "Hotspot Keepalive: Instant Hotspot \(deviceName) was enabled, but Wi-Fi join failed: \(message)."
            )
        }
        lastJoinMessage = message
        if waitForInstantHotspotConnection(
            interface: interface,
            ssid: networkName,
            previousGateway: previousGateway,
            timeout: 24
        ) {
            return HotspotKeepaliveResult(
                success: true,
                message: "Hotspot Keepalive: connected to Instant Hotspot \(deviceName).",
                didReconnect: true
            )
        }
    }

    guard let wifi = CWWiFiClient.shared().interface(withName: interface) else {
        return HotspotKeepaliveResult(
            success: false,
            message: "Hotspot Keepalive: Wi-Fi interface \(interface) is unavailable."
        )
    }

    let deadline = Date().addingTimeInterval(18)
    var lastMessage = lastJoinMessage
    while Date() < deadline {
        do {
            let networks = try wifi.scanForNetworks(withName: networkName)
            if let network = networks.first {
                wifi.disassociate()
                Thread.sleep(forTimeInterval: 0.4)
                let message = associateToWiFiNetwork(wifi, network: network, password: password)
                if waitForInstantHotspotConnection(
                    interface: interface,
                    ssid: networkName,
                    previousGateway: previousGateway,
                    timeout: 24
                ) {
                    return HotspotKeepaliveResult(
                        success: true,
                        message: "Hotspot Keepalive: connected to Instant Hotspot \(deviceName).",
                        didReconnect: true
                    )
                }
                return HotspotKeepaliveResult(
                    success: false,
                    message: "Hotspot Keepalive: Instant Hotspot \(deviceName) was enabled, but Wi-Fi join failed: \(message)."
                )
            }
        } catch {
            lastMessage = error.localizedDescription
        }
        Thread.sleep(forTimeInterval: 1)
    }

    return HotspotKeepaliveResult(
        success: false,
        message: "Hotspot Keepalive: Instant Hotspot \(deviceName) was enabled, but Wi-Fi join failed: \(lastMessage)."
    )
}

private func waitForWiFiConnection(interface: String, ssid: String) -> String? {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        let health = healthForTargetConfirmation(
            interface: interface,
            targetSSID: ssid,
            current: hotspotConnectionHealth(interface: interface, targetSSID: ssid)
        )
        if health.currentSSID == ssid {
            return ssid
        }
        if health.confirmsTargetConnection {
            return nil
        }
        Thread.sleep(forTimeInterval: 1)
    }

    let health = hotspotConnectionHealth(interface: interface, targetSSID: ssid, allowSlowSSIDLookup: true)
    guard health.linkActive else {
        return nil
    }
    return health.currentSSID
}

private final class HotspotResultWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: HotspotKeepaliveResult?

    var currentResult: HotspotKeepaliveResult? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    var isFinished: Bool {
        currentResult != nil
    }

    func finish(_ result: HotspotKeepaliveResult) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: DispatchTime) -> HotspotKeepaliveResult? {
        guard semaphore.wait(timeout: timeout) == .success else {
            return nil
        }
        return currentResult
    }
}

private typealias WiFiAssociateHiddenIMP = @convention(c) (
    AnyObject,
    Selector,
    AnyObject,
    AnyObject?,
    Bool,
    Bool,
    Bool,
    UnsafeMutablePointer<NSError?>?
) -> Bool

private typealias WiFiAssociateIMP = @convention(c) (
    AnyObject,
    Selector,
    AnyObject,
    AnyObject?,
    UnsafeMutablePointer<NSError?>?
) -> Bool

private typealias ObjCVoidIMP = @convention(c) (AnyObject, Selector) -> Void
private typealias ObjCVoidObjectIMP = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
private typealias ObjCVoidTwoObjectsIMP = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void

private func associateToWiFiNetwork(_ wifi: CWInterface, network: CWNetwork, password: String) -> String {
    let hiddenSelector = NSSelectorFromString("associateToNetwork:password:forceBSSID:remember:possiblyHidden:error:")
    if let method = class_getInstanceMethod(type(of: wifi), hiddenSelector) {
        let associate = unsafeBitCast(method_getImplementation(method), to: WiFiAssociateHiddenIMP.self)
        var error: NSError?
        let ok = associate(wifi, hiddenSelector, network, password as NSString, false, true, true, &error)
        if ok {
            return "association started."
        }
        if let error {
            return error.localizedDescription
        }
    }

    let selector = NSSelectorFromString("associateToNetwork:password:error:")
    guard let method = class_getInstanceMethod(type(of: wifi), selector) else {
        return "Wi-Fi association API is unavailable."
    }

    let associate = unsafeBitCast(method_getImplementation(method), to: WiFiAssociateIMP.self)
    var error: NSError?
    let ok = associate(wifi, selector, network, password as NSString, &error)
    if ok {
        return "association started."
    }
    return error?.localizedDescription ?? "association failed."
}

@discardableResult
private func callObjCVoid(_ object: AnyObject, _ selectorName: String) -> Bool {
    let selector = NSSelectorFromString(selectorName)
    guard let objectClass = object_getClass(object),
          let method = class_getInstanceMethod(objectClass, selector) else {
        return false
    }

    let function = unsafeBitCast(method_getImplementation(method), to: ObjCVoidIMP.self)
    function(object, selector)
    return true
}

@discardableResult
private func callObjCVoidObject(_ object: AnyObject, _ selectorName: String, _ argument: AnyObject?) -> Bool {
    let selector = NSSelectorFromString(selectorName)
    guard let objectClass = object_getClass(object),
          let method = class_getInstanceMethod(objectClass, selector) else {
        return false
    }

    let function = unsafeBitCast(method_getImplementation(method), to: ObjCVoidObjectIMP.self)
    function(object, selector, argument)
    return true
}

@discardableResult
private func callObjCVoidTwoObjects(
    _ object: AnyObject,
    _ selectorName: String,
    _ firstArgument: AnyObject?,
    _ secondArgument: AnyObject?
) -> Bool {
    let selector = NSSelectorFromString(selectorName)
    guard let objectClass = object_getClass(object),
          let method = class_getInstanceMethod(objectClass, selector) else {
        return false
    }

    let function = unsafeBitCast(method_getImplementation(method), to: ObjCVoidTwoObjectsIMP.self)
    function(object, selector, firstArgument, secondArgument)
    return true
}

private final class NetworkNameResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []

    func set(_ value: [String]) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class InstantHotspotNameBrowser: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var session: NSObject?
    private var foundNames = Set<String>()

    func names(timeout: TimeInterval) -> [String] {
        if Thread.isMainThread {
            return namesOnMain(timeout: timeout)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let result = NetworkNameResultBox()

        DispatchQueue.main.async {
            self.startBrowsing()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                self.stopBrowsing()
                result.set(sortedUniqueNetworkNames(Array(self.snapshot())))
                semaphore.signal()
            }
        }

        guard semaphore.wait(timeout: .now() + timeout + 1) == .success else {
            return []
        }
        return result.get()
    }

    private func namesOnMain(timeout: TimeInterval) -> [String] {
        startBrowsing()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        stopBrowsing()
        return sortedUniqueNetworkNames(Array(snapshot()))
    }

    private func startBrowsing() {
        guard session == nil else { return }
        guard dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW) != nil,
              let sessionClass = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type else {
            return
        }

        let session = sessionClass.init()
        self.session = session
        guard callObjCVoidObject(session, "setDelegate:", self),
              callObjCVoid(session, "startBrowsing") else {
            self.session = nil
            return
        }
    }

    private func stopBrowsing() {
        guard let session else { return }
        callObjCVoid(session, "stopBrowsing")
        callObjCVoidObject(session, "setDelegate:", nil)
        self.session = nil
    }

    private func snapshot() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return foundNames
    }

    @objc private func updatedFoundDeviceList(_ devices: Any) {
        handleUpdatedFoundDevices(devices)
    }

    @objc private func session(_ session: Any, updatedFoundDevices devices: Any) {
        handleUpdatedFoundDevices(devices)
    }

    private func handleUpdatedFoundDevices(_ devices: Any) {
        let deviceList: [Any]
        if let array = devices as? [Any] {
            deviceList = array
        } else if let array = devices as? NSArray {
            deviceList = array.map { $0 }
        } else {
            return
        }

        let names = deviceList.compactMap { rawDevice -> String? in
            let device = rawDevice as AnyObject
            let name = (device.value(forKey: "deviceName") as? String)
                ?? (device.value(forKey: "name") as? String)
            return name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        guard !names.isEmpty else { return }

        lock.lock()
        foundNames.formUnion(names)
        lock.unlock()
    }
}

private final class InstantHotspotConnector: NSObject, @unchecked Sendable {
    private final class Retainer: @unchecked Sendable {
        private let lock = NSLock()
        private var connectors: [InstantHotspotConnector] = []

        func append(_ connector: InstantHotspotConnector) {
            lock.lock()
            connectors.append(connector)
            lock.unlock()
        }
    }

    private static let retainer = Retainer()

    private let interface: String
    private let deviceName: String
    private var session: NSObject?
    private var completionBlock: Any?
    private var finishHandler: (@Sendable (HotspotKeepaliveResult) -> Void)?
    private let completionLock = NSLock()
    private var completed = false
    private var didRequestEnable = false
    private var didReceiveCredentials = false
    private var didRetainAfterEnable = false

    init(interface: String, deviceName: String) {
        self.interface = interface
        self.deviceName = deviceName
    }

    func connect() -> HotspotKeepaliveResult {
        let waiter = HotspotResultWaiter()
        let start: @Sendable () -> Void = {
            self.startBrowsing(finish: { result in
                waiter.finish(result)
            })
        }

        if Thread.isMainThread {
            start()
            let deadline = Date().addingTimeInterval(22)
            while !waiter.isFinished, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
            }
            if let result = waiter.currentResult {
                return result
            }
            stopBrowsing()
            return HotspotKeepaliveResult(
                success: false,
                message: "Hotspot Keepalive: Instant Hotspot enable for \(deviceName) timed out."
            )
        }

        DispatchQueue.main.async(execute: start)
        if let result = waiter.wait(timeout: .now() + 60) {
            return result
        }

        DispatchQueue.main.async {
            self.stopBrowsing()
        }
        return HotspotKeepaliveResult(
            success: false,
            message: timeoutMessage()
        )
    }

    func connectAndExit(_ exitHandler: @escaping @Sendable (HotspotKeepaliveResult) -> Never) -> Never {
        DispatchQueue.main.async {
            self.startBrowsing { result in
                exitHandler(result)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            self.stopBrowsing()
            exitHandler(HotspotKeepaliveResult(
                success: false,
                message: self.timeoutMessage()
            ))
        }
        dispatchMain()
    }

    private func startBrowsing(finish: @escaping @Sendable (HotspotKeepaliveResult) -> Void) {
        completionLock.lock()
        completed = false
        didRequestEnable = false
        didReceiveCredentials = false
        finishHandler = finish
        completionLock.unlock()

        guard dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW) != nil,
              let sessionClass = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type else {
            complete(HotspotKeepaliveResult(
                success: false,
                message: "Hotspot Keepalive: Instant Hotspot private API is unavailable."
            ))
            return
        }

        let session = sessionClass.init()
        self.session = session
        guard callObjCVoidObject(session, "setDelegate:", self),
              callObjCVoid(session, "startBrowsing") else {
            complete(HotspotKeepaliveResult(
                success: false,
                message: "Hotspot Keepalive: Instant Hotspot private API could not start browsing."
            ))
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 16) { [weak self] in
            guard let self else { return }
            guard !hasReceivedCredentials else { return }
            if didRequestEnable {
                complete(HotspotKeepaliveResult(
                    success: false,
                    message: "Hotspot Keepalive: Instant Hotspot enable for \(deviceName) timed out."
                ))
            } else {
                complete(HotspotKeepaliveResult(
                    success: false,
                    message: "Hotspot Keepalive: \(deviceName) is not visible to Instant Hotspot."
                ))
            }
        }
    }

    private func stopBrowsing() {
        guard let session else { return }
        if !didRequestEnable {
            callObjCVoid(session, "stopBrowsing")
            callObjCVoidObject(session, "setDelegate:", nil)
            self.session = nil
            completionBlock = nil
            finishHandler = nil
            return
        }

        retainAfterPrivateEnable()
        finishHandler = nil
    }

    private func retainAfterPrivateEnable() {
        completionLock.lock()
        guard !didRetainAfterEnable else {
            completionLock.unlock()
            return
        }
        didRetainAfterEnable = true
        completionLock.unlock()

        Self.retainer.append(self)
    }

    @objc private func updatedFoundDeviceList(_ devices: Any) {
        handleUpdatedFoundDevices(devices)
    }

    @objc private func session(_ session: Any, updatedFoundDevices devices: Any) {
        handleUpdatedFoundDevices(devices)
    }

    private func handleUpdatedFoundDevices(_ devices: Any) {
        guard !didRequestEnable,
              let device = matchingDevice(in: devices) else {
            return
        }

        didRequestEnable = true
        let block: @convention(block) (Any?, Any?) -> Void = { [weak self] hotspotInfo, error in
            self?.finishEnable(hotspotInfo: hotspotInfo, error: error)
        }
        let blockObject = block as AnyObject
        completionBlock = blockObject
        guard let session = self.session,
              callObjCVoidTwoObjects(
                  session,
                  "enableHotspotForDevice:withCompletionHandler:",
                  device,
                  blockObject
              ) else {
            complete(HotspotKeepaliveResult(
                success: false,
                message: "Hotspot Keepalive: Instant Hotspot private API could not enable \(deviceName)."
            ))
            return
        }
    }

    private func matchingDevice(in devices: Any) -> AnyObject? {
        guard let array = devices as? [Any] else {
            return nil
        }

        return array
            .map { $0 as AnyObject }
            .first { device in
                guard let name = device.value(forKey: "deviceName") as? String else {
                    return false
                }
                return name == deviceName
            }
    }

    private func finishEnable(hotspotInfo: Any?, error: Any?) {
        if let networkName = hotspotInfo as? String,
           let password = error as? String,
           !networkName.isEmpty,
           !password.isEmpty {
            markReceivedCredentials()
            joinInstantHotspotNetworkOnMain(networkName: networkName, password: password)
            return
        }
        if let error = error as? NSError {
            complete(HotspotKeepaliveResult(
                success: false,
                message: "Hotspot Keepalive: Instant Hotspot enable failed for \(deviceName): \(error.localizedDescription)"
            ))
            return
        }
        if let error {
            complete(HotspotKeepaliveResult(
                success: false,
                message: "Hotspot Keepalive: Instant Hotspot enable failed for \(deviceName): \(error)"
            ))
            return
        }
        guard let hotspotInfo = hotspotInfo as AnyObject?,
              let networkName = hotspotInfo.value(forKey: "name") as? String,
              !networkName.isEmpty,
              let password = hotspotInfo.value(forKey: "password") as? String,
              !password.isEmpty else {
            complete(HotspotKeepaliveResult(
                success: false,
                message: "Hotspot Keepalive: Instant Hotspot did not return Wi-Fi credentials for \(deviceName)."
            ))
            return
        }

        markReceivedCredentials()
        joinInstantHotspotNetworkOnMain(networkName: networkName, password: password)
    }

    private var hasReceivedCredentials: Bool {
        completionLock.lock()
        defer { completionLock.unlock() }
        return didReceiveCredentials
    }

    private func markReceivedCredentials() {
        completionLock.lock()
        didReceiveCredentials = true
        completionLock.unlock()
    }

    private func timeoutMessage() -> String {
        if hasReceivedCredentials {
            return "Hotspot Keepalive: Instant Hotspot Wi-Fi join for \(deviceName) timed out."
        }
        return "Hotspot Keepalive: Instant Hotspot enable for \(deviceName) timed out."
    }

    private func joinInstantHotspotNetworkOnMain(networkName: String, password: String) {
        DispatchQueue.main.async {
            self.scanForInstantHotspotNetwork(
                networkName: networkName,
                password: password,
                deadline: Date().addingTimeInterval(16),
                lastMessage: "Instant Hotspot network was not found in Wi-Fi scan."
            )
        }
    }

    private func complete(_ result: HotspotKeepaliveResult) {
        completionLock.lock()
        guard !completed else {
            completionLock.unlock()
            return
        }
        completed = true
        let finishHandler = finishHandler
        completionLock.unlock()

        DispatchQueue.main.async {
            self.stopBrowsing()
        }
        finishHandler?(result)
    }

    private func scanForInstantHotspotNetwork(
        networkName: String,
        password: String,
        deadline: Date,
        lastMessage: String
    ) {
        guard Date() < deadline else {
            completeInstantHotspotJoinFailure(networkName: networkName, lastMessage: lastMessage)
            return
        }

        guard let wifi = CWWiFiClient.shared().interface(withName: interface) else {
            completeInstantHotspotJoinFailure(networkName: networkName, lastMessage: "Wi-Fi interface \(interface) is unavailable.")
            return
        }

        do {
            let networks = try wifi.scanForNetworks(withName: networkName)
            guard let network = networks.first else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.scanForInstantHotspotNetwork(
                        networkName: networkName,
                        password: password,
                        deadline: deadline,
                        lastMessage: lastMessage
                    )
                }
                return
            }

            let message = associateToInstantHotspotNetwork(wifi, network: network, password: password)
            waitForInstantHotspotConnectionOnMain(
                networkName: networkName,
                deadline: Date().addingTimeInterval(24),
                lastMessage: message
            )
        } catch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.scanForInstantHotspotNetwork(
                    networkName: networkName,
                    password: password,
                    deadline: deadline,
                    lastMessage: error.localizedDescription
                )
            }
        }
    }

    private func waitForInstantHotspotConnectionOnMain(networkName: String, deadline: Date, lastMessage: String) {
        let health = hotspotConnectionHealth(interface: interface, targetSSID: networkName)
        if health.confirmsTargetConnection {
            complete(HotspotKeepaliveResult(
                success: true,
                message: "Hotspot Keepalive: connected to Instant Hotspot \(deviceName).",
                didReconnect: true
            ))
            return
        }

        guard Date() < deadline else {
            completeInstantHotspotJoinFailure(networkName: networkName, lastMessage: lastMessage)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.waitForInstantHotspotConnectionOnMain(
                networkName: networkName,
                deadline: deadline,
                lastMessage: lastMessage
            )
        }
    }

    private func completeInstantHotspotJoinFailure(networkName: String, lastMessage: String) {
        let currentSSID = currentWiFiSSID(interface: interface, allowSlowLookup: false)
        let currentText = currentSSID.map { " Still on \($0)." } ?? ""
        complete(HotspotKeepaliveResult(
            success: false,
            message: "Hotspot Keepalive: Instant Hotspot \(deviceName) was enabled, but Wi-Fi join failed: \(lastMessage).\(currentText)"
        ))
    }

    private func associateToInstantHotspotNetwork(_ wifi: CWInterface, network: CWNetwork, password: String) -> String {
        let hiddenSelector = NSSelectorFromString("associateToNetwork:password:forceBSSID:remember:possiblyHidden:error:")
        if let method = class_getInstanceMethod(type(of: wifi), hiddenSelector) {
            let associate = unsafeBitCast(method_getImplementation(method), to: WiFiAssociateHiddenIMP.self)
            var error: NSError?
            let ok = associate(wifi, hiddenSelector, network, password as NSString, false, true, true, &error)
            if ok {
                return "association started."
            }
            if let error {
                return error.localizedDescription
            }
        }

        let selector = NSSelectorFromString("associateToNetwork:password:error:")
        guard let method = class_getInstanceMethod(type(of: wifi), selector) else {
            return "Wi-Fi association API is unavailable."
        }

        let associate = unsafeBitCast(method_getImplementation(method), to: WiFiAssociateIMP.self)
        var error: NSError?
        let ok = associate(wifi, selector, network, password as NSString, &error)
        if ok {
            return "association started."
        }
        return error?.localizedDescription ?? "association failed."
    }
}

private func waitForInstantHotspotConnection(
    interface: String,
    ssid: String,
    previousGateway: String?,
    timeout: TimeInterval
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let health = hotspotConnectionHealth(interface: interface, targetSSID: ssid)
        if health.confirmsTargetConnection {
            return true
        }
        if health.linkActive,
           health.internetReachable,
           defaultRouteUsesInterface(interface),
           let gateway = health.gateway,
           gateway != previousGateway {
            return true
        }
        Thread.sleep(forTimeInterval: 1)
    }

    return hotspotConnectionHealth(interface: interface, targetSSID: ssid).confirmsTargetConnection
}

private func defaultRouteUsesInterface(_ interface: String) -> Bool {
    guard let result = try? run("/sbin/route", ["-n", "get", "default"]),
          result.status == 0 else {
        return false
    }

    for rawLine in result.output.split(separator: "\n").map(String.init) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("interface:") else { continue }
        let routeInterface = line.dropFirst("interface:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return routeInterface == interface
    }

    return false
}

private func ipconfigSummary(interface: String) -> String? {
    guard let result = try? run("/usr/sbin/ipconfig", ["getsummary", interface]),
          result.status == 0 else {
        return nil
    }

    return result.output
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
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
