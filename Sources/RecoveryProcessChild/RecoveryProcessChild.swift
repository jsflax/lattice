import Foundation
import RecoveryProcessSupport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Dedicated child, never a respawned test runner. Control data is never stdout.
@main struct RecoveryProcessChild {
    @MainActor static func main() async {
        var receiver: RecoveryProcessReceiver?, channel: RecoveryProcessChildChannel?
        var success = false
        do {
            let arguments = CommandLine.arguments, environment = ProcessInfo.processInfo.environment
            guard arguments.count == 2, environment["LATTICE_RECEIVER_KILL_RECOVERY_GATE"] == "1",
                  let root = environment["LATTICE_CONNECTED_RECOVERY_RUN_DIR"],
                  arguments[1].hasPrefix(root + "/private/"),
                  let nativeLog = environment["LATTICE_TEST_LOG_PATH"], nativeLog.hasPrefix(arguments[1] + "/child-"),
                  nativeLog.hasSuffix("-native.log") else { throw RecoveryProcessFailure.configuration }
            let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
            let fd = try RecoveryProcessPOSIX.directory(directory, privateCase: true)
            let bytes: Data
            do { bytes = try RecoveryProcessPOSIX.readConfiguration(directory: fd) }
            catch { _ = close(fd); throw error }
            guard close(fd) == 0 else { throw RecoveryProcessFailure.io }
            let configuration = try RecoveryProcessCodec.decode(RecoveryProcessConfiguration.self, from: bytes)
            try configuration.validate(); try configuration.validateDeadline(now: RecoveryProcessPOSIX.now())
            let control = try RecoveryProcessChildChannel(fd: 3, deadline: configuration.deadlineNanoseconds); channel = control
            let owner = try RecoveryProcessReceiver(configuration: configuration, caseDirectory: directory); receiver = owner
            let hello = RecoveryProcessHello(nonce: configuration.nonce, configurationSHA256: try RecoveryProcessSHA256.hash(bytes), processID: getpid())
            try await control.sendMessage(RecoveryProcessCodec.encode(hello))
            var state = RecoveryProcessCommandState()
            while true {
                let message = try await control.readMessage()
                let command = try RecoveryProcessCodec.decode(RecoveryProcessCommand.self, from: message)
                do {
                    try state.accept(command, nonce: configuration.nonce)
                    let reply = try await owner.execute(command); try reply.validate(for: command)
                    try await control.sendMessage(RecoveryProcessCodec.encode(reply))
                    if command.operation == .close { success = true; break }
                } catch {
                    // No arbitrary exception/configuration content crosses the control boundary.
                    let failure = (error as? RecoveryProcessFailure) ?? .publicState
                    try? await control.sendMessage(RecoveryProcessCodec.encode(RecoveryProcessReply(command: command, failure: failure)))
                    throw failure
                }
            }
        } catch { success = false }
        if let receiver { do { try receiver.close() } catch { success = false } }
        if let channel { if !(await channel.finish()) { success = false } }
        exit(success ? 0 : 1)
    }
}
