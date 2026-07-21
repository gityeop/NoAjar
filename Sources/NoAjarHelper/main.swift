import Foundation
import LidAwakeCore
import Security

private struct HelperState: Codable {
    let previousDisableSleep: Int
    let enabledAt: Date
}

private final class HelperService: NSObject, NoAjarHelperProtocol {
    func enableNoAjar(withReply reply: @escaping (Bool, NSString?) -> Void) {
        do {
            let existingState = try loadState()
            let createdState = existingState == nil
            let state: HelperState
            if let existingState {
                state = existingState
            } else {
                let previous = try readSleepDisabled()
                state = HelperState(previousDisableSleep: previous, enabledAt: Date())
                try saveState(state)
            }
            do {
                try setDisableSleep(1)
            } catch let enableError {
                if createdState {
                    do {
                        try setDisableSleep(state.previousDisableSleep)
                        try removeState()
                    } catch let restoreError {
                        throw HelperError("\(enableError.localizedDescription)\nFailed to restore SleepDisabled: \(restoreError.localizedDescription)")
                    }
                }
                throw enableError
            }
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription as NSString)
        }
    }

    func disableNoAjar(withReply reply: @escaping (Bool, NSString?) -> Void) {
        do {
            guard let state = try loadState() else {
                throw HelperError("No saved NoAjar helper state was found; refusing to change SleepDisabled.")
            }
            try setDisableSleep(state.previousDisableSleep)
            try removeState()
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription as NSString)
        }
    }

    func status(withReply reply: @escaping (Bool, NSString?) -> Void) {
        do {
            reply(try readSleepDisabled() == 1, nil)
        } catch {
            reply(false, error.localizedDescription as NSString)
        }
    }

    func statusV2(withReply reply: @escaping (Bool, Bool, NSString?) -> Void) {
        do {
            let isManaged = try loadState() != nil
            let isSleepDisabled = try readSleepDisabled() == 1
            reply(isManaged, isSleepDisabled, nil)
        } catch {
            reply(false, false, error.localizedDescription as NSString)
        }
    }
}

private final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard validateClient(pid: connection.processIdentifier) else {
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: NoAjarHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private func validateClient(pid: pid_t) -> Bool {
    guard let requirementText = try? String(contentsOf: noAjarHelperClientRequirementURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !requirementText.isEmpty else {
        return false
    }

    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
          let requirement else {
        return false
    }

    let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
          let code else {
        return false
    }

    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
}

private func setDisableSleep(_ value: Int) throws {
    guard value == 0 || value == 1 else {
        throw HelperError("Invalid disablesleep value.")
    }
    let result = try run("/usr/bin/pmset", ["-a", "disablesleep", "\(value)"])
    guard result.status == 0 else {
        throw HelperError(result.errorOrOutput(defaultMessage: "pmset failed."))
    }
    guard try readSleepDisabled() == value else {
        throw HelperError("SleepDisabled did not change to \(value).")
    }
}

private func saveState(_ state: HelperState) throws {
    let data = try JSONEncoder().encode(state)
    try data.write(to: noAjarHelperStateURL, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: noAjarHelperStateURL.path)
}

private func loadState() throws -> HelperState? {
    guard FileManager.default.fileExists(atPath: noAjarHelperStateURL.path) else { return nil }
    let data = try Data(contentsOf: noAjarHelperStateURL)
    return try JSONDecoder().decode(HelperState.self, from: data)
}

private func removeState() throws {
    try FileManager.default.removeItem(at: noAjarHelperStateURL)
}

private struct CommandResult {
    let status: Int32
    let output: String
    let error: String

    func errorOrOutput(defaultMessage: String) -> String {
        let cleanError = error.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanError.isEmpty { return cleanError }
        let cleanOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanOutput.isEmpty ? defaultMessage : cleanOutput
    }
}

@discardableResult
private func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice

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

private struct HelperError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private let delegate = HelperDelegate()
private let listener = NSXPCListener(machServiceName: noAjarHelperLabel)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
