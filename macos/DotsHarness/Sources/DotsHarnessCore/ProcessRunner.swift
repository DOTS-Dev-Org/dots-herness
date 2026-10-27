// Copyright (c) 2026 DOTS

import Foundation

enum ProcessRunnerFailure {
    case launch(String)
    case timedOut
    case nonzero(status: Int32, stderr: String)
}

enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 60,
        mapFailure: (ProcessRunnerFailure) -> Error
    ) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw mapFailure(.launch(error.localizedDescription))
        }

        var stdoutData = Data()
        var stderrData = Data()
        let stdoutHandle = output.fileHandleForReading
        let stderrHandle = errors.fileHandleForReading
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            stdoutData.append(stdoutHandle.availableData)
            stderrData.append(stderrHandle.availableData)
        }
        if process.isRunning {
            process.terminate()
            throw mapFailure(.timedOut)
        }
        stdoutData.append(stdoutHandle.readDataToEndOfFile())
        stderrData.append(stderrHandle.readDataToEndOfFile())

        guard process.terminationStatus == 0 else {
            let text = String(data: stderrData.prefix(4_000), encoding: .utf8) ?? ""
            throw mapFailure(.nonzero(
                status: process.terminationStatus,
                stderr: text.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return stdoutData
    }
}
