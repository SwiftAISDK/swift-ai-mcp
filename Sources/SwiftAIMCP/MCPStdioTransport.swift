import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


#if os(macOS) || os(Linux)

/// Shell execution is explicit; command and arguments use shell syntax when enabled.
public enum MCPStdioShell: Equatable, Sendable {
    case disabled
    case system
    case executable(String)
}

public struct MCPStdioConfig: Equatable, Sendable {
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var cwd: String?
    public var shell: MCPStdioShell

    public init(
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        cwd: String? = nil,
        shell: MCPStdioShell = .disabled
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.shell = shell
    }
}

public final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    public let supportsProtocolVersionDiscovery = true
    private let state: MCPStdioTransportState

    public init(config: MCPStdioConfig) {
        self.state = MCPStdioTransportState(config: config)
    }

    public convenience init(
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        cwd: String? = nil,
        shell: MCPStdioShell = .disabled
    ) {
        self.init(config: MCPStdioConfig(command: command, args: args, env: env, cwd: cwd, shell: shell))
    }

    public func setRequestHandler(_ handler: (@Sendable (JSONValue) async -> JSONValue)?) async {
        await state.setRequestHandler(handler)
    }

    public func start() async throws {
        try await state.start()
    }

    public func request(_ message: JSONValue) async throws -> JSONValue {
        try await state.request(message)
    }

    public func notify(_ message: JSONValue) async throws {
        try await state.notify(message)
    }

    public func close() async throws {
        await state.close()
    }
}

private actor MCPStdioTransportState {
    private let config: MCPStdioConfig
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var readBuffer = Data()
    private var requestHandler: (@Sendable (JSONValue) async -> JSONValue)?
    private var pendingRequests: [JSONValue: CheckedContinuation<JSONValue, Error>] = [:]

    init(config: MCPStdioConfig) {
        self.config = config
    }

    func setRequestHandler(_ handler: (@Sendable (JSONValue) async -> JSONValue)?) {
        requestHandler = handler
    }

    func start() throws {
        guard process == nil else {
            throw MCPClientError(message: "StdioMCPTransport already started.")
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.environment = mcpStdioEnvironment(config.env)
        if let cwd = config.cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }

        switch config.shell {
        case .disabled:
            if config.command.contains("/") {
                process.executableURL = URL(fileURLWithPath: config.command)
                process.arguments = config.args
            } else {
                process.executableURL = mcpStdioEnvExecutableURL()
                process.arguments = [config.command] + config.args
            }
        case .system, .executable:
            let shell: String
            if case let .executable(path) = config.shell { shell = path } else { shell = "/bin/sh" }
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", ([config.command] + config.args).joined(separator: " ")]
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.processOutput(data) }
        }
        process.terminationHandler = { [weak self] process in
            Task { await self?.processTerminated(status: process.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
    }

    func request(_ message: JSONValue) async throws -> JSONValue {
        guard let id = message["id"] else {
            throw MCPClientError(message: "StdioMCPTransport request is missing a JSON-RPC id.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            do {
                try writeMessage(message)
            } catch {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    func notify(_ message: JSONValue) throws {
        try writeMessage(message)
    }

    func close() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        try? outputPipe?.fileHandleForReading.close()
        try? inputPipe?.fileHandleForWriting.close()

        let currentProcess = process
        process = nil
        inputPipe = nil
        outputPipe = nil
        readBuffer.removeAll()

        let continuations = pendingRequests
        pendingRequests.removeAll()
        for continuation in continuations.values {
            continuation.resume(throwing: MCPClientError(message: "StdioMCPTransport closed."))
        }

        if currentProcess?.isRunning == true {
            currentProcess?.terminate()
        }
    }

    private func processOutput(_ data: Data) async {
        readBuffer.append(data)
        while let line = readLine() {
            do {
                let message = try decodeJSONBody(Data(line.utf8))
                try await handleMessage(message)
            } catch {
                failPendingRequests(error)
            }
        }
    }

    private func handleMessage(_ message: JSONValue) async throws {
        if let id = message["id"], message["method"]?.stringValue == nil, let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(returning: message)
            return
        }

        guard message["method"]?.stringValue != nil, message["id"] != nil else {
            return
        }

        if let requestHandler {
            let response = await requestHandler(message)
            try writeMessage(response)
        } else {
            try writeMessage(mcpStdioJSONRPCErrorResponse(
                id: message["id"],
                code: -32601,
                message: "No MCP stdio request handler registered."
            ))
        }
    }

    private func processTerminated(status: Int32) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        readBuffer.removeAll()

        let continuations = pendingRequests
        pendingRequests.removeAll()
        guard !continuations.isEmpty else { return }
        let error = MCPClientError(message: "StdioMCPTransport process exited with status \(status).")
        for continuation in continuations.values {
            continuation.resume(throwing: error)
        }
    }

    private func writeMessage(_ message: JSONValue) throws {
        guard process?.isRunning == true, let inputPipe else {
            throw MCPClientError(message: "StdioClientTransport not connected")
        }
        var data = try encodeJSONBody(message)
        data.append(10)
        try inputPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func readLine() -> String? {
        guard let newlineIndex = readBuffer.firstIndex(of: 10) else { return nil }
        var lineData = Data(readBuffer[..<newlineIndex])
        readBuffer.removeSubrange(...newlineIndex)
        if lineData.last == 13 {
            lineData.removeLast()
        }
        return String(decoding: lineData, as: UTF8.self)
    }

    private func failPendingRequests(_ error: Error) {
        let continuations = pendingRequests
        pendingRequests.removeAll()
        for continuation in continuations.values {
            continuation.resume(throwing: error)
        }
    }
}

private func mcpStdioJSONRPCErrorResponse(id: JSONValue?, code: Int, message: String) -> JSONValue {
    .object([
        "jsonrpc": .string("2.0"),
        "id": id ?? .null,
        "error": .object([
            "code": .number(Double(code)),
            "message": .string(message)
        ])
    ])
}

private func mcpStdioEnvExecutableURL() -> URL {
    let fileManager = FileManager.default
    if fileManager.isExecutableFile(atPath: "/usr/bin/env") {
        return URL(fileURLWithPath: "/usr/bin/env")
    }
    return URL(fileURLWithPath: "/bin/env")
}

func mcpStdioEnvironment(_ custom: [String: String]) -> [String: String] {
    #if os(Windows)
    let inheritedKeys = [
        "APPDATA",
        "HOMEDRIVE",
        "HOMEPATH",
        "LOCALAPPDATA",
        "PATH",
        "PROCESSOR_ARCHITECTURE",
        "SYSTEMDRIVE",
        "SYSTEMROOT",
        "TEMP",
        "USERNAME",
        "USERPROFILE"
    ]
    #else
    let inheritedKeys = ["HOME", "LOGNAME", "PATH", "SHELL", "TERM", "USER"]
    #endif

    var environment = custom
    let processEnvironment = ProcessInfo.processInfo.environment
    #if os(Windows)
    let customKeys = Set(custom.keys.map { $0.uppercased() })
    #else
    let customKeys = Set(custom.keys)
    #endif
    for key in inheritedKeys {
        guard !customKeys.contains(key) else { continue }
        guard let value = processEnvironment[key], !value.hasPrefix("()") else { continue }
        environment[key] = value
    }
    return environment
}

#endif