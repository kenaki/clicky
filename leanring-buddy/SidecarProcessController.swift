//
//  SidecarProcessController.swift
//  leanring-buddy
//
//  Starts and stops the agent sidecar Node process. Two modes:
//
//  - Attach: if something already answers the sidecar hello on the port (you
//    ran `npm run serve` in a terminal to watch its logs), use that and never
//    stop it; it is yours.
//  - Spawn: otherwise run the sidecar from source with Node + tsx, exactly
//    what `npm run serve` does, so there is no build step. The app passes its
//    own pid so the sidecar exits within ~2 s if the app dies, and a random
//    per-launch token so no other local process can drive the agent.
//
//  Configuration (Info.plist, all optional):
//  - AgentSidecarDirectory: absolute path of agent-sidecar/. Default: the
//    agent-sidecar folder next to this source file's folder, which is right
//    whenever the app is built from this checkout in Xcode.
//  - AgentSidecarNodePath: absolute path of `node`. Default: Homebrew's, then /usr/local.
//  The project the agent works in comes from the sidecar's own .env
//  (CLICKY_PROJECT_DIRECTORY), not from the app.
//

import Foundation

@MainActor
final class SidecarProcessController {
    enum LaunchError: LocalizedError {
        case sidecarDirectoryMissing(path: String)
        case dependenciesNotInstalled(sidecarDirectoryPath: String)
        case nodeNotFound
        case exitedBeforeListening(exitCode: Int32, lastStderrLines: String)
        case listeningLineTimedOut

        var errorDescription: String? {
            switch self {
            case .sidecarDirectoryMissing(let path):
                return "No agent-sidecar folder at \(path). Set AgentSidecarDirectory in Info.plist."
            case .dependenciesNotInstalled(let sidecarDirectoryPath):
                return "Run `npm install` in \(sidecarDirectoryPath) first."
            case .nodeNotFound:
                return "Node was not found. Install it with Homebrew or set AgentSidecarNodePath in Info.plist."
            case .exitedBeforeListening(let exitCode, let lastStderrLines):
                return "The sidecar exited with code \(exitCode) before it was ready. \(lastStderrLines)"
            case .listeningLineTimedOut:
                return "The sidecar did not print its listening line in time."
            }
        }
    }

    enum ConnectionMode: String {
        case attached
        case spawned
    }

    /// Where the sidecar is listening and how the app should say hello to it.
    struct RunningSidecar {
        let port: Int
        let sharedToken: String?
        let connectionMode: ConnectionMode
    }

    private var sidecarProcess: Process?
    /// Last few stderr lines, so a startup failure can say why.
    private var recentStderrLines: [String] = []
    /// stdout carries exactly one line we care about. The continuation is
    /// resumed by whichever comes first: that line, process exit, or timeout.
    private var standardOutputBuffer = ""
    private var listeningPortContinuation: CheckedContinuation<Int, Error>?

    private static let listeningLinePrefix = "listening on ws://127.0.0.1:"
    private static let listeningLineTimeoutSeconds: Double = 20

    // MARK: - Configuration

    static var sidecarDirectoryURL: URL {
        if let configuredPath = AppBundleConfiguration.stringValue(forKey: "AgentSidecarDirectory") {
            return URL(fileURLWithPath: configuredPath, isDirectory: true)
        }
        // #filePath is this file's absolute path at compile time:
        // <repo>/leanring-buddy/SidecarProcessController.swift → <repo>/agent-sidecar
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agent-sidecar", isDirectory: true)
    }

    private static func resolveNodeExecutableURL() -> URL? {
        let candidatePaths = [
            AppBundleConfiguration.stringValue(forKey: "AgentSidecarNodePath"),
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node"
        ].compactMap { $0 }
        return candidatePaths
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Spawn

    /// Starts the sidecar and returns once it prints its listening line.
    func spawnSidecar(port: Int) async throws -> RunningSidecar {
        stopSpawnedSidecar()

        let sidecarDirectoryURL = Self.sidecarDirectoryURL
        let serveEntryPointURL = sidecarDirectoryURL.appendingPathComponent("src/cli/serve.ts")
        let tsxLoaderURL = sidecarDirectoryURL.appendingPathComponent("node_modules/tsx/dist/loader.mjs")

        guard FileManager.default.fileExists(atPath: serveEntryPointURL.path) else {
            throw LaunchError.sidecarDirectoryMissing(path: sidecarDirectoryURL.path)
        }
        guard FileManager.default.fileExists(atPath: tsxLoaderURL.path) else {
            throw LaunchError.dependenciesNotInstalled(sidecarDirectoryPath: sidecarDirectoryURL.path)
        }
        guard let nodeExecutableURL = Self.resolveNodeExecutableURL() else {
            throw LaunchError.nodeNotFound
        }

        let perLaunchSharedToken = UUID().uuidString

        // An app launched from Xcode or Finder gets a minimal PATH; put Node's
        // folder first in case the Agent SDK looks for `node` itself.
        var childEnvironment = ProcessInfo.processInfo.environment
        let nodeDirectoryPath = nodeExecutableURL.deletingLastPathComponent().path
        childEnvironment["PATH"] = "\(nodeDirectoryPath):\(childEnvironment["PATH"] ?? "/usr/bin:/bin")"
        // Values already in the environment win over agent-sidecar/.env.
        childEnvironment["CLICKY_SIDECAR_TOKEN"] = perLaunchSharedToken

        let process = Process()
        process.executableURL = nodeExecutableURL
        process.arguments = [
            "--import", tsxLoaderURL.absoluteString,
            serveEntryPointURL.path,
            "--port", String(port),
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)
        ]
        process.currentDirectoryURL = sidecarDirectoryURL
        process.environment = childEnvironment

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let chunk = String(decoding: fileHandle.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.handleStandardOutputChunk(chunk)
            }
        }

        standardErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let chunk = String(decoding: fileHandle.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in
                for line in chunk.split(separator: "\n") {
                    print("🧩 [sidecar] \(line)")
                    self?.recentStderrLines.append(String(line))
                }
                if let self, self.recentStderrLines.count > 8 {
                    self.recentStderrLines.removeFirst(self.recentStderrLines.count - 8)
                }
            }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            let exitCode = terminatedProcess.terminationStatus
            Task { @MainActor [weak self] in
                print("🧩 Sidecar process exited with code \(exitCode)")
                guard let self else { return }
                let lastStderrLines = self.recentStderrLines.suffix(3).joined(separator: " ")
                self.finishWaitingForListeningLine(with: .failure(LaunchError.exitedBeforeListening(exitCode: exitCode, lastStderrLines: lastStderrLines)))
                if self.sidecarProcess === terminatedProcess {
                    self.sidecarProcess = nil
                }
            }
        }

        recentStderrLines = []
        standardOutputBuffer = ""
        try process.run()
        sidecarProcess = process
        print("🧩 Spawned sidecar pid \(process.processIdentifier) from \(sidecarDirectoryURL.path)")

        let listeningPort = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            listeningPortContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.listeningLineTimeoutSeconds * 1_000_000_000))
                self?.finishWaitingForListeningLine(with: .failure(LaunchError.listeningLineTimedOut))
            }
        }

        return RunningSidecar(port: listeningPort, sharedToken: perLaunchSharedToken, connectionMode: .spawned)
    }

    private func handleStandardOutputChunk(_ chunk: String) {
        standardOutputBuffer += chunk
        guard let listeningLine = standardOutputBuffer
                .split(separator: "\n")
                .first(where: { $0.hasPrefix(Self.listeningLinePrefix) }),
              let listeningPort = Int(listeningLine.dropFirst(Self.listeningLinePrefix.count).trimmingCharacters(in: .whitespaces)) else {
            return
        }
        finishWaitingForListeningLine(with: .success(listeningPort))
    }

    private func finishWaitingForListeningLine(with result: Result<Int, Error>) {
        guard let continuation = listeningPortContinuation else { return }
        listeningPortContinuation = nil
        continuation.resume(with: result)
    }

    /// Stops a sidecar this app started. An attached sidecar is left alone.
    func stopSpawnedSidecar() {
        guard let sidecarProcess else { return }
        self.sidecarProcess = nil
        if sidecarProcess.isRunning {
            // SIGTERM runs the sidecar's graceful shutdown, which closes the agent session.
            sidecarProcess.terminate()
        }
    }
}
