import AppKit
import Carbon
import CoreLocation
import Darwin
import Foundation
import IOKit
import IOKit.hid
import LidAwakeCore
import Security
import UniformTypeIdentifiers

private enum SessionSource {
    case manual
    case automation
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

private final class ModeDurationChoice: NSObject {
    let mode: AwakeMode
    let duration: TimeInterval?

    init(mode: AwakeMode, duration: TimeInterval?) {
        self.mode = mode
        self.duration = duration
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, CLLocationManagerDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let launchAgent = LaunchAgent(label: "dev.local.noajar")
    private let locationManager = CLLocationManager()
    private let privilegedHelper = PrivilegedNoAjarHelperClient()
    private let lidBrightnessController = LidBrightnessController()

    private var session: LidAwakeSession?
    private var sessionSource: SessionSource?
    private var activeMode: AwakeMode?
    private var sessionEndsAt: Date?
    private var monitorTimer: Timer?
    private var lidBrightnessTimer: Timer?
    private var hotKeyController: HotKeyController?
    private var isRecordingHotKey = false

    private var minBatteryPercent = 30
    private var batteryStopEnabled = true
    private var wifiGuardEnabled = false
    private var pinnedWiFi = ""
    private var blockedWiFi: [String] = []
    private var autoWatchedApps = false
    private var autoAwakeMode = AwakeMode.awake
    private var hotKeyEnabled = true
    private var hotKeyShortcut = HotKeyShortcut.defaultShortcut
    private var watchedApps = ["remodex", "opencode", "openclaw", "claude", "codex"]
    private var lastAutomationReasons: [String] = []
    private var lastMessage: String?
    private var automationSuppressedUntil: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "NoAjar"
        locationManager.delegate = self
        repairStaleStateIfNeeded()
        loadPreferences()
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
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitorTimer?.invalidate()
        lidBrightnessTimer?.invalidate()
        stopSession()
        lidBrightnessController.restoreIfNeeded()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.clearResolvedWiFiPermissionMessage()
            self.rebuildMenu()
        }
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        wifiGuardEnabled = defaults.bool(forKey: "wifiGuardEnabled")
        pinnedWiFi = defaults.string(forKey: "pinnedWiFi") ?? ""
        blockedWiFi = defaults.stringArray(forKey: "blockedWiFi") ?? []
        autoWatchedApps = defaults.bool(forKey: "autoWatchedApps")
        hotKeyEnabled = defaults.object(forKey: "hotKeyEnabled") as? Bool ?? true
        if let storedShortcut = defaults.string(forKey: "hotKeyShortcut"),
           let shortcut = parseHotKeyShortcut(storedShortcut) {
            hotKeyShortcut = shortcut
        }
        minBatteryPercent = defaults.object(forKey: "minBatteryPercent") as? Int ?? 30
        batteryStopEnabled = defaults.object(forKey: "batteryGuardEnabled") as? Bool ?? true

        if let rawMode = defaults.string(forKey: "autoAwakeMode"),
           let mode = AwakeMode(rawValue: rawMode) {
            autoAwakeMode = mode
        }
        if let storedApps = defaults.stringArray(forKey: "watchedApps"), !storedApps.isEmpty {
            watchedApps = storedApps
        }
    }

    private func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "allowBattery")
        defaults.set(batteryStopEnabled, forKey: "batteryGuardEnabled")
        defaults.set(false, forKey: "preventDisplaySleep")
        defaults.set(wifiGuardEnabled, forKey: "wifiGuardEnabled")
        defaults.set(pinnedWiFi, forKey: "pinnedWiFi")
        defaults.set(blockedWiFi, forKey: "blockedWiFi")
        defaults.set(autoWatchedApps, forKey: "autoWatchedApps")
        defaults.set(false, forKey: "powerProtectEnabled")
        defaults.set(hotKeyEnabled, forKey: "hotKeyEnabled")
        defaults.set(hotKeyShortcut.storageValue, forKey: "hotKeyShortcut")
        defaults.set(minBatteryPercent, forKey: "minBatteryPercent")
        defaults.set(autoAwakeMode.rawValue, forKey: "autoAwakeMode")
        defaults.set(watchedApps, forKey: "watchedApps")
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let active = session != nil
        statusItem.button?.title = menuBarStatusTitle()
        clearResolvedWiFiPermissionMessage()

        menu.addItem(statusHeaderMenuItem())
        menu.addItem(.separator())
        menu.addItem(modeMenuItem(.awake))
        menu.addItem(modeMenuItem(.noAjar))
        addItem("Turn Off", #selector(turnOffClicked), keyEquivalent: "0", keyEquivalentModifierMask: [], enabled: active)

        menu.addItem(.separator())
        menu.addItem(wifiMenuItem())
        menu.addItem(appsMenuItem())
        menu.addItem(preferencesMenuItem())

        menu.addItem(.separator())
        addItem("Quit", #selector(quitClicked), keyEquivalent: "q", keyEquivalentModifierMask: [.command])

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
        rows.append(("Wi-Fi: \(wifiStatusLabel())", .systemFont(ofSize: 13, weight: .regular), .labelColor))
        return rows
    }

    private func clearResolvedWiFiPermissionMessage() {
        guard let lastMessage, isWiFiPermissionMessage(lastMessage) else { return }

        let authorizationStatus = locationManager.authorizationStatus
        let isAuthorized = authorizationStatus == .authorizedAlways || authorizationStatus == .authorized
        if isAuthorized || wifiStatus().currentSSID != nil {
            self.lastMessage = nil
        }
    }

    private func isWiFiPermissionMessage(_ message: String) -> Bool {
        message.contains("Location access") || message.contains("Wi-Fi name access")
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

    private func modeMenuItem(_ mode: AwakeMode) -> NSMenuItem {
        let parent = NSMenuItem(
            title: mode.displayName,
            action: nil,
            keyEquivalent: ""
        )
        parent.state = activeMode == mode ? .on : .off
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (index, option) in durationOptions.enumerated() {
            let item = NSMenuItem(
                title: "Start \(option.title)",
                action: #selector(startModeDuration(_:)),
                keyEquivalent: "\(index + 1)"
            )
            item.target = self
            item.representedObject = ModeDurationChoice(mode: mode, duration: option.seconds)
            item.isEnabled = activeMode != mode
            item.keyEquivalentModifierMask = mode == .awake ? [] : [.option]
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(batteryThresholdMenuItem())
        parent.submenu = submenu
        return parent
    }

    private func wifiMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Wi-Fi", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        submenu.addItem(toggleItem("Wi-Fi Guard", #selector(toggleWiFiGuard), state: wifiGuardEnabled))
        if let accessItem = wifiNameAccessMenuItem() {
            submenu.addItem(accessItem)
        }
        submenu.addItem(actionItem("Pin Current Wi-Fi", #selector(pinCurrentWiFi)))
        submenu.addItem(actionItem("Input Pinned Network...", #selector(editPinnedWiFi)))
        submenu.addItem(disabledItem("Pinned: \(pinnedWiFi.isEmpty ? "None" : pinnedWiFi)"))
        submenu.addItem(actionItem("Block Current Wi-Fi", #selector(blockCurrentWiFi)))
        submenu.addItem(actionItem("Input Blocked Networks...", #selector(editBlockedWiFi)))
        submenu.addItem(disabledItem("Blocked: \(blockedWiFi.isEmpty ? "None" : blockedWiFi.joined(separator: ", "))"))

        parent.submenu = submenu
        return parent
    }

    private func wifiNameAccessMenuItem() -> NSMenuItem? {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorized:
            return nil
        case .notDetermined:
            return actionItem("Allow Wi-Fi Name Access", #selector(requestWiFiNameAccess))
        case .denied, .restricted:
            return actionItem("Open Wi-Fi Name Access Settings", #selector(requestWiFiNameAccess))
        @unknown default:
            return actionItem("Allow Wi-Fi Name Access", #selector(requestWiFiNameAccess))
        }
    }

    private func appsMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Apps", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        submenu.addItem(toggleItem("App Auto Awake", #selector(toggleAutoWatchedApps), state: autoWatchedApps))
        submenu.addItem(actionItem("Add Apps...", #selector(editWatchedApps)))
        submenu.addItem(actionItem("Clear Apps", #selector(clearWatchedApps), enabled: !watchedApps.isEmpty))
        submenu.addItem(appAutoModeMenuItem())
        submenu.addItem(disabledItem("Apps: \(watchedApps.joined(separator: ", "))"))

        parent.submenu = submenu
        return parent
    }

    private func preferencesMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        submenu.addItem(hotkeyMenuItem())
        submenu.addItem(toggleItem("Launch at Login", #selector(toggleLaunchAtLogin), state: launchAgent.isEnabled))

        parent.submenu = submenu
        return parent
    }

    private func hotkeyMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Hotkey: \(hotKeyShortcut.displayName)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        submenu.addItem(toggleItem("Enabled", #selector(toggleHotKey), state: hotKeyEnabled))
        submenu.addItem(actionItem("Set Hotkey...", #selector(setHotKeyShortcut)))

        parent.submenu = submenu
        return parent
    }

    private func batteryThresholdMenuItem() -> NSMenuItem {
        let title = batteryStopEnabled ? "Stop Below \(minBatteryPercent)%" : "Stop Below: Keep Running"
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
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

    @objc private func startModeDuration(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ModeDurationChoice else {
            return
        }
        startManualSession(mode: choice.mode, duration: choice.duration)
    }

    @objc private func turnOffClicked() {
        stopSession()
        rebuildMenu()
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

    @objc private func toggleWiFiGuard() {
        if !wifiGuardEnabled {
            let status = wifiStatus()
            if status.linkActive, status.currentSSID == nil {
                requestLocationPermissionForWiFiName()
            }
        }
        wifiGuardEnabled.toggle()
        savePreferences()
        checkWiFiGuard()
        rebuildMenu()
    }

    @objc private func pinCurrentWiFi() {
        let status = wifiStatus()
        guard let ssid = status.currentSSID else {
            showWiFiNameUnavailableMessage(status: status)
            return
        }

        pinnedWiFi = ssid
        savePreferences()
        lastMessage = "Pinned Wi-Fi: \(ssid)"
        rebuildMenu()
    }

    @objc private func editPinnedWiFi() {
        let value = promptText(
            title: "Pinned Wi-Fi",
            message: "Enter the Wi-Fi name NoAjar should return to during an active session.",
            value: pinnedWiFi
        )
        guard let value else { return }
        pinnedWiFi = value.trimmingCharacters(in: .whitespacesAndNewlines)
        savePreferences()
        rebuildMenu()
    }

    @objc private func blockCurrentWiFi() {
        let status = wifiStatus()
        guard let ssid = status.currentSSID else {
            showWiFiNameUnavailableMessage(status: status)
            return
        }

        if !blockedWiFi.contains(ssid) {
            blockedWiFi.append(ssid)
            blockedWiFi.sort()
        }
        savePreferences()
        checkWiFiGuard(force: true)
        rebuildMenu()
    }

    @objc private func requestWiFiNameAccess() {
        requestLocationPermissionForWiFiName()
        rebuildMenu()
    }

    @objc private func editBlockedWiFi() {
        let value = promptText(
            title: "Blocked Wi-Fi",
            message: "Enter Wi-Fi names to avoid, separated by commas.",
            value: blockedWiFi.joined(separator: ", ")
        )
        guard let value else { return }
        blockedWiFi = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        savePreferences()
        checkWiFiGuard(force: true)
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

    private func toggleFromHotKey() {
        guard !isRecordingHotKey else { return }

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
        if session != nil {
            stopSession()
        }
        startSession(mode: mode, duration: duration, source: .manual, reason: mode.displayName, showErrors: true)
    }

    private func startSession(
        mode: AwakeMode,
        duration: TimeInterval?,
        source: SessionSource,
        reason: String,
        showErrors: Bool
    ) {
        guard session == nil else { return }
        if source == .automation, mode == .noAjar, !privilegedHelper.isAuthorized {
            lastMessage = "No Ajar Mode needs admin authorization."
            return
        }

        do {
            let usesNoAjarHelper = mode == .noAjar && privilegedHelper.isAuthorized
            let options = LidAwakeOptions(
                mode: mode,
                allowBattery: true,
                batteryGuardEnabled: batteryStopEnabled,
                minBatteryPercent: minBatteryPercent,
                durationSeconds: duration,
                preventDisplaySleep: false,
                manageLidSleepOverride: !usesNoAjarHelper,
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
            sessionEndsAt = duration.map { Date().addingTimeInterval($0) }
            lastMessage = nil
            syncLidBrightness()
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
        if shouldRestoreBrightness {
            lidBrightnessController.restoreIfNeeded()
        }
    }

    private func monitorTick() {
        syncLidBrightness()
        checkSafety()
        checkWiFiGuard()
        evaluateAutomation()
        rebuildMenu()
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
        if let automationSuppressedUntil, automationSuppressedUntil > Date() {
            lastAutomationReasons = []
            return
        }
        automationSuppressedUntil = nil

        let reasons = automationReasons()
        lastAutomationReasons = reasons

        if session == nil, !reasons.isEmpty {
            startSession(
                mode: autoAwakeMode,
                duration: nil,
                source: .automation,
                reason: "Automation: \(reasons.joined(separator: ", "))",
                showErrors: false
            )
            return
        }

        if sessionSource == .automation, reasons.isEmpty {
            stopSession()
        }
    }

    private func automationReasons() -> [String] {
        guard autoWatchedApps, isAnyProcessRunning(matching: watchedApps) else {
            return []
        }
        return ["App Auto Awake"]
    }

    private func checkWiFiGuard(force: Bool = false) {
        guard wifiGuardEnabled, session != nil || force else { return }

        let cleanPinnedWiFi = pinnedWiFi.trimmingCharacters(in: .whitespacesAndNewlines)
        let blocked = Set(blockedWiFi.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })

        if !cleanPinnedWiFi.isEmpty, blocked.contains(cleanPinnedWiFi) {
            lastMessage = "Wi-Fi Guard paused: pinned Wi-Fi is also blocked."
            return
        }

        let status = wifiStatus()
        guard status.interface != nil else {
            lastMessage = "Wi-Fi Guard: no Wi-Fi interface found."
            return
        }
        if status.currentSSID == nil, status.linkActive {
            lastMessage = "Wi-Fi Guard needs Location access to read this network name."
            return
        }

        for ssid in blocked {
            do {
                try removePreferredWiFi(ssid: ssid)
            } catch {
                lastMessage = "Wi-Fi Guard: \(error.localizedDescription)"
                return
            }
        }

        if let currentSSID = status.currentSSID, blocked.contains(currentSSID) {
            do {
                if !cleanPinnedWiFi.isEmpty {
                    try connectWiFi(ssid: cleanPinnedWiFi)
                    lastMessage = "Wi-Fi Guard moved from \(currentSSID) to \(cleanPinnedWiFi)."
                } else {
                    try disconnectCurrentWiFi()
                    lastMessage = "Wi-Fi Guard disconnected blocked Wi-Fi: \(currentSSID)."
                }
            } catch {
                lastMessage = "Wi-Fi Guard: \(error.localizedDescription)"
            }
            return
        }

        guard !cleanPinnedWiFi.isEmpty, status.currentSSID != cleanPinnedWiFi else { return }

        do {
            try connectWiFi(ssid: cleanPinnedWiFi)
            lastMessage = "Wi-Fi Guard reconnected to \(cleanPinnedWiFi)."
        } catch {
            lastMessage = "Wi-Fi Guard: \(error.localizedDescription)"
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "NoAjar"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showWiFiNameUnavailableMessage(status: WiFiStatus) {
        if status.linkActive {
            requestLocationPermissionForWiFiName()
            showError("macOS is hiding the current Wi-Fi name. Allow Location access for NoAjar, then try again.")
        } else {
            showError("No Wi-Fi network is currently connected.")
        }
    }

    private func requestLocationPermissionForWiFiName() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            lastMessage = "Allow Location access, then try Pin Current Wi-Fi again."
        case .authorizedAlways, .authorized:
            lastMessage = nil
        case .denied, .restricted:
            openPermissionAlert(
                title: "Location Access Needed",
                message: "NoAjar needs Location permission to read Wi-Fi names. This is required by macOS for Wi-Fi Guard."
            )
        @unknown default:
            locationManager.requestWhenInUseAuthorization()
        }
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

    private func openPermissionAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openPrivacySettings()
        }
    }

    private func openPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices"
        ]
        for rawURL in urls {
            guard let url = URL(string: rawURL), NSWorkspace.shared.open(url) else { continue }
            return
        }
    }

    private func wifiStatusLabel() -> String {
        let status = wifiStatus()
        if let ssid = status.currentSSID {
            return ssid
        }
        if status.linkActive {
            return "Name unavailable"
        }
        return "Not connected"
    }

    private func promptText(title: String, message: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        textField.stringValue = value
        alert.accessoryView = textField

        return alert.runModal() == .alertFirstButtonReturn ? textField.stringValue : nil
    }
}

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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
