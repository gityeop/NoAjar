import AppKit
import Carbon
import Darwin
import Foundation
import IOKit
import IOKit.hid
import LidAwakeCore
import Security
import Sparkle
import UniformTypeIdentifiers

private enum SessionSource {
    case manual
    case automation
}

private struct AutomationDecision {
    let mode: AwakeMode
    let reasons: [String]
    let scheduleWindow: NoAjarScheduleWindow?
}

private let betaAppcastURLString = "https://github.com/gityeop/NoAjar/releases/download/beta/appcast-beta.xml"
private let scheduleSettingsDefaultsKey = "scheduleSettings"
private let scheduleSuppressionsDefaultsKey = "scheduleSuppressions"

private func bundledNoAjarCLIURL() -> URL? {
    let bundledURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("Helpers")
        .appendingPathComponent("noajar")
    if FileManager.default.isExecutableFile(atPath: bundledURL.path) {
        return bundledURL
    }

    return nil
}

private func performHotspotKeepaliveInHelper(targetSSID: String?, forceReconnect: Bool) -> HotspotKeepaliveResult {
    guard let helperURL = bundledNoAjarCLIURL() else {
        return HotspotKeepaliveResult(
            success: false,
            message: "Hotspot Keepalive: bundled helper was not found."
        )
    }

    let process = Process()
    process.executableURL = helperURL
    process.arguments = ["hotspot-keepalive"]
    if let targetSSID,
       !targetSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        process.arguments?.append(contentsOf: ["--hotspot-ssid", targetSSID])
    }
    if forceReconnect {
        process.arguments?.append("--force-reconnect")
    }

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
        try process.run()
    } catch {
        return HotspotKeepaliveResult(
            success: false,
            message: "Hotspot Keepalive: helper could not start: \(error.localizedDescription)"
        )
    }

    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()

    var success = process.terminationStatus == 0
    var didReconnect = false
    var message = [output, error]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")

    for line in output.split(separator: "\n").map(String.init) {
        if line == "success=1" {
            success = true
        } else if line == "success=0" {
            success = false
        } else if line == "didReconnect=1" {
            didReconnect = true
        } else if line == "didReconnect=0" {
            didReconnect = false
        } else if line.hasPrefix("message=") {
            message = String(line.dropFirst("message=".count))
        }
    }

    if process.terminationStatus != 0, let targetSSID {
        if currentWiFiNetworkName(allowSlowLookup: true) == targetSSID ||
            (hotspotFailureMayStillComplete(message) && waitForHotspotConnection(targetSSID: targetSSID, timeout: 24)) {
            return HotspotKeepaliveResult(
                success: true,
                message: "Hotspot Keepalive: connected to Instant Hotspot \(targetSSID).",
                didReconnect: true
            )
        }
    }

    if process.terminationStatus != 0, message.isEmpty {
        message = "Hotspot Keepalive: helper exited unexpectedly."
    }

    return HotspotKeepaliveResult(success: success, message: message, didReconnect: didReconnect)
}

private func hotspotFailureMayStillComplete(_ message: String) -> Bool {
    let normalized = message.lowercased()
        .replacingOccurrences(of: "\u{2018}", with: "'")
        .replacingOccurrences(of: "\u{2019}", with: "'")
    return normalized.contains("80211api") ||
        normalized.contains("-3900") ||
        normalized.contains("tmperr") ||
        normalized.contains("wi-fi join failed") ||
        normalized.contains("association")
}

private func waitForHotspotConnection(targetSSID: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if currentWiFiNetworkName(allowSlowLookup: false) == targetSSID {
            return true
        }
        Thread.sleep(forTimeInterval: 1)
    }
    return currentWiFiNetworkName(allowSlowLookup: true) == targetSSID
}

private struct HotKeyShortcut {
    let storageValue: String
    let displayName: String
    let keyCode: UInt32
    let carbonModifiers: UInt32

    static let defaultShortcut = HotKeyShortcut(
        storageValue: "cmd+option+l",
        displayName: "Cmd-Opt-L",
        keyCode: UInt32(kVK_ANSI_L),
        carbonModifiers: UInt32(cmdKey | optionKey)
    )
}

private final class LidBrightnessController {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let lidAngleDimThreshold = 20.0
    private static let lidAngleRestoreThreshold = 25.0
    private static let noHIDOptions = IOOptionBits(kIOHIDOptionsTypeNone)

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let getBrightness: GetBrightness?
    private let setBrightness: SetBrightness?
    private var builtInDisplayID: CGDirectDisplayID?
    private var lidAngleDevice: IOHIDDevice?
    private var isLidAngleDeviceOpen = false
    private var lidAngleReport = [UInt8](repeating: 0, count: 8)
    private var lastOpenBrightness: Float?
    private var restoreBrightness: Float?
    private var isDimmed = false

    init() {
        frameworkHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        if let frameworkHandle,
           let getSymbol = dlsym(frameworkHandle, "DisplayServicesGetBrightness"),
           let setSymbol = dlsym(frameworkHandle, "DisplayServicesSetBrightness") {
            getBrightness = unsafeBitCast(getSymbol, to: GetBrightness.self)
            setBrightness = unsafeBitCast(setSymbol, to: SetBrightness.self)
        } else {
            getBrightness = nil
            setBrightness = nil
        }
        builtInDisplayID = findBuiltInDisplayID()
        lidAngleDevice = findLidAngleDevice()
    }

    deinit {
        restoreIfNeeded()
        closeLidAngleDevice()
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    func sync(noAjarActive: Bool) {
        guard noAjarActive else {
            restoreIfNeeded()
            lastOpenBrightness = nil
            return
        }

        if shouldDimForCurrentLidPosition() {
            dimIfNeeded()
        } else {
            restoreIfNeeded()
            if let brightness = currentBrightness() {
                lastOpenBrightness = brightness
            }
        }
    }

    func restoreIfNeeded() {
        guard isDimmed else { return }
        if let brightness = restoreBrightness ?? lastOpenBrightness {
            setBrightnessValue(brightness)
        }
        restoreBrightness = nil
        isDimmed = false
    }

    private func dimIfNeeded() {
        guard !isDimmed else { return }
        restoreBrightness = lastOpenBrightness ?? currentBrightness()
        guard setBrightnessValue(0) else { return }
        isDimmed = true
    }

    private func currentBrightness() -> Float? {
        guard let getBrightness,
              let displayID = usableBuiltInDisplayID() else { return nil }

        var brightness: Float = 0
        guard getBrightness(displayID, &brightness) == 0 else { return nil }
        return min(max(brightness, 0), 1)
    }

    @discardableResult
    private func setBrightnessValue(_ brightness: Float) -> Bool {
        guard let setBrightness,
              let displayID = usableBuiltInDisplayID() else { return false }

        let clamped = min(max(brightness, 0), 1)
        return setBrightness(displayID, clamped) == 0
    }

    private func usableBuiltInDisplayID() -> CGDirectDisplayID? {
        if let displayID = findBuiltInDisplayID() {
            builtInDisplayID = displayID
            return displayID
        }
        return builtInDisplayID
    }

    private func findBuiltInDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            let mainDisplayID = CGMainDisplayID()
            return CGDisplayIsBuiltin(mainDisplayID) != 0 ? mainDisplayID : nil
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return nil
        }
        return displays.first { CGDisplayIsBuiltin($0) != 0 }
    }

    private func shouldDimForCurrentLidPosition() -> Bool {
        if let angle = currentLidAngle() {
            let threshold = isDimmed ? Self.lidAngleRestoreThreshold : Self.lidAngleDimThreshold
            return angle <= threshold
        }
        return isLidClosed()
    }

    private func currentLidAngle() -> Double? {
        guard let device = usableLidAngleDevice(),
              openLidAngleDeviceIfNeeded(device) else { return nil }

        var length = CFIndex(lidAngleReport.count)
        let result = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            1,
            &lidAngleReport,
            &length
        )

        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        let rawValue = UInt16(lidAngleReport[2]) << 8 | UInt16(lidAngleReport[1])
        return Double(rawValue)
    }

    private func usableLidAngleDevice() -> IOHIDDevice? {
        if lidAngleDevice == nil {
            lidAngleDevice = findLidAngleDevice()
        }
        return lidAngleDevice
    }

    private func openLidAngleDeviceIfNeeded(_ device: IOHIDDevice) -> Bool {
        guard !isLidAngleDeviceOpen else { return true }
        guard IOHIDDeviceOpen(device, Self.noHIDOptions) == kIOReturnSuccess else { return false }
        isLidAngleDeviceOpen = true
        return true
    }

    private func closeLidAngleDevice() {
        guard isLidAngleDeviceOpen, let device = lidAngleDevice else { return }
        IOHIDDeviceClose(device, Self.noHIDOptions)
        isLidAngleDeviceOpen = false
    }

    private func findLidAngleDevice() -> IOHIDDevice? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, Self.noHIDOptions)
        guard IOHIDManagerOpen(manager, Self.noHIDOptions) == kIOReturnSuccess else { return nil }
        defer { IOHIDManagerClose(manager, Self.noHIDOptions) }

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0x8104,
            kIOHIDPrimaryUsagePageKey as String: 0x0020,
            kIOHIDPrimaryUsageKey as String: 0x008A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        for device in devices {
            guard IOHIDDeviceOpen(device, Self.noHIDOptions) == kIOReturnSuccess else { continue }
            defer { IOHIDDeviceClose(device, Self.noHIDOptions) }

            var report = [UInt8](repeating: 0, count: 8)
            var length = CFIndex(report.count)
            let result = IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeFeature,
                1,
                &report,
                &length
            )
            if result == kIOReturnSuccess, length >= 3 {
                return device
            }
        }

        return nil
    }

    private func isLidClosed() -> Bool {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOPMrootDomain")
        guard entry != 0 else { return false }
        defer { IOObjectRelease(entry) }

        guard let value = IORegistryEntryCreateCFProperty(
            entry,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return false
        }

        if let isClosed = value as? Bool {
            return isClosed
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return false
    }
}

private final class HotKeyRecorderBox: NSView {
    var onActivate: (() -> Void)?
    var isActive = false {
        didSet { updateStyle() }
    }

    private var isPressed = false {
        didSet { updateStyle() }
    }
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { updateStyle() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        updateStyle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        isActive = true
        onActivate?()
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
    }

    private func updateStyle() {
        if isPressed {
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        } else if isActive {
            layer?.borderWidth = 1.5
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        } else if isHovered {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.75).cgColor
        } else {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
        }
    }
}

private final class HotKeyRecorderView: NSView {
    private let shortcutBox = HotKeyRecorderBox()
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "Press a modifier plus a key.")

    var shortcut: HotKeyShortcut?

    init(currentShortcut: HotKeyShortcut) {
        self.shortcut = currentShortcut
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 76))
        setupView(currentShortcut: currentShortcut)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusRecorder()
        }
    }

    override func mouseDown(with event: NSEvent) {
        focusRecorder()
    }

    override func keyDown(with event: NSEvent) {
        _ = record(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        record(event)
    }

    override func flagsChanged(with event: NSEvent) {
        updateModifierState(event)
    }

    func updateModifierState(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        hintLabel.stringValue = flags.intersection([.command, .option, .control, .shift]).isEmpty
            ? "Press a modifier plus a key."
            : "Now press a key."
    }

    func record(_ event: NSEvent) -> Bool {
        guard let shortcut = hotKeyShortcut(from: event) else {
            return false
        }
        self.shortcut = shortcut
        shortcutLabel.stringValue = shortcut.displayName
        hintLabel.stringValue = "Ready to save."
        hintLabel.textColor = .secondaryLabelColor
        setRecordingStyle(active: true)
        return true
    }

    @objc private func focusRecorder() {
        window?.makeFirstResponder(self)
        hintLabel.stringValue = "Listening for keys..."
        hintLabel.textColor = .controlAccentColor
        setRecordingStyle(active: true)
    }

    private func setupView(currentShortcut: HotKeyShortcut) {
        shortcutBox.onActivate = { [weak self] in
            self?.focusRecorder()
        }

        shortcutLabel.stringValue = currentShortcut.displayName
        shortcutLabel.alignment = .center
        shortcutLabel.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
        shortcutLabel.textColor = .labelColor
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center

        shortcutBox.addSubview(shortcutLabel)
        NSLayoutConstraint.activate([
            shortcutLabel.centerXAnchor.constraint(equalTo: shortcutBox.centerXAnchor),
            shortcutLabel.centerYAnchor.constraint(equalTo: shortcutBox.centerYAnchor, constant: -1)
        ])

        let stack = NSStackView(views: [shortcutBox, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            shortcutBox.heightAnchor.constraint(equalToConstant: 44),
            shortcutBox.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        setRecordingStyle(active: false)
    }

    private func setRecordingStyle(active: Bool) {
        shortcutBox.isActive = active
        hintLabel.textColor = active ? .controlAccentColor : .secondaryLabelColor
    }
}

private final class HotKeyRecorderPanel: NSPanel {
    weak var recorder: HotKeyRecorderView?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if recorder?.record(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recorder?.record(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        recorder?.updateModifierState(event)
    }
}

@MainActor
private final class HotKeyPromptController: NSObject {
    private let panel: HotKeyRecorderPanel
    private let recorder: HotKeyRecorderView
    private var result: NSApplication.ModalResponse = .cancel

    init(currentShortcut: HotKeyShortcut) {
        recorder = HotKeyRecorderView(currentShortcut: currentShortcut)
        panel = HotKeyRecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 230),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.recorder = recorder
        setupPanel()
    }

    func run() -> HotKeyShortcut? {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(recorder)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return result == .OK ? recorder.shortcut : nil
    }

    @objc private func save() {
        result = .OK
        NSApp.stopModal()
    }

    @objc private func cancel() {
        result = .cancel
        NSApp.stopModal()
    }

    private func setupPanel() {
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let titleLabel = NSTextField(labelWithString: "Set Hotkey")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.alignment = .center

        let subtitleLabel = NSTextField(labelWithString: "Press the shortcut you want to use.")
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        cancelButton.bezelStyle = .rounded
        saveButton.bezelStyle = .rounded

        let buttonStack = NSStackView(views: [cancelButton, saveButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually

        let stack = NSStackView(views: [titleLabel, subtitleLabel, recorder, buttonStack])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(stack)
        panel.contentView = contentView

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 32),
            recorder.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonStack.widthAnchor.constraint(equalToConstant: 224),
            cancelButton.heightAnchor.constraint(equalToConstant: 32),
            saveButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }
}

private final class WeekdayPillButton: NSButton {
    var isOn = false {
        didSet { updateStyle() }
    }

    init(title: String, fullTitle: String) {
        super.init(frame: .zero)
        self.title = title
        toolTip = fullTitle
        isBordered = false
        wantsLayer = true
        font = .systemFont(ofSize: 12, weight: .medium)
        alignment = .center
        setButtonType(.momentaryChange)
        updateStyle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 54, height: 30)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        sendAction(action, to: target)
    }

    private func updateStyle() {
        layer?.cornerRadius = 8
        layer?.backgroundColor = isOn
            ? NSColor.controlAccentColor.cgColor
            : NSColor.controlBackgroundColor.withAlphaComponent(0.95).cgColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: isOn ? NSColor.white : NSColor.labelColor
            ]
        )
    }
}

private final class ScheduleRuleEditorRow: NSView {
    var onChange: (() -> Void)?
    var onDelete: ((ScheduleRuleEditorRow) -> Void)?

    private let enabledButton = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let modeControl = NSSegmentedControl(labels: ["Awake", "No Ajar"], trackingMode: .selectOne, target: nil, action: nil)
    private let keepHotspotButton = NSButton(checkboxWithTitle: "Hotspot", target: nil, action: nil)
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var weekdayButtons: [(value: Int, button: WeekdayPillButton)] = []
    private let ruleID: String

    init(rule: NoAjarScheduleRule) {
        ruleID = rule.id
        super.init(frame: NSRect(x: 0, y: 0, width: 680, height: 110))
        setupView(rule: rule)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func rule() -> NoAjarScheduleRule {
        let mode: AwakeMode = modeControl.selectedSegment == 1 ? .noAjar : .awake
        return NoAjarScheduleRule(
            id: ruleID,
            enabled: enabledButton.state == .on,
            mode: mode,
            keepHotspotConnected: mode == .noAjar && keepHotspotButton.state == .on,
            weekdays: selectedWeekdays(),
            startMinute: minuteOfDay(from: startPicker.dateValue),
            endMinute: minuteOfDay(from: endPicker.dateValue)
        )
    }

    @objc private func controlChanged() {
        updateHotspotControlState()
        onChange?()
    }

    @objc private func deleteClicked() {
        onDelete?(self)
    }

    private func setupView(rule: NoAjarScheduleRule) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor
        layer?.cornerRadius = 8

        enabledButton.target = self
        enabledButton.action = #selector(controlChanged)
        enabledButton.state = rule.enabled ? .on : .off

        modeControl.target = self
        modeControl.action = #selector(controlChanged)
        modeControl.selectedSegment = rule.mode == .noAjar ? 1 : 0
        modeControl.setWidth(74, forSegment: 0)
        modeControl.setWidth(84, forSegment: 1)

        keepHotspotButton.target = self
        keepHotspotButton.action = #selector(controlChanged)
        keepHotspotButton.state = rule.keepHotspotConnected ? .on : .off
        keepHotspotButton.toolTip = "Keep the saved hotspot connected while this schedule is running."
        updateHotspotControlState()

        configureTimePicker(startPicker, minute: rule.startMinute)
        configureTimePicker(endPicker, minute: rule.endMinute)

        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.bezelStyle = .rounded

        let topStack = NSStackView(views: [
            enabledButton,
            modeControl,
            label("Start"),
            startPicker,
            label("End"),
            endPicker,
            deleteButton
        ])
        topStack.orientation = .horizontal
        topStack.alignment = .centerY
        topStack.spacing = 10

        let dayStack = NSStackView()
        dayStack.orientation = .horizontal
        dayStack.alignment = .centerY
        dayStack.spacing = 6
        for weekday in scheduleWeekdays {
            let button = WeekdayPillButton(title: weekday.title, fullTitle: weekday.fullTitle)
            button.target = self
            button.action = #selector(controlChanged)
            button.isOn = rule.normalizedWeekdays.contains(weekday.value)
            weekdayButtons.append((weekday.value, button))
            dayStack.addArrangedSubview(button)
        }

        let bottomStack = NSStackView(views: [dayStack, keepHotspotButton])
        bottomStack.orientation = .horizontal
        bottomStack.alignment = .centerY
        bottomStack.spacing = 14

        let stack = NSStackView(views: [topStack, bottomStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            modeControl.widthAnchor.constraint(equalToConstant: 164),
            startPicker.widthAnchor.constraint(equalToConstant: 86),
            endPicker.widthAnchor.constraint(equalToConstant: 86)
        ])
    }

    private func updateHotspotControlState() {
        let noAjarSelected = modeControl.selectedSegment == 1
        keepHotspotButton.isEnabled = noAjarSelected
        if !noAjarSelected {
            keepHotspotButton.state = .off
        }
    }

    private func selectedWeekdays() -> [Int] {
        weekdayButtons.compactMap { $0.button.isOn ? $0.value : nil }
    }

    private func configureTimePicker(_ picker: NSDatePicker, minute: Int) {
        picker.datePickerMode = .single
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.hourMinute]
        picker.dateValue = dateForMinuteOfDay(minute)
        picker.target = self
        picker.action = #selector(controlChanged)
        picker.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    }

    private func label(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        return field
    }
}

@MainActor
private final class ScheduleEditorController: NSObject {
    private let panel: NSPanel
    private let enabledButton = NSButton(checkboxWithTitle: "Scheduled Mode", target: nil, action: nil)
    private let rowsStack = NSStackView()
    private let rowsDocumentView = NSView(frame: NSRect(x: 0, y: 0, width: 688, height: 285))
    private let errorLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var rows: [ScheduleRuleEditorRow] = []
    private var result: NoAjarScheduleSettings?

    init(settings: NoAjarScheduleSettings) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        setupPanel(settings: settings)
    }

    func run() -> NoAjarScheduleSettings? {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return result
    }

    @objc private func addRule() {
        appendRow(NoAjarScheduleRule())
        validate()
    }

    @objc private func save() {
        validate()
        guard saveButton.isEnabled else { return }
        result = NoAjarScheduleSettings(
            isEnabled: enabledButton.state == .on,
            rules: rows.map { $0.rule() }
        )
        NSApp.stopModal()
    }

    @objc private func cancel() {
        result = nil
        NSApp.stopModal()
    }

    @objc private func enabledChanged() {
        validate()
    }

    private func setupPanel(settings: NoAjarScheduleSettings) {
        panel.isReleasedWhenClosed = false
        panel.title = "Schedules"
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.closeButton)?.target = self
        panel.standardWindowButton(.closeButton)?.action = #selector(cancel)

        enabledButton.target = self
        enabledButton.action = #selector(enabledChanged)
        enabledButton.state = settings.isEnabled ? .on : .off
        enabledButton.font = .systemFont(ofSize: 13, weight: .medium)

        let subtitleLabel = NSTextField(labelWithString: "Create time windows that automatically start Awake Mode or No Ajar Mode while this app is running.")
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        rowsDocumentView.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: rowsDocumentView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: rowsDocumentView.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: rowsDocumentView.topAnchor),
            rowsStack.bottomAnchor.constraint(lessThanOrEqualTo: rowsDocumentView.bottomAnchor)
        ])

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = rowsDocumentView

        let addButton = NSButton(title: "Add Rule", target: self, action: #selector(addRule))
        addButton.bezelStyle = .rounded
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2

        let buttonStack = NSStackView(views: [addButton, NSView(), cancelButton, saveButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 10

        let stack = NSStackView(views: [subtitleLabel, enabledButton, scrollView, errorLabel, buttonStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(stack)
        panel.contentView = contentView

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 285),
            buttonStack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        let initialRules = settings.rules.isEmpty ? [NoAjarScheduleRule()] : settings.rules
        initialRules.forEach(appendRow)
        validate()
    }

    private func appendRow(_ rule: NoAjarScheduleRule) {
        let row = ScheduleRuleEditorRow(rule: rule)
        row.onChange = { [weak self] in self?.validate() }
        row.onDelete = { [weak self] row in
            self?.removeRow(row)
        }
        rows.append(row)
        rowsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalToConstant: 688).isActive = true
        row.heightAnchor.constraint(equalToConstant: 110).isActive = true
        updateRowsDocumentFrame()
    }

    private func removeRow(_ row: ScheduleRuleEditorRow) {
        rows.removeAll { $0 === row }
        rowsStack.removeArrangedSubview(row)
        row.removeFromSuperview()
        updateRowsDocumentFrame()
        validate()
    }

    private func updateRowsDocumentFrame() {
        let height = max(285, CGFloat(rows.count) * 120)
        rowsDocumentView.setFrameSize(NSSize(width: 688, height: height))
    }

    private func validate() {
        let rules = rows.map { $0.rule() }
        if let emptyWeekdayRule = rules.first(where: { $0.enabled && $0.normalizedWeekdays.isEmpty }) {
            saveButton.isEnabled = false
            errorLabel.stringValue = "Choose at least one day for each enabled rule. Rule \(emptyWeekdayRule.id.prefix(4)) has no days."
            return
        }

        let overlappingIDs = NoAjarScheduleEvaluator.overlappingRuleIDs(rules)
        if !overlappingIDs.isEmpty {
            saveButton.isEnabled = false
            errorLabel.stringValue = "Schedule rules cannot overlap on the same day. Adjust the highlighted time windows."
            return
        }

        saveButton.isEnabled = true
        errorLabel.stringValue = ""
    }
}

private final class HotKeyController: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: @Sendable @MainActor () -> Void

    init(action: @escaping @Sendable @MainActor () -> Void) {
        self.action = action
    }

    deinit {
        unregister()
    }

    func register(shortcut: HotKeyShortcut) throws {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let controller = Unmanaged<HotKeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in
                    controller.action()
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )
        guard installStatus == noErr else {
            throw LidAwakeError("Unable to install hotkey handler: \(installStatus).")
        }

        let hotKeyID = EventHotKeyID(signature: fourCharCode("NOAJ"), id: 1)
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            unregister()
            throw LidAwakeError("Unable to register Cmd-Opt-L hotkey: \(registerStatus).")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}

private final class PrivilegedNoAjarHelperClient {
    private enum Command {
        case enable
        case disable
        case status
    }

    var isAuthorized: Bool {
        (try? send(.status)) != nil
    }

    func authorize(appBundleURL: URL) throws {
        if isAuthorized { return }
        try install(appBundleURL: appBundleURL)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if isAuthorized { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw LidAwakeError("Privileged helper was installed, but did not start.")
    }

    func setNoAjarActive(_ active: Bool) throws {
        try send(active ? .enable : .disable)
    }

    private func send(_ command: Command) throws {
        let connection = NSXPCConnection(machServiceName: noAjarHelperLabel, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: NoAjarHelperProtocol.self)

        let semaphore = DispatchSemaphore(value: 0)
        var responseError: Error?

        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            responseError = error
            semaphore.signal()
        } as? NoAjarHelperProtocol

        guard let proxy else {
            connection.invalidate()
            throw LidAwakeError("Privileged helper connection failed.")
        }

        let reply: (Bool, NSString?) -> Void = { ok, message in
            if let message {
                responseError = LidAwakeError(message as String)
            } else if command != .status, !ok {
                responseError = LidAwakeError("Privileged helper command failed.")
            }
            semaphore.signal()
        }

        switch command {
        case .enable:
            proxy.enableNoAjar(withReply: reply)
        case .disable:
            proxy.disableNoAjar(withReply: reply)
        case .status:
            proxy.status(withReply: reply)
        }

        guard semaphore.wait(timeout: .now() + 5) == .success else {
            connection.invalidate()
            throw LidAwakeError("Privileged helper did not respond.")
        }
        connection.invalidate()
        if let responseError {
            throw responseError
        }
    }

    private func install(appBundleURL: URL) throws {
        let bundledHelperURL = appBundleURL
            .appendingPathComponent("Contents/Library/LaunchServices")
            .appendingPathComponent(noAjarHelperLabel)
        let bundledPlistURL = appBundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons")
            .appendingPathComponent("\(noAjarHelperLabel).plist")

        guard FileManager.default.fileExists(atPath: bundledHelperURL.path) else {
            throw LidAwakeError("Bundled privileged helper was not found. Build the app with `make app`.")
        }
        guard FileManager.default.fileExists(atPath: bundledPlistURL.path) else {
            throw LidAwakeError("Bundled LaunchDaemon plist was not found. Build the app with `make app`.")
        }

        let requirement = try designatedRequirement(for: appBundleURL)
        let shellScript = """
        /bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons
        /usr/bin/install -m 0755 -o root -g wheel \(shellSingleQuoted(bundledHelperURL.path)) \(shellSingleQuoted(noAjarHelperToolURL.path))
        /usr/bin/install -m 0644 -o root -g wheel \(shellSingleQuoted(bundledPlistURL.path)) \(shellSingleQuoted(noAjarHelperLaunchDaemonURL.path))
        /usr/bin/printf %s \(shellSingleQuoted(requirement)) > \(shellSingleQuoted(noAjarHelperClientRequirementURL.path))
        /usr/sbin/chown root:wheel \(shellSingleQuoted(noAjarHelperClientRequirementURL.path))
        /bin/chmod 0644 \(shellSingleQuoted(noAjarHelperClientRequirementURL.path))
        /bin/launchctl bootout system \(shellSingleQuoted(noAjarHelperLaunchDaemonURL.path)) >/dev/null 2>&1 || true
        /bin/launchctl bootstrap system \(shellSingleQuoted(noAjarHelperLaunchDaemonURL.path))
        /bin/launchctl enable system/\(noAjarHelperLabel)
        /bin/launchctl kickstart -k system/\(noAjarHelperLabel)
        """

        try runPrivilegedShell(script: shellScript)
    }

    private func designatedRequirement(for appBundleURL: URL) throws -> String {
        var code: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(appBundleURL as CFURL, [], &code)
        guard createStatus == errSecSuccess, let code else {
            throw LidAwakeError("Could not read NoAjar code signature: \(createStatus).")
        }

        var requirement: SecRequirement?
        let requirementStatus = SecCodeCopyDesignatedRequirement(code, [], &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            throw LidAwakeError("Could not read NoAjar designated requirement: \(requirementStatus).")
        }

        var requirementText: CFString?
        let copyStatus = SecRequirementCopyString(requirement, [], &requirementText)
        guard copyStatus == errSecSuccess, let requirementText else {
            throw LidAwakeError("Could not stringify NoAjar designated requirement: \(copyStatus).")
        }

        return String(requirementText)
    }

    private func runPrivilegedShell(script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"\(appleScriptEscaped(script))\" with administrator privileges"
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LidAwakeError(message.isEmpty ? (fallback.isEmpty ? "Privileged helper install failed." : fallback) : message)
        }
    }
}

private final class DurationChoice: NSObject {
    let duration: TimeInterval?

    init(duration: TimeInterval?) {
        self.duration = duration
    }
}

private enum HotspotKeepaliveTiming {
    static let connectedSoon: TimeInterval = 10
    static let stableConnected: TimeInterval = 45
    static let aliveButUnconfirmed: TimeInterval = 30
    static let disconnectedRetry: TimeInterval = 8
    static let disconnectedRetryStep: TimeInterval = 6
    static let disconnectedRetryMax: TimeInterval = 30
    static let activeFailureRetry: TimeInterval = 20
    static let activeFailureRetryStep: TimeInterval = 15
    static let activeFailureRetryMax: TimeInterval = 60
    static let confirmationWindow: TimeInterval = 60
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SPUUpdaterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let launchAgent = LaunchAgent(label: "dev.local.noajar")
    private let privilegedHelper = PrivilegedNoAjarHelperClient()
    private let lidBrightnessController = LidBrightnessController()

    private var session: LidAwakeSession?
    private var sessionSource: SessionSource?
    private var activeMode: AwakeMode?
    private var activeDurationSeconds: TimeInterval?
    private var sessionEndsAt: Date?
    private var monitorTimer: Timer?
    private var lidBrightnessTimer: Timer?
    private var hotspotKeepaliveTimer: Timer?
    private var hotKeyController: HotKeyController?
    private var isRecordingHotKey = false

    private var minBatteryPercent = 30
    private var batteryStopEnabled = true
    private var hotspotKeepaliveEnabled = false
    private var hotspotSSID: String?
    private var activeSessionHotspotKeepaliveEnabled = false
    private var hotspotKeepaliveInProgress = false
    private var hotspotKeepaliveFailureCount = 0
    private var lastHotspotConnectionConfirmedAt: Date?
    private var scheduleSettings = NoAjarScheduleSettings()
    private var scheduleSuppressions: [NoAjarScheduleSuppression] = []
    private var autoWatchedApps = false
    private var autoAwakeMode = AwakeMode.awake
    private var hotKeyEnabled = true
    private var hotKeyShortcut = HotKeyShortcut.defaultShortcut
    private var betaUpdateCheckInProgress = false
    private var watchedApps: [String] = []
    private var lastAutomationReasons: [String] = []
    private var lastMessage: String?
    private var isMenuOpen = false
    private var lastHotKeyActivationAt: Date?
    private var automationSuppressedUntil: Date?
    private var activeAutomationScheduleWindow: NoAjarScheduleWindow?
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "NoAjar"
        repairStaleStateIfNeeded()
        loadPreferences()
        menu.delegate = self
        setupSparkleUpdater()
        setupHotKey()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.monitorTick()
            }
        }
        lidBrightnessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncLidBrightness()
            }
        }
        monitorTick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitorTimer?.invalidate()
        lidBrightnessTimer?.invalidate()
        hotspotKeepaliveTimer?.invalidate()
        stopSession()
        lidBrightnessController.restoreIfNeeded()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        lastHotKeyActivationAt = Date()
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        autoWatchedApps = defaults.bool(forKey: "autoWatchedApps")
        hotKeyEnabled = defaults.object(forKey: "hotKeyEnabled") as? Bool ?? true
        if let storedShortcut = defaults.string(forKey: "hotKeyShortcut"),
           let shortcut = parseHotKeyShortcut(storedShortcut) {
            hotKeyShortcut = shortcut
        }
        minBatteryPercent = defaults.object(forKey: "minBatteryPercent") as? Int ?? 30
        batteryStopEnabled = defaults.object(forKey: "batteryGuardEnabled") as? Bool ?? true
        hotspotKeepaliveEnabled = defaults.bool(forKey: "hotspotKeepaliveEnabled")
        hotspotSSID = defaults.string(forKey: "hotspotSSID")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        if let rawMode = defaults.string(forKey: "autoAwakeMode"),
           let mode = AwakeMode(rawValue: rawMode) {
            autoAwakeMode = mode
        }
        if let data = defaults.data(forKey: scheduleSettingsDefaultsKey),
           let decoded = try? JSONDecoder().decode(NoAjarScheduleSettings.self, from: data) {
            scheduleSettings = decoded
        }
        if let data = defaults.data(forKey: scheduleSuppressionsDefaultsKey),
           let decoded = try? JSONDecoder().decode([NoAjarScheduleSuppression].self, from: data) {
            scheduleSuppressions = NoAjarScheduleEvaluator.suppressions(decoded, validAt: Date())
        }
        if let storedApps = defaults.stringArray(forKey: "watchedApps") {
            watchedApps = storedApps
        }
    }

    private func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "allowBattery")
        defaults.set(batteryStopEnabled, forKey: "batteryGuardEnabled")
        defaults.set(hotspotKeepaliveEnabled, forKey: "hotspotKeepaliveEnabled")
        if let hotspotSSID {
            defaults.set(hotspotSSID, forKey: "hotspotSSID")
        } else {
            defaults.removeObject(forKey: "hotspotSSID")
        }
        defaults.set(false, forKey: "preventDisplaySleep")
        defaults.set(autoWatchedApps, forKey: "autoWatchedApps")
        defaults.set(false, forKey: "powerProtectEnabled")
        defaults.set(hotKeyEnabled, forKey: "hotKeyEnabled")
        defaults.set(hotKeyShortcut.storageValue, forKey: "hotKeyShortcut")
        defaults.set(minBatteryPercent, forKey: "minBatteryPercent")
        defaults.set(autoAwakeMode.rawValue, forKey: "autoAwakeMode")
        defaults.set(watchedApps, forKey: "watchedApps")
        if let data = try? JSONEncoder().encode(scheduleSettings) {
            defaults.set(data, forKey: scheduleSettingsDefaultsKey)
        }
        if let data = try? JSONEncoder().encode(scheduleSuppressions) {
            defaults.set(data, forKey: scheduleSuppressionsDefaultsKey)
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.autoenablesItems = false

        statusItem.button?.title = menuBarStatusTitle()

        menu.addItem(statusHeaderMenuItem())
        menu.addItem(.separator())
        menu.addItem(modeToggleMenuItem(.noAjar))
        menu.addItem(modeToggleMenuItem(.awake))
        menu.addItem(durationMenuItem())
        menu.addItem(scheduleMenuItem())
        menu.addItem(hotspotConnectionMenuItem())

        menu.addItem(.separator())
        menu.addItem(appsMenuItem())
        menu.addItem(preferencesMenuItem())

        menu.addItem(.separator())
        let quitItem = actionItem("Quit", #selector(quitClicked), keyEquivalent: "q", keyEquivalentModifierMask: [.command])
        applyIcon("rectangle.portrait.and.arrow.right", to: quitItem)
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func statusHeaderMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let rows = statusHeaderRows()
        let width: CGFloat = 420
        let spacing: CGFloat = 4
        let verticalPadding: CGFloat = 8
        let height = rows.reduce(verticalPadding * 2) { total, row in
            total + ceil(row.font.ascender - row.font.descender + row.font.leading)
        } + CGFloat(max(0, rows.count - 1)) * spacing
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: verticalPadding, left: 18, bottom: verticalPadding, right: 18)

        for row in rows {
            let label = NSTextField(labelWithString: row.text)
            label.font = row.font
            label.textColor = row.color
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(lessThanOrEqualToConstant: width - 36).isActive = true
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        stack.frame = container.bounds
        stack.autoresizingMask = [.width, .height]
        container.addSubview(stack)
        item.view = container
        return item
    }

    private func statusHeaderRows() -> [(text: String, font: NSFont, color: NSColor)] {
        let snapshot = statusSnapshot()
        let power = snapshot.power.percent.map { "\(snapshot.power.source) \($0)%" } ?? snapshot.power.source
        var rows: [(text: String, font: NSFont, color: NSColor)] = [
            (statusTitle(), .systemFont(ofSize: 14, weight: .semibold), .labelColor),
            ("Power: \(power)", .systemFont(ofSize: 13, weight: .regular), .labelColor)
        ]

        if !lastAutomationReasons.isEmpty {
            rows.append((
                "Trigger: \(lastAutomationReasons.joined(separator: ", "))",
                .systemFont(ofSize: 13, weight: .regular),
                .labelColor
            ))
        }
        if let lastMessage {
            rows.append((
                lastMessage,
                .systemFont(ofSize: 13, weight: .medium),
                .systemOrange
            ))
        }
        if displayedHotspotKeepaliveEnabled {
            let target = hotspotSSID.map { " -> \($0)" } ?? ""
            rows.append((
                "Keep Hotspot Connected: On\(target)",
                .systemFont(ofSize: 13, weight: .regular),
                .secondaryLabelColor
            ))
        }
        return rows
    }

    private var displayedHotspotKeepaliveEnabled: Bool {
        session == nil ? hotspotKeepaliveEnabled : activeSessionHotspotKeepaliveEnabled
    }

    private func menuBarStatusTitle() -> String {
        guard let activeMode else {
            return "💤"
        }

        switch activeMode {
        case .awake:
            return "☕"
        case .noAjar:
            return "🚀"
        }
    }

    private func statusTitle() -> String {
        guard let activeMode else {
            return "Off"
        }

        let source = sessionSource == .automation ? "Auto" : "Manual"
        return "\(activeMode.displayName), \(timeStatus()), \(source)"
    }

    private func timeStatus() -> String {
        guard let sessionEndsAt else {
            return "until stopped"
        }

        let remaining = max(0, Int(sessionEndsAt.timeIntervalSinceNow))
        if remaining >= 3600 {
            return "\(remaining / 3600)h \((remaining % 3600) / 60)m left"
        }
        return "\(max(1, remaining / 60))m left"
    }

    private func modeToggleMenuItem(_ mode: AwakeMode) -> NSMenuItem {
        let item = actionItem(
            mode.displayName,
            mode == .noAjar ? #selector(toggleNoAjarMode) : #selector(toggleAwakeMode)
        )
        item.state = activeMode == mode ? .on : .off
        applyIcon(mode == .noAjar ? "waveform.path.ecg" : "cup.and.saucer", to: item)
        return item
    }

    private func durationMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Duration: \(durationLabel(activeDurationSeconds))", action: nil, keyEquivalent: "")
        applyIcon("clock", to: parent)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for option in durationOptions {
            let item = NSMenuItem(
                title: option.title,
                action: #selector(changeDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = DurationChoice(duration: option.seconds)
            item.state = durationsMatch(activeDurationSeconds, option.seconds) ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(batteryThresholdMenuItem())
        parent.submenu = submenu
        return parent
    }

    private func scheduleMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: scheduleMenuTitle(), action: nil, keyEquivalent: "")
        parent.state = scheduleSettings.isEnabled ? .on : .off
        applyIcon("calendar.badge.clock", to: parent)

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        submenu.addItem(iconItem("Edit Schedules...", #selector(editSchedules), symbolName: "calendar.badge.plus"))
        submenu.addItem(.separator())
        if let active = activeScheduleWindow() {
            submenu.addItem(disabledItem("Active: \(scheduleSummary(active, prefixWithDay: false))"))
        } else if let next = NoAjarScheduleEvaluator.nextWindow(settings: scheduleSettings) {
            submenu.addItem(disabledItem("Next: \(scheduleSummary(next, prefixWithDay: true))"))
        } else {
            submenu.addItem(disabledItem(scheduleSettings.isEnabled ? "No upcoming schedule" : "Schedule is off"))
        }

        parent.submenu = submenu
        return parent
    }

    private func scheduleMenuTitle() -> String {
        guard scheduleSettings.isEnabled else {
            return "Schedule: Off"
        }
        if activeScheduleWindow() != nil {
            return "Schedule: Active"
        }
        let count = scheduleSettings.rules.filter { $0.enabled }.count
        return count == 1 ? "Schedule: 1 Rule" : "Schedule: \(count) Rules"
    }

    private func scheduleSummary(_ window: NoAjarScheduleWindow, prefixWithDay: Bool) -> String {
        let time = "\(timeFormatter.string(from: window.start))-\(timeFormatter.string(from: window.end))"
        if prefixWithDay {
            return "\(weekdayFormatter.string(from: window.start)) \(time), \(window.rule.mode.displayName)"
        }
        return "\(time), \(window.rule.mode.displayName)"
    }

    private func hotspotConnectionMenuItem() -> NSMenuItem {
        let title = hotspotKeepaliveEnabled ? "Keep Hotspot Connected: On" : "Keep Hotspot Connected: Off"
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.state = hotspotKeepaliveEnabled ? .on : .off
        applyIcon("wifi", to: parent)

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let toggle = toggleItem("Keep Hotspot Connected", #selector(toggleHotspotKeepalive), state: hotspotKeepaliveEnabled)
        applyIcon("wifi", to: toggle)
        submenu.addItem(toggle)

        let hotspot = disabledItem("Hotspot: \(hotspotSSID ?? "Not Set")")
        applyIcon("iphone", to: hotspot)
        submenu.addItem(hotspot)

        submenu.addItem(.separator())
        submenu.addItem(iconItem("Use Current Wi-Fi as Hotspot", #selector(useCurrentWiFiAsHotspot), symbolName: "antenna.radiowaves.left.and.right"))
        submenu.addItem(iconItem("Forget Hotspot", #selector(clearHotspotNetwork), symbolName: "trash", enabled: hotspotSSID != nil))

        parent.submenu = submenu
        return parent
    }

    private func appsMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Apps", action: nil, keyEquivalent: "")
        applyIcon("square.grid.2x2", to: parent)
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let autoAwake = toggleItem("App Auto Awake", #selector(toggleAutoWatchedApps), state: autoWatchedApps)
        applyIcon("bolt", to: autoAwake)
        submenu.addItem(autoAwake)
        submenu.addItem(iconItem("Add Apps...", #selector(editWatchedApps), symbolName: "plus.app"))
        submenu.addItem(iconItem("Clear Apps", #selector(clearWatchedApps), symbolName: "trash", enabled: !watchedApps.isEmpty))
        submenu.addItem(appAutoModeMenuItem())
        submenu.addItem(disabledItem("Apps: \(watchedApps.joined(separator: ", "))"))

        parent.submenu = submenu
        return parent
    }

    private func preferencesMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        applyIcon("gearshape", to: parent)
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        submenu.addItem(hotkeyMenuItem())
        let launchAtLogin = toggleItem("Launch at Login", #selector(toggleLaunchAtLogin), state: launchAgent.isEnabled)
        applyIcon("arrow.clockwise.circle", to: launchAtLogin)
        submenu.addItem(launchAtLogin)
        submenu.addItem(.separator())
        submenu.addItem(iconItem("Check for Updates...", #selector(checkForUpdatesClicked), symbolName: "arrow.down.circle", enabled: sparkleUpdater != nil))
        let updateChecks = toggleItem(
            "Automatically Check for Updates",
            #selector(toggleAutomaticUpdateChecks),
            state: sparkleUpdater?.automaticallyChecksForUpdates ?? false,
            enabled: sparkleUpdater != nil
        )
        applyIcon("arrow.triangle.2.circlepath", to: updateChecks)
        submenu.addItem(updateChecks)
        let installUpdates = toggleItem(
            "Automatically Install Updates",
            #selector(toggleAutomaticInstallUpdates),
            state: sparkleUpdater?.automaticallyDownloadsUpdates ?? false,
            enabled: sparkleUpdater?.allowsAutomaticUpdates ?? false
        )
        applyIcon("arrow.down.app", to: installUpdates)
        submenu.addItem(installUpdates)
        let betaUpdates = iconItem(
            betaUpdateCheckInProgress ? "Checking Beta Updates..." : "Try Beta Updates",
            #selector(tryBetaUpdatesClicked),
            symbolName: "sparkles",
            enabled: sparkleUpdater != nil && !betaUpdateCheckInProgress
        )
        submenu.addItem(betaUpdates)
        submenu.addItem(disabledItem("Version: \(appVersionDisplay())"))

        parent.submenu = submenu
        return parent
    }

    private func hotkeyMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Hotkey: \(hotKeyShortcut.displayName)", action: nil, keyEquivalent: "")
        applyIcon("keyboard", to: parent)
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let enabled = toggleItem("Enabled", #selector(toggleHotKey), state: hotKeyEnabled)
        applyIcon("checkmark.circle", to: enabled)
        submenu.addItem(enabled)
        submenu.addItem(iconItem("Set Hotkey...", #selector(setHotKeyShortcut), symbolName: "keyboard.badge.ellipsis"))

        parent.submenu = submenu
        return parent
    }

    private func batteryThresholdMenuItem() -> NSMenuItem {
        let title = batteryStopEnabled ? "Stop Below \(minBatteryPercent)%" : "Stop Below: Keep Running"
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        applyIcon("battery.75percent", to: parent)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let keepRunningItem = NSMenuItem(title: "Keep Running", action: #selector(setBatteryThreshold(_:)), keyEquivalent: "")
        keepRunningItem.target = self
        keepRunningItem.tag = 0
        keepRunningItem.state = batteryStopEnabled ? .off : .on
        submenu.addItem(keepRunningItem)
        submenu.addItem(.separator())
        for threshold in [20, 30, 40, 50] {
            let item = NSMenuItem(title: "\(threshold)%", action: #selector(setBatteryThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.tag = threshold
            item.state = batteryStopEnabled && threshold == minBatteryPercent ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func appAutoModeMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Mode: \(autoAwakeMode.displayName)", action: nil, keyEquivalent: "")
        applyIcon("slider.horizontal.3", to: parent)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for mode in AwakeMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(setAutoAwakeMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = autoAwakeMode == mode ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func addItem(
        _ title: String,
        _ action: Selector,
        keyEquivalent: String = "",
        keyEquivalentModifierMask: NSEvent.ModifierFlags? = nil,
        enabled: Bool = true
    ) {
        menu.addItem(actionItem(
            title,
            action,
            keyEquivalent: keyEquivalent,
            keyEquivalentModifierMask: keyEquivalentModifierMask,
            enabled: enabled
        ))
    }

    private func actionItem(
        _ title: String,
        _ action: Selector,
        keyEquivalent: String = "",
        keyEquivalentModifierMask: NSEvent.ModifierFlags? = nil,
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = enabled
        if let keyEquivalentModifierMask {
            item.keyEquivalentModifierMask = keyEquivalentModifierMask
        }
        return item
    }

    private func iconItem(
        _ title: String,
        _ action: Selector,
        symbolName: String,
        keyEquivalent: String = "",
        keyEquivalentModifierMask: NSEvent.ModifierFlags? = nil,
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = actionItem(
            title,
            action,
            keyEquivalent: keyEquivalent,
            keyEquivalentModifierMask: keyEquivalentModifierMask,
            enabled: enabled
        )
        applyIcon(symbolName, to: item)
        return item
    }

    @discardableResult
    private func applyIcon(_ symbolName: String, to item: NSMenuItem) -> NSMenuItem {
        item.image = menuIcon(symbolName)
        return item
    }

    private func menuIcon(_ symbolName: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return nil
        }
        let configured = image.withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? image
        configured.isTemplate = true
        configured.size = NSSize(width: 18, height: 18)
        return configured
    }

    private func toggleItem(_ title: String, _ action: Selector, state: Bool, enabled: Bool = true) -> NSMenuItem {
        let item = actionItem(title, action, enabled: enabled)
        item.state = state ? .on : .off
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func changeDuration(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? DurationChoice else {
            return
        }
        activeDurationSeconds = choice.duration
        guard let activeMode else {
            lastMessage = "Duration set to \(durationLabel(choice.duration))."
            rebuildMenu()
            return
        }

        startManualSession(mode: activeMode, duration: choice.duration)
    }

    @objc private func toggleNoAjarMode() {
        toggleMode(.noAjar)
    }

    @objc private func toggleAwakeMode() {
        toggleMode(.awake)
    }

    private func toggleMode(_ mode: AwakeMode) {
        if activeMode == mode {
            suppressActiveScheduleIfNeeded()
            stopSession()
            rebuildMenu()
            return
        }

        startManualSession(mode: mode, duration: activeDurationSeconds)
    }

    @objc private func setBatteryThreshold(_ sender: NSMenuItem) {
        applyBatteryThreshold(enabled: sender.tag > 0, percent: sender.tag > 0 ? sender.tag : nil)
    }

    private func applyBatteryThreshold(enabled: Bool, percent: Int?) {
        batteryStopEnabled = enabled
        if let percent {
            minBatteryPercent = percent
        }
        if session != nil {
            lastMessage = "Battery setting applies to the next session."
        }
        savePreferences()
        rebuildMenu()
    }

    @objc private func editSchedules() {
        openScheduleEditor(with: scheduleSettings)
    }

    private func openScheduleEditor(with settings: NoAjarScheduleSettings) {
        guard let updated = ScheduleEditorController(settings: settings).run() else {
            rebuildMenu()
            return
        }
        applyScheduleSettings(updated)
    }

    private func applyScheduleSettings(_ settings: NoAjarScheduleSettings) {
        if settings.isEnabled,
           settings.rules.contains(where: { $0.enabled && $0.mode == .noAjar }),
           !privilegedHelper.isAuthorized,
           !authorizeNoAjarMode() {
            rebuildMenu()
            return
        }

        let overlappingIDs = NoAjarScheduleEvaluator.overlappingRuleIDs(settings.rules)
        guard overlappingIDs.isEmpty else {
            showError("Schedule rules cannot overlap on the same day.")
            rebuildMenu()
            return
        }

        scheduleSettings = settings
        scheduleSuppressions = NoAjarScheduleEvaluator.suppressions(scheduleSuppressions, validAt: Date())
        if !scheduleSettings.isEnabled {
            scheduleSuppressions = []
        }
        savePreferences()
        monitorTick()
        rebuildMenu()
    }

    @objc private func toggleHotspotKeepalive() {
        hotspotKeepaliveEnabled.toggle()
        if hotspotKeepaliveEnabled, hotspotSSID == nil {
            hotspotSSID = wifiStatus().currentSSID
        }
        if !hotspotKeepaliveEnabled {
            resetHotspotKeepaliveSchedule()
        }
        if session != nil, activeAutomationScheduleWindow == nil {
            activeSessionHotspotKeepaliveEnabled = hotspotKeepaliveEnabled
        }
        savePreferences()
        if hotspotKeepaliveEnabled, let hotspotSSID {
            lastMessage = "Keep Hotspot Connected enabled for \(hotspotSSID)."
        } else {
            lastMessage = hotspotKeepaliveEnabled ? "Keep Hotspot Connected enabled." : "Keep Hotspot Connected disabled."
        }
        runHotspotKeepalive(showSuccess: true)
        rebuildMenu()
    }

    @objc private func useCurrentWiFiAsHotspot() {
        let ssid: String
        if let currentSSID = currentWiFiNetworkName(allowSlowLookup: true)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty {
            ssid = currentSSID
        } else if let enteredSSID = promptHotspotSSID(defaultValue: hotspotSSID ?? wifiStatus().currentSSID) {
            ssid = enteredSSID
        } else {
            return
        }

        hotspotSSID = ssid
        hotspotKeepaliveEnabled = true
        if session != nil, activeAutomationScheduleWindow == nil {
            activeSessionHotspotKeepaliveEnabled = true
        }
        resetHotspotKeepaliveSchedule()
        savePreferences()
        lastMessage = "Hotspot set to \(ssid)."
        runHotspotKeepalive(showSuccess: true)
        rebuildMenu()
    }

    @objc private func clearHotspotNetwork() {
        hotspotSSID = nil
        resetHotspotKeepaliveSchedule()
        savePreferences()
        lastMessage = "Hotspot forgotten."
        rebuildMenu()
    }

    @objc private func toggleAutoWatchedApps() {
        if !autoWatchedApps, autoAwakeMode == .noAjar, !privilegedHelper.isAuthorized {
            guard authorizeNoAjarMode() else {
                rebuildMenu()
                return
            }
        }
        autoWatchedApps.toggle()
        savePreferences()
        monitorTick()
        rebuildMenu()
    }

    @objc private func setAutoAwakeMode(_ sender: NSMenuItem) {
        guard let rawMode = sender.representedObject as? String,
              let mode = AwakeMode(rawValue: rawMode) else {
            return
        }
        _ = applyAutoAwakeMode(mode)
    }

    @discardableResult
    private func applyAutoAwakeMode(_ mode: AwakeMode) -> Bool {
        if mode == .noAjar, !privilegedHelper.isAuthorized, !authorizeNoAjarMode() {
            rebuildMenu()
            return false
        }
        autoAwakeMode = mode
        savePreferences()
        monitorTick()
        rebuildMenu()
        return true
    }

    @objc private func clearWatchedApps() {
        watchedApps = []
        savePreferences()
        monitorTick()
        rebuildMenu()
    }

    @objc private func editWatchedApps() {
        let panel = NSOpenPanel()
        panel.title = "Choose apps to keep NoAjar awake"
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]

        guard panel.runModal() == .OK else { return }

        var names = watchedApps
        for url in panel.urls {
            guard let processName = appProcessName(from: url), !names.contains(processName) else {
                continue
            }
            names.append(processName)
        }
        watchedApps = names.sorted()
        savePreferences()
        monitorTick()
        rebuildMenu()
    }

    @objc private func toggleHotKey() {
        hotKeyEnabled.toggle()
        savePreferences()
        setupHotKey()
        rebuildMenu()
    }

    @objc private func setHotKeyShortcut() {
        hotKeyController?.unregister()
        hotKeyController = nil
        isRecordingHotKey = true
        defer {
            isRecordingHotKey = false
            setupHotKey()
        }

        guard let shortcut = promptHotKeyShortcut() else { return }

        hotKeyShortcut = shortcut
        hotKeyEnabled = true
        savePreferences()
        rebuildMenu()
    }

    private func promptHotKeyShortcut() -> HotKeyShortcut? {
        HotKeyPromptController(currentShortcut: hotKeyShortcut).run()
    }

    @objc private func toggleLaunchAtLogin() {
        guard let executablePath = Bundle.main.executablePath else {
            showError("Unable to find app executable path.")
            return
        }

        do {
            try launchAgent.setEnabled(!launchAgent.isEnabled, executablePath: executablePath)
            rebuildMenu()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func checkForUpdatesClicked() {
        sparkleUpdaterController?.checkForUpdates(nil)
    }

    @objc private func toggleAutomaticUpdateChecks() {
        guard let sparkleUpdater else { return }
        sparkleUpdater.automaticallyChecksForUpdates.toggle()
        rebuildMenu()
    }

    @objc private func toggleAutomaticInstallUpdates() {
        guard let sparkleUpdater, sparkleUpdater.allowsAutomaticUpdates else { return }
        sparkleUpdater.automaticallyDownloadsUpdates.toggle()
        rebuildMenu()
    }

    @objc private func tryBetaUpdatesClicked() {
        guard sparkleUpdater != nil else { return }
        betaUpdateCheckInProgress = true
        sparkleUpdaterController?.checkForUpdates(nil)
        rebuildMenu()
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    private func setupHotKey() {
        hotKeyController?.unregister()
        hotKeyController = nil

        guard hotKeyEnabled else { return }

        do {
            let controller = HotKeyController { [weak self] in
                self?.toggleFromHotKey()
            }
            try controller.register(shortcut: hotKeyShortcut)
            hotKeyController = controller
        } catch {
            hotKeyEnabled = false
            savePreferences()
            showError(error.localizedDescription)
        }
    }

    private func setupSparkleUpdater() {
        sparkleUpdaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    private var sparkleUpdater: SPUUpdater? {
        sparkleUpdaterController?.updater
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        betaUpdateCheckInProgress ? betaAppcastURLString : nil
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        betaUpdateCheckInProgress = false
        rebuildMenu()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        betaUpdateCheckInProgress = false
        rebuildMenu()
    }

    private func toggleFromHotKey() {
        guard !isRecordingHotKey else { return }
        let now = Date()
        if let lastHotKeyActivationAt,
           now.timeIntervalSince(lastHotKeyActivationAt) < 0.6 {
            return
        }
        guard !isMenuOpen else { return }

        lastHotKeyActivationAt = now
        rebuildMenu()
        statusItem.button?.performClick(nil)
    }

    private func startManualSession(mode: AwakeMode, duration: TimeInterval? = nil) {
        if mode == .noAjar, !privilegedHelper.isAuthorized {
            guard authorizeNoAjarMode() else {
                rebuildMenu()
                return
            }
        }
        if mode == .noAjar, activeMode != .noAjar {
            promptHotspotKeepaliveForNoAjarStart()
        }
        if session != nil {
            suppressActiveScheduleIfNeeded()
            stopSession()
        }
        startSession(mode: mode, duration: duration, source: .manual, reason: mode.displayName, showErrors: true)
    }

    private func promptHotspotKeepaliveForNoAjarStart() {
        guard let hotspotSSID else { return }

        let alert = NSAlert()
        alert.messageText = "Keep Hotspot Connected?"
        alert.informativeText = "NoAjar can keep \(hotspotSSID) connected while No Ajar Mode is on."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: hotspotKeepaliveEnabled ? "Keep On" : "Turn On")

        let shouldEnableHotspotKeepalive = alert.runModal() == .alertSecondButtonReturn
        guard hotspotKeepaliveEnabled != shouldEnableHotspotKeepalive else { return }
        hotspotKeepaliveEnabled = shouldEnableHotspotKeepalive
        if !shouldEnableHotspotKeepalive {
            resetHotspotKeepaliveSchedule()
        }
        savePreferences()
    }

    private func startSession(
        mode: AwakeMode,
        duration: TimeInterval?,
        source: SessionSource,
        reason: String,
        showErrors: Bool,
        scheduleWindow: NoAjarScheduleWindow? = nil
    ) {
        guard session == nil else { return }
        if source == .automation, mode == .noAjar, !privilegedHelper.isAuthorized {
            lastMessage = "No Ajar Mode needs admin authorization."
            return
        }

        do {
            let usesNoAjarHelper = mode == .noAjar && privilegedHelper.isAuthorized
            let effectiveHotspotKeepalive = effectiveHotspotKeepaliveEnabled(mode: mode, scheduleWindow: scheduleWindow)
            let options = LidAwakeOptions(
                mode: mode,
                allowBattery: true,
                batteryGuardEnabled: batteryStopEnabled,
                minBatteryPercent: minBatteryPercent,
                durationSeconds: duration,
                preventDisplaySleep: false,
                manageLidSleepOverride: !usesNoAjarHelper,
                hotspotKeepaliveEnabled: effectiveHotspotKeepalive,
                hotspotSSID: hotspotSSID,
                reason: "NoAjar \(reason)"
            )
            let newSession = LidAwakeSession(options: options)
            try newSession.start()
            if usesNoAjarHelper {
                try privilegedHelper.setNoAjarActive(true)
            }
            session = newSession
            sessionSource = source
            activeMode = mode
            activeDurationSeconds = duration
            sessionEndsAt = duration.map { Date().addingTimeInterval($0) }
            activeAutomationScheduleWindow = source == .automation ? scheduleWindow : nil
            activeSessionHotspotKeepaliveEnabled = effectiveHotspotKeepalive
            lastMessage = nil
            syncLidBrightness()
            runHotspotKeepalive(showSuccess: false)
            rebuildMenu()
        } catch {
            lastMessage = error.localizedDescription
            if source == .automation {
                automationSuppressedUntil = Date().addingTimeInterval(5 * 60)
                lastMessage = "Auto Awake paused for 5 minutes: \(error.localizedDescription)"
            }
            if showErrors {
                showError(error.localizedDescription)
            }
        }
    }

    private func stopSession() {
        let shouldRestoreBrightness = activeMode == .noAjar
        if activeMode == .noAjar {
            do {
                try privilegedHelper.setNoAjarActive(false)
            } catch {
                lastMessage = error.localizedDescription
            }
        }
        session?.stop()
        session = nil
        sessionSource = nil
        activeMode = nil
        sessionEndsAt = nil
        activeAutomationScheduleWindow = nil
        activeSessionHotspotKeepaliveEnabled = false
        resetHotspotKeepaliveSchedule()
        if shouldRestoreBrightness {
            lidBrightnessController.restoreIfNeeded()
        }
    }

    private func monitorTick() {
        syncLidBrightness()
        pruneScheduleSuppressions()
        checkSafety()
        evaluateAutomation()
        rebuildMenu()
    }

    private func hotspotKeepaliveTick() {
        hotspotKeepaliveTimer = nil
        runHotspotKeepalive(showSuccess: false)
    }

    private func effectiveHotspotKeepaliveEnabled(
        mode: AwakeMode,
        scheduleWindow: NoAjarScheduleWindow?
    ) -> Bool {
        if mode == .noAjar,
           let scheduleWindow,
           scheduleWindow.rule.mode == .noAjar {
            return scheduleWindow.rule.keepHotspotConnected
        }
        return hotspotKeepaliveEnabled
    }

    private func runHotspotKeepalive(
        showSuccess: Bool,
        requiresActiveSession: Bool = true,
        forceReconnect: Bool = false
    ) {
        let keepaliveEnabled = requiresActiveSession ? activeSessionHotspotKeepaliveEnabled : hotspotKeepaliveEnabled
        guard keepaliveEnabled else {
            resetHotspotKeepaliveSchedule()
            return
        }
        guard !hotspotKeepaliveInProgress else { return }
        if requiresActiveSession {
            guard session != nil,
                  activeMode == .noAjar else {
                resetHotspotKeepaliveSchedule()
                return
            }
        }

        hotspotKeepaliveInProgress = true
        let targetSSID = hotspotSSID
        syncHotspotConnectionConfidence(targetSSID: targetSSID)
        let effectiveForceReconnect = forceReconnect || shouldForceSavedHotspotReconnect(
            targetSSID: targetSSID,
            requiresActiveSession: requiresActiveSession
        )
        if let targetSSID,
           shouldShowHotspotConnectionProgress(targetSSID: targetSSID) {
            lastMessage = "Connecting to \(targetSSID)..."
            rebuildMenu()
        }
        Task.detached(priority: .utility) { [showSuccess, targetSSID, requiresActiveSession, effectiveForceReconnect] in
            let result = performHotspotKeepaliveInHelper(
                targetSSID: targetSSID,
                forceReconnect: effectiveForceReconnect
            )
            await self.finishHotspotKeepalive(
                result,
                showSuccess: showSuccess,
                requiresActiveSession: requiresActiveSession
            )
        }
    }

    private func syncHotspotConnectionConfidence(targetSSID: String?) {
        guard let targetSSID else { return }
        guard wifiStatus().linkActive else {
            lastHotspotConnectionConfirmedAt = nil
            return
        }
        if let currentSSID = currentWiFiNetworkName(allowSlowLookup: false),
           currentSSID != targetSSID {
            lastHotspotConnectionConfirmedAt = nil
        }
    }

    private func shouldForceSavedHotspotReconnect(targetSSID: String?, requiresActiveSession: Bool) -> Bool {
        guard requiresActiveSession,
              let targetSSID else { return false }
        let status = wifiStatus()
        if status.currentSSID == targetSSID {
            lastHotspotConnectionConfirmedAt = Date()
            return false
        }
        if !status.linkActive {
            return true
        }
        return !recentlyConfirmedHotspotConnection(targetSSID: targetSSID)
    }

    private func recentlyConfirmedHotspotConnection(targetSSID: String) -> Bool {
        guard hotspotSSID == targetSSID,
              let lastHotspotConnectionConfirmedAt else { return false }
        guard wifiStatus().linkActive else { return false }
        return Date().timeIntervalSince(lastHotspotConnectionConfirmedAt) < HotspotKeepaliveTiming.confirmationWindow
    }

    private func shouldShowHotspotConnectionProgress(targetSSID: String) -> Bool {
        if recentlyConfirmedHotspotConnection(targetSSID: targetSSID) {
            return false
        }
        return currentWiFiNetworkName(allowSlowLookup: false) != targetSSID
    }

    private func finishHotspotKeepalive(
        _ result: HotspotKeepaliveResult,
        showSuccess: Bool,
        requiresActiveSession: Bool
    ) {
        hotspotKeepaliveInProgress = false
        let keepaliveEnabled = requiresActiveSession ? activeSessionHotspotKeepaliveEnabled : hotspotKeepaliveEnabled
        guard keepaliveEnabled else {
            resetHotspotKeepaliveSchedule()
            return
        }
        if requiresActiveSession {
            guard session != nil,
                  activeMode == .noAjar else {
                resetHotspotKeepaliveSchedule()
                return
            }
        }

        let confirmedConnection = resultConfirmsSavedHotspotConnection(result)
        if confirmedConnection {
            lastHotspotConnectionConfirmedAt = Date()
            hotspotKeepaliveFailureCount = 0
        } else if !result.success {
            lastHotspotConnectionConfirmedAt = nil
            hotspotKeepaliveFailureCount += 1
        } else {
            hotspotKeepaliveFailureCount = 0
        }
        scheduleNextHotspotKeepalive(after: nextHotspotKeepaliveInterval(
            result: result,
            confirmedConnection: confirmedConnection
        ))

        let wasShowingConnectionProgress = hotspotSSID.map { lastMessage == "Connecting to \($0)..." } ?? false
        if showSuccess || !result.success || result.didReconnect || wasShowingConnectionProgress {
            if result.success, let hotspotSSID {
                lastMessage = "Connected to \(hotspotSSID)."
            } else {
                lastMessage = result.message
            }
            rebuildMenu()
        }
    }

    private func resetHotspotKeepaliveSchedule() {
        hotspotKeepaliveTimer?.invalidate()
        hotspotKeepaliveTimer = nil
        hotspotKeepaliveFailureCount = 0
        lastHotspotConnectionConfirmedAt = nil
    }

    private func scheduleNextHotspotKeepalive(after interval: TimeInterval) {
        hotspotKeepaliveTimer?.invalidate()
        hotspotKeepaliveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hotspotKeepaliveTick()
            }
        }
    }

    private func nextHotspotKeepaliveInterval(
        result: HotspotKeepaliveResult,
        confirmedConnection: Bool
    ) -> TimeInterval {
        if confirmedConnection {
            return result.didReconnect ? HotspotKeepaliveTiming.connectedSoon : HotspotKeepaliveTiming.stableConnected
        }
        if result.success {
            return HotspotKeepaliveTiming.aliveButUnconfirmed
        }

        let extraFailures = max(0, hotspotKeepaliveFailureCount - 1)
        let status = wifiStatus()
        if !status.linkActive || hotspotSSID.map({ status.currentSSID != $0 }) == true {
            return min(
                HotspotKeepaliveTiming.disconnectedRetry +
                    Double(extraFailures) * HotspotKeepaliveTiming.disconnectedRetryStep,
                HotspotKeepaliveTiming.disconnectedRetryMax
            )
        }
        return min(
            HotspotKeepaliveTiming.activeFailureRetry +
                Double(extraFailures) * HotspotKeepaliveTiming.activeFailureRetryStep,
            HotspotKeepaliveTiming.activeFailureRetryMax
        )
    }

    private func resultConfirmsSavedHotspotConnection(_ result: HotspotKeepaliveResult) -> Bool {
        guard result.success,
              let hotspotSSID else { return false }
        if result.didReconnect {
            return true
        }
        return currentWiFiNetworkName(allowSlowLookup: false) == hotspotSSID
    }

    private func syncLidBrightness() {
        lidBrightnessController.sync(noAjarActive: session != nil && activeMode == .noAjar)
    }

    private func checkSafety() {
        guard let session else { return }
        if let reason = session.safetyStopReason() {
            let wasManual = sessionSource == .manual
            stopSession()
            lastMessage = "\(reason) Stopped for safety."
            if wasManual {
                showError(lastMessage ?? "Stopped for safety.")
            }
        }
    }

    private func evaluateAutomation() {
        let now = Date()
        if let automationSuppressedUntil, automationSuppressedUntil > now {
            lastAutomationReasons = []
            return
        }
        automationSuppressedUntil = nil

        let decision = automationDecision(at: now)
        lastAutomationReasons = decision?.reasons ?? []

        if session == nil, let decision {
            startSession(
                mode: decision.mode,
                duration: nil,
                source: .automation,
                reason: "Automation: \(decision.reasons.joined(separator: ", "))",
                showErrors: false,
                scheduleWindow: decision.scheduleWindow
            )
            return
        }

        guard sessionSource == .automation else { return }

        guard let decision else {
            stopSession()
            return
        }

        if activeMode != decision.mode {
            stopSession()
            startSession(
                mode: decision.mode,
                duration: nil,
                source: .automation,
                reason: "Automation: \(decision.reasons.joined(separator: ", "))",
                showErrors: false,
                scheduleWindow: decision.scheduleWindow
            )
            return
        }

        activeAutomationScheduleWindow = decision.scheduleWindow
        syncActiveAutomationHotspotKeepalive(decision)
    }

    private func automationDecision(at date: Date = Date()) -> AutomationDecision? {
        var reasons: [String] = []
        var mode: AwakeMode?
        let scheduleWindow = activeScheduleWindow(at: date)

        if let scheduleWindow {
            reasons.append("Schedule")
            mode = scheduleWindow.rule.mode
        }

        if autoWatchedApps, isAnyProcessRunning(matching: watchedApps) {
            reasons.append("App Auto Awake")
            mode = preferredAutomationMode(mode, autoAwakeMode)
        }

        guard let mode else { return nil }
        return AutomationDecision(mode: mode, reasons: reasons, scheduleWindow: scheduleWindow)
    }

    private func preferredAutomationMode(_ lhs: AwakeMode?, _ rhs: AwakeMode) -> AwakeMode {
        if lhs == .noAjar || rhs == .noAjar {
            return .noAjar
        }
        return .awake
    }

    private func syncActiveAutomationHotspotKeepalive(_ decision: AutomationDecision) {
        let effective = effectiveHotspotKeepaliveEnabled(
            mode: decision.mode,
            scheduleWindow: decision.scheduleWindow
        )
        guard activeSessionHotspotKeepaliveEnabled != effective else { return }
        activeSessionHotspotKeepaliveEnabled = effective
        if effective {
            runHotspotKeepalive(showSuccess: false)
        } else {
            resetHotspotKeepaliveSchedule()
        }
    }

    private func activeScheduleWindow(at date: Date = Date()) -> NoAjarScheduleWindow? {
        NoAjarScheduleEvaluator.activeWindow(
            settings: scheduleSettings,
            suppressions: scheduleSuppressions,
            at: date
        )
    }

    private func suppressActiveScheduleIfNeeded() {
        guard sessionSource == .automation,
              let window = activeAutomationScheduleWindow,
              Date() < window.end else {
            return
        }

        scheduleSuppressions.removeAll { $0.ruleID == window.rule.id }
        scheduleSuppressions.append(NoAjarScheduleSuppression(ruleID: window.rule.id, windowEnd: window.end))
        scheduleSuppressions = NoAjarScheduleEvaluator.suppressions(scheduleSuppressions, validAt: Date())
        savePreferences()
    }

    private func pruneScheduleSuppressions() {
        let pruned = NoAjarScheduleEvaluator.suppressions(scheduleSuppressions, validAt: Date())
        guard pruned != scheduleSuppressions else { return }
        scheduleSuppressions = pruned
        savePreferences()
    }

    private func currentAppVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private func appVersionDisplay() -> String {
        let version = currentAppVersion()
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty else {
            return version
        }
        return "\(version) (\(build))"
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "NoAjar"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func promptHotspotSSID(defaultValue: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = "Enter Hotspot Name"
        alert.informativeText = "Enter the iPhone hotspot Wi-Fi name exactly as it appears in macOS. NoAjar will keep this hotspot connected while No Ajar Mode is on."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = defaultValue ?? ""
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let ssid = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if ssid.isEmpty {
            showError("Enter a hotspot Wi-Fi name.")
            return nil
        }
        return ssid
    }

    private func authorizeNoAjarMode() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Authorize No Ajar Mode"
        alert.informativeText = "No Ajar Mode changes macOS lid-sleep settings. Enter your administrator password once while NoAjar is running so No Ajar sessions can start without repeated prompts."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Authorize")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        do {
            try privilegedHelper.authorize(appBundleURL: Bundle.main.bundleURL)
            lastMessage = "No Ajar Mode authorized."
            return true
        } catch {
            lastMessage = "No Ajar Mode authorization failed: \(error.localizedDescription)"
            showError(lastMessage ?? error.localizedDescription)
            return false
        }
    }

}

private let scheduleWeekdays: [(title: String, fullTitle: String, value: Int)] = [
    ("Mon", "Monday", 2),
    ("Tue", "Tuesday", 3),
    ("Wed", "Wednesday", 4),
    ("Thu", "Thursday", 5),
    ("Fri", "Friday", 6),
    ("Sat", "Saturday", 7),
    ("Sun", "Sunday", 1)
]

private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
}()

private let weekdayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE"
    return formatter
}()

private let durationOptions: [(title: String, seconds: TimeInterval?)] = [
    ("Until Stopped", nil),
    ("30 Minutes", 30 * 60),
    ("1 Hour", 60 * 60),
    ("4 Hours", 4 * 60 * 60),
    ("8 Hours", 8 * 60 * 60)
]

private func parseHotKeyShortcut(_ raw: String) -> HotKeyShortcut? {
    let normalized = raw
        .lowercased()
        .replacingOccurrences(of: "command", with: "cmd")
        .replacingOccurrences(of: "⌘", with: "cmd")
        .replacingOccurrences(of: "option", with: "opt")
        .replacingOccurrences(of: "alt", with: "opt")
        .replacingOccurrences(of: "⌥", with: "opt")
        .replacingOccurrences(of: "control", with: "ctrl")
        .replacingOccurrences(of: "⌃", with: "ctrl")
        .replacingOccurrences(of: "shift", with: "shift")
        .replacingOccurrences(of: "⇧", with: "shift")

    let tokens = normalized
        .components(separatedBy: CharacterSet(charactersIn: "+- "))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    var carbonModifiers: UInt32 = 0
    var displayModifiers: [String] = []
    var keyToken: String?

    for token in tokens {
        switch token {
        case "cmd":
            carbonModifiers |= UInt32(cmdKey)
            if !displayModifiers.contains("Cmd") { displayModifiers.append("Cmd") }
        case "opt":
            carbonModifiers |= UInt32(optionKey)
            if !displayModifiers.contains("Opt") { displayModifiers.append("Opt") }
        case "ctrl":
            carbonModifiers |= UInt32(controlKey)
            if !displayModifiers.contains("Ctrl") { displayModifiers.append("Ctrl") }
        case "shift":
            carbonModifiers |= UInt32(shiftKey)
            if !displayModifiers.contains("Shift") { displayModifiers.append("Shift") }
        default:
            keyToken = token
        }
    }

    guard carbonModifiers != 0,
          let keyToken,
          let keyCode = hotKeyCode(for: keyToken) else {
        return nil
    }

    let cleanKey = keyToken.uppercased()
    let storageValue = (displayModifiers + [cleanKey]).joined(separator: "+").lowercased()
    let displayName = (displayModifiers + [cleanKey]).joined(separator: "-")
    return HotKeyShortcut(
        storageValue: storageValue,
        displayName: displayName,
        keyCode: keyCode,
        carbonModifiers: carbonModifiers
    )
}

private func hotKeyShortcut(from event: NSEvent) -> HotKeyShortcut? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var carbonModifiers: UInt32 = 0
    var displayModifiers: [String] = []

    if flags.contains(.command) {
        carbonModifiers |= UInt32(cmdKey)
        displayModifiers.append("Cmd")
    }
    if flags.contains(.option) {
        carbonModifiers |= UInt32(optionKey)
        displayModifiers.append("Opt")
    }
    if flags.contains(.control) {
        carbonModifiers |= UInt32(controlKey)
        displayModifiers.append("Ctrl")
    }
    if flags.contains(.shift) {
        carbonModifiers |= UInt32(shiftKey)
        displayModifiers.append("Shift")
    }

    guard carbonModifiers != 0,
          let keyToken = event.charactersIgnoringModifiers?.lowercased(),
          keyToken.count == 1,
          hotKeyCode(for: keyToken) != nil else {
        return nil
    }

    let cleanKey = keyToken.uppercased()
    let storageValue = (displayModifiers + [cleanKey]).joined(separator: "+").lowercased()
    let displayName = (displayModifiers + [cleanKey]).joined(separator: "-")
    return HotKeyShortcut(
        storageValue: storageValue,
        displayName: displayName,
        keyCode: UInt32(event.keyCode),
        carbonModifiers: carbonModifiers
    )
}

private func hotKeyCode(for key: String) -> UInt32? {
    switch key.lowercased() {
    case "a": UInt32(kVK_ANSI_A)
    case "b": UInt32(kVK_ANSI_B)
    case "c": UInt32(kVK_ANSI_C)
    case "d": UInt32(kVK_ANSI_D)
    case "e": UInt32(kVK_ANSI_E)
    case "f": UInt32(kVK_ANSI_F)
    case "g": UInt32(kVK_ANSI_G)
    case "h": UInt32(kVK_ANSI_H)
    case "i": UInt32(kVK_ANSI_I)
    case "j": UInt32(kVK_ANSI_J)
    case "k": UInt32(kVK_ANSI_K)
    case "l": UInt32(kVK_ANSI_L)
    case "m": UInt32(kVK_ANSI_M)
    case "n": UInt32(kVK_ANSI_N)
    case "o": UInt32(kVK_ANSI_O)
    case "p": UInt32(kVK_ANSI_P)
    case "q": UInt32(kVK_ANSI_Q)
    case "r": UInt32(kVK_ANSI_R)
    case "s": UInt32(kVK_ANSI_S)
    case "t": UInt32(kVK_ANSI_T)
    case "u": UInt32(kVK_ANSI_U)
    case "v": UInt32(kVK_ANSI_V)
    case "w": UInt32(kVK_ANSI_W)
    case "x": UInt32(kVK_ANSI_X)
    case "y": UInt32(kVK_ANSI_Y)
    case "z": UInt32(kVK_ANSI_Z)
    case "0": UInt32(kVK_ANSI_0)
    case "1": UInt32(kVK_ANSI_1)
    case "2": UInt32(kVK_ANSI_2)
    case "3": UInt32(kVK_ANSI_3)
    case "4": UInt32(kVK_ANSI_4)
    case "5": UInt32(kVK_ANSI_5)
    case "6": UInt32(kVK_ANSI_6)
    case "7": UInt32(kVK_ANSI_7)
    case "8": UInt32(kVK_ANSI_8)
    case "9": UInt32(kVK_ANSI_9)
    default: nil
    }
}

private func durationLabel(_ seconds: TimeInterval?) -> String {
    guard let seconds else {
        return "Until Stopped"
    }

    switch Int(seconds) {
    case 30 * 60:
        return "30 Minutes"
    case 60 * 60:
        return "1 Hour"
    case 4 * 60 * 60:
        return "4 Hours"
    case 8 * 60 * 60:
        return "8 Hours"
    default:
        return "\(Int(seconds / 60)) Minutes"
    }
}

private func durationsMatch(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case let (lhs?, rhs?):
        return Int(lhs) == Int(rhs)
    default:
        return false
    }
}

private func dateForMinuteOfDay(_ minute: Int) -> Date {
    let safeMinute = min(max(minute, 0), 24 * 60 - 1)
    var components = DateComponents()
    components.calendar = Calendar.current
    components.year = 2001
    components.month = 1
    components.day = 1
    components.hour = safeMinute / 60
    components.minute = safeMinute % 60
    return components.date ?? Date(timeIntervalSinceReferenceDate: 0)
}

private func minuteOfDay(from date: Date) -> Int {
    let components = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (components.hour ?? 0) * 60 + (components.minute ?? 0)
}

private func fourCharCode(_ value: String) -> OSType {
    var result: OSType = 0
    for byte in value.utf8.prefix(4) {
        result = (result << 8) + OSType(byte)
    }
    return result
}

private func appProcessName(from url: URL) -> String? {
    guard url.pathExtension == "app" else { return nil }

    if let bundle = Bundle(url: url),
       let executableName = bundle.executableURL?.lastPathComponent,
       !executableName.isEmpty {
        return executableName
    }

    let fallback = url.deletingPathExtension().lastPathComponent
    return fallback.isEmpty ? nil : fallback
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
