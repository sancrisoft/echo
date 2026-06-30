//
//  LlamaServerManager.swift
//  Echo
//
//  Starts and monitors a local llama.cpp server for post-recording summaries.
//

import Foundation
import os

struct LlamaServerConfig: Sendable {
    nonisolated static let alias = "echo-gemma-summary"
    static let modelPathKey = "GemmaGGUFModelPath"
    static let executablePathKey = "LlamaServerExecutablePath"

    var executableURL: URL
    var modelURL: URL
    var host: String
    var port: Int
    var contextSize: Int
    var gpuLayers: Int
    var startupTimeout: TimeInterval

    nonisolated init(
        executableURL: URL,
        modelURL: URL,
        host: String = "127.0.0.1",
        port: Int = 8080,
        contextSize: Int = 32768,
        gpuLayers: Int = 99,
        startupTimeout: TimeInterval = 180
    ) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.host = host
        self.port = port
        self.contextSize = contextSize
        self.gpuLayers = gpuLayers
        self.startupTimeout = startupTimeout
    }

    nonisolated var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    nonisolated var healthURL: URL {
        baseURL.appending(path: "health")
    }

    nonisolated var arguments: [String] {
        [
            "-m", modelURL.path,
            "--alias", Self.alias,
            "--host", host,
            "--port", "\(port)",
            "-c", "\(contextSize)",
            "-ngl", "\(gpuLayers)",
        ]
    }

    @MainActor
    static var storedModelPath: String? {
        UserDefaults.standard.string(forKey: modelPathKey)
    }

    @MainActor
    static func storeModelURL(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: modelPathKey)
    }

    @MainActor
    static func resolved() throws -> LlamaServerConfig {
        guard let executableURL = resolvedExecutableURL() else {
            throw LlamaServerError.missingExecutable
        }
        guard let modelURL = try resolvedModelURL() else {
            throw LlamaServerError.missingModel(nil)
        }

        return LlamaServerConfig(executableURL: executableURL, modelURL: modelURL)
    }

    @MainActor
    private static func resolvedExecutableURL() -> URL? {
        if let path = UserDefaults.standard.string(forKey: executablePathKey),
           FileManager.default.isExecutableFile(atPath: expanded(path)) {
            return URL(fileURLWithPath: expanded(path))
        }

        let bundleCandidates = [
            Bundle.main.url(forAuxiliaryExecutable: "llama-server"),
            Bundle.main.url(forResource: "llama-server", withExtension: nil),
        ].compactMap { $0 }

        if let bundled = bundleCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return bundled
        }

        let pathCandidates = [
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server",
            "/usr/bin/llama-server",
        ]

        return pathCandidates
            .map(expanded)
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    @MainActor
    private static func resolvedModelURL() throws -> URL? {
        var missingStoredPath: String?
        if let stored = storedModelPath {
            let path = expanded(stored)
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            missingStoredPath = path
        }

        var pathCandidates = [
            "~/Models/gemma-4-12b-unified-it-qat-q4_0.gguf",
            "~/Models/gemma-4-12b-unified-it-Q4_0.gguf",
            "~/Models/gemma-4-12b-it-qat-q4_0.gguf",
            "~/Models/gemma-3-12b-it-qat-q4_0.gguf",
        ]

#if DEBUG
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        pathCandidates.insert(
            projectRoot
                .appending(path: ".local-models")
                .appending(path: "gemma-4")
                .appending(path: "gemma-4-12b-it-qat-q4_0")
                .appending(path: "gemma-4-12b-it-qat-q4_0.gguf")
                .path,
            at: 0
        )
#endif

        let discoveredURL = pathCandidates
            .map(expanded)
            .first(where: FileManager.default.fileExists(atPath:))
            .map { URL(fileURLWithPath: $0) }

        if let discoveredURL {
            return discoveredURL
        }

        if let missingStoredPath {
            throw LlamaServerError.missingModel(missingStoredPath)
        }

        return nil
    }

    nonisolated private static func expanded(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

actor LlamaServerManager {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "LlamaServerManager")

    private var process: Process?

    func ensureRunning(config: LlamaServerConfig) async throws {
        if await isHealthy(config: config) { return }

        if let process, process.isRunning {
            process.terminate()
            self.process = nil
        }

        try start(config: config)
        try await waitUntilHealthy(config: config)
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private func start(config: LlamaServerConfig) throws {
        let process = Process()
        process.executableURL = config.executableURL
        process.arguments = config.arguments
        process.currentDirectoryURL = config.modelURL.deletingLastPathComponent()
        process.qualityOfService = .userInitiated

        do {
            try process.run()
            self.process = process
            Self.log.info("Started llama-server with model \(config.modelURL.lastPathComponent, privacy: .public)")
        } catch {
            throw LlamaServerError.startFailed(error.localizedDescription)
        }
    }

    private func waitUntilHealthy(config: LlamaServerConfig) async throws {
        let deadline = Date().addingTimeInterval(config.startupTimeout)

        while Date() < deadline {
            if await isHealthy(config: config) { return }
            if let process, !process.isRunning {
                self.process = nil
                throw LlamaServerError.exitedEarly
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        throw LlamaServerError.startupTimedOut
    }

    private func isHealthy(config: LlamaServerConfig) async -> Bool {
        var request = URLRequest(url: config.healthURL, timeoutInterval: 2)
        request.httpMethod = "GET"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return 200..<300 ~= http.statusCode
        } catch {
            return false
        }
    }
}

enum LlamaServerError: LocalizedError {
    case missingExecutable
    case missingModel(String?)
    case startFailed(String)
    case exitedEarly
    case startupTimedOut

    nonisolated var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "llama-server was not found. Install llama.cpp with Homebrew or bundle llama-server inside Echo."
        case .missingModel(let path):
            if let path {
                return "The selected Gemma model was not found at \(path)."
            }
            return "Select a local Gemma GGUF model before generating a summary."
        case .startFailed(let message):
            return "Could not start llama-server: \(message)"
        case .exitedEarly:
            return "llama-server exited before it became ready."
        case .startupTimedOut:
            return "llama-server did not become ready in time."
        }
    }
}
