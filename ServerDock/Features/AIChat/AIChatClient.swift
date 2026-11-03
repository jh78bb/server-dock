import Foundation

struct AIChatClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs an AI CLI either on the SSH host or on this Mac with an authenticated SSH path.
enum AIChatClient {
    static func send(
        connection: SSHConnection, provider: AIAPIProvider, location: AIChatExecutionLocation, messages: [AIChatMessage],
        model: String, systemPrompt: String, directory: String?
    ) async throws -> String {
        guard connection.hasUsableCredentials else {
            throw AIChatClientError(message: "Connect to this server and enter its SSH password first.")
        }
        return try await Task.detached(priority: .userInitiated) {
            let conversation = ([systemPrompt] + messages.filter { !$0.isError }.map {
                "\($0.role == .user ? "User" : "Assistant"): \($0.content)"
            }).joined(separator: "\n\n")
            switch location {
            case .local:
                guard AppEnv.localTerminalEnabled else {
                    throw AIChatClientError(message: "Local AI CLI is unavailable in the App Store build.")
                }
                return try sendFromMac(connection: connection, provider: provider, conversation: conversation, model: model, directory: directory)
            case .remote:
                return try sendOnServer(connection: connection, provider: provider, conversation: conversation, model: model, directory: directory)
            }
        }.value
    }

    /// Listing models creates no conversation or inference request.
    static func listCodexModels(connection: SSHConnection?, location: AIChatExecutionLocation) async throws -> [AIModelOption] {
        try await Task.detached(priority: .userInitiated) {
            switch location {
            case .local:
                guard AppEnv.localTerminalEnabled else {
                    throw AIChatClientError(message: String(localized: "Local AI CLI is unavailable in the App Store build."))
                }
                return try localCodexModels()
            case .remote:
                guard let connection, connection.hasUsableCredentials else {
                    throw AIChatClientError(message: String(localized: "Connect to this server and enter its SSH password first."))
                }
                let session = try SSHSessionPool.shared.dedicated(connection)
                defer { session.close() }
                let result = try session.execBytes("python3 -c " + shellQuote(codexModelScript), timeout: 35,
                                                  outCap: 1 << 20, errCap: 8192)
                guard !result.timedOut, !result.cancelled else {
                    throw AIChatClientError(message: String(localized: "Model loading timed out. Try again."))
                }
                guard result.exitCode == 0 else {
                    let detail = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    throw AIChatClientError(message: detail.isEmpty ? String(localized: "Could not load models from the server.") : detail)
                }
                return try visibleCodexModels(JSONDecoder().decode([AIModelOption].self, from: result.stdout))
            }
        }.value
    }

    private static func visibleCodexModels(_ models: [AIModelOption]) throws -> [AIModelOption] {
        var seen = Set<String>()
        let visible = models.filter { !$0.hidden && !$0.model.isEmpty && seen.insert($0.model).inserted }
        guard !visible.isEmpty else {
            throw AIChatClientError(message: String(localized: "Codex returned no models. Check its sign-in and version."))
        }
        return visible
    }

    private static func localCodexModels() throws -> [AIModelOption] {
        guard let executable = localExecutable(named: "codex") else {
            throw AIChatClientError(message: String(localized: "codex CLI is not installed on this Mac."))
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("serverdock-models-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let errorURL = work.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }
        let input = Pipe(), output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.currentDirectoryURL = work
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ([environment["PATH"] ?? ""] + additionalExecutablePaths()).joined(separator: ":")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorHandle
        try process.run()
        let deadline = Date().addingTimeInterval(25)
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        var buffer = Data()
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func response(id: Int) throws -> [String: Any] {
            while Date() < deadline {
                if let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          object["id"] as? Int == id else { continue }
                    if let error = object["error"] as? [String: Any] {
                        throw AIChatClientError(message: error["message"] as? String ?? String(localized: "Could not load models."))
                    }
                    if let result = object["result"] as? [String: Any] { return result }
                } else {
                    let chunk = output.fileHandleForReading.availableData
                    guard !chunk.isEmpty else { break }
                    buffer.append(chunk)
                    guard buffer.count <= 1 << 20 else {
                        throw AIChatClientError(message: String(localized: "Invalid model response from Codex."))
                    }
                }
            }
            if Date() >= deadline { throw AIChatClientError(message: String(localized: "Model loading timed out. Try again.")) }
            throw AIChatClientError(message: String(localized: "Could not load models. Check that Codex is installed, up to date, and signed in."))
        }
        try send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "serverdock", "title": "ServerDock", "version": "1.0"]]])
        _ = try response(id: 0)
        try send(["method": "initialized", "params": [:]])
        var models: [AIModelOption] = []
        var cursor: String?
        var cursors = Set<String>()
        for id in 1...20 {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            try send(["id": id, "method": "model/list", "params": params])
            let result = try response(id: id)
            let data = try JSONSerialization.data(withJSONObject: result["data"] ?? [])
            models += try JSONDecoder().decode([AIModelOption].self, from: data)
            cursor = result["nextCursor"] as? String
            guard let next = cursor, !next.isEmpty else { return try visibleCodexModels(models) }
            guard cursors.insert(next).inserted else { break }
        }
        throw AIChatClientError(message: String(localized: "Invalid model response from Codex."))
    }

    /// Remote stdio round trips use Python's standard library without extra packages.
    static let codexModelScript = #"""
import json, os, select, shutil, subprocess, sys, time
proc = None
try:
    executable = shutil.which("codex")
    if not executable:
        raise RuntimeError("Codex is not installed on this server.")
    deadline = time.monotonic() + 25
    proc = subprocess.Popen([executable, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    buffer = b""
    def send(message):
        proc.stdin.write((json.dumps(message) + "\n").encode())
        proc.stdin.flush()
    def response(request_id):
        global buffer
        while time.monotonic() < deadline:
            if b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if message.get("id") != request_id:
                    continue
                if "error" in message:
                    raise RuntimeError(message["error"].get("message", "Model loading failed."))
                return message["result"]
            ready, _, _ = select.select([proc.stdout], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("Codex stopped. Check its version and sign-in.")
            buffer += chunk
            if len(buffer) > 1048576:
                raise RuntimeError("Invalid model response from Codex.")
        raise RuntimeError("Model loading timed out. Try again.")
    send({"id": 0, "method": "initialize", "params": {"clientInfo": {"name": "serverdock", "title": "ServerDock", "version": "1.0"}}})
    response(0)
    send({"method": "initialized", "params": {}})
    models, cursor, cursors = [], None, set()
    for request_id in range(1, 21):
        params = {"limit": 100, "includeHidden": False}
        if cursor:
            params["cursor"] = cursor
        send({"id": request_id, "method": "model/list", "params": params})
        result = response(request_id)
        models.extend(result["data"])
        cursor = result.get("nextCursor")
        if not cursor:
            print(json.dumps(models))
            break
        if cursor in cursors:
            raise RuntimeError("Invalid model response from Codex.")
        cursors.add(cursor)
    else:
        raise RuntimeError("Too many model pages from Codex.")
except Exception as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
finally:
    if proc is not None:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
"""#

    private static func sendOnServer(
        connection: SSHConnection, provider: AIAPIProvider, conversation: String, model: String, directory: String?
    ) throws -> String {
            let executable = provider == .openai ? "codex" : "claude"
            let modelOption = model.isEmpty ? "" : " --model \(shellQuote(model))"
            let invocation: String
            switch provider {
            case .openai:
                invocation = "codex exec --skip-git-repo-check" + modelOption + " " + shellQuote(conversation)
            case .anthropic:
                invocation = "claude -p" + modelOption + " " + shellQuote(conversation)
            }
            let path = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let changeDirectory = path.isEmpty || path == "~" ? "" : "cd -- \(shellQuote(path)) && "
            let command = changeDirectory + "command -v \(executable) >/dev/null 2>&1 || { printf '%s\\n' \(shellQuote("\(executable) CLI is not installed on this server.")) >&2; exit 127; }; " + invocation
            let session = try SSHSessionPool.shared.dedicated(connection)
            defer { session.close() }
            let result = try session.execBytes(command, timeout: 300, outCap: 1 << 20, errCap: 1 << 16)
            if result.timedOut { throw AIChatClientError(message: "AI CLI timed out after 5 minutes.") }
            if result.cancelled { throw AIChatClientError(message: "AI CLI request was cancelled.") }
            let output = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode != 0 {
                let detail = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw AIChatClientError(message: detail.isEmpty ? "\(executable) CLI exited with status \(result.exitCode)." : detail)
            }
            guard !output.isEmpty else { throw AIChatClientError(message: "\(executable) CLI returned an empty response.") }
            return output
    }

    private static func sendFromMac(
        connection: SSHConnection, provider: AIAPIProvider, conversation: String, model: String, directory: String?
    ) throws -> String {
        let name = provider == .openai ? "codex" : "claude"
        guard let executable = localExecutable(named: name) else {
            throw AIChatClientError(message: "\(name) CLI is not installed on this Mac.")
        }
        // Keep the control socket path short enough for macOS's UNIX socket limit.
        let work = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("serverdock-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }

        // Authenticate in a separate ssh process, so the AI CLI never receives the SSH password.
        let socket = work.appendingPathComponent("ssh-control").path
        var baseArgs = connection.sshArguments()
        let destination = baseArgs.removeLast()
        let controlOptions = ["-o", "ControlPath=\(socket)"]
        let masterArgs = baseArgs + controlOptions + ["-o", "ControlMaster=yes", "-o", "ControlPersist=600", "-f", "-N", destination]
        var masterEnv: [String: String] = [:]
        if connection.needsAskpass {
            guard let askpass = SSHAskpass.envVars(password: connection.password) else {
                throw AIChatClientError(message: "Could not prepare SSH authentication.")
            }
            masterEnv.merge(askpass) { _, new in new }
        }
        let master = try runProcess(URL(fileURLWithPath: "/usr/bin/ssh"), arguments: masterArgs, environment: masterEnv, directory: work, timeout: 30)
        guard master.exitCode == 0 else {
            throw AIChatClientError(message: master.error.isEmpty ? "Could not connect to the server via SSH." : master.error)
        }
        defer {
            _ = try? runProcess(URL(fileURLWithPath: "/usr/bin/ssh"), arguments: ["-S", socket, "-O", "exit", destination], directory: work, timeout: 10)
        }

        let sshArgs = baseArgs + controlOptions + ["-o", "ControlMaster=no", "-o", "BatchMode=yes", destination]
        let sshCommand = "ssh " + sshArgs.map(shellQuote).joined(separator: " ")
        let cwd = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let remoteDirectory = cwd.isEmpty || cwd == "~" ? "the server's home directory" : cwd
        let instructions = "You are running on the user's Mac. Manage the SSH server only through this authenticated command: \(sshCommand). Append a quoted remote shell command after the destination when needed. The user's current remote directory is \(remoteDirectory). Do not inspect or change unrelated local files.\n\n" + conversation

        var arguments: [String]
        switch provider {
        case .openai:
            arguments = ["exec", "--sandbox", "workspace-write", "-c", "sandbox_workspace_write.network_access=true", "--skip-git-repo-check", "--ephemeral", "-C", work.path]
        case .anthropic:
            arguments = ["-p", "--permission-mode", "dontAsk", "--allowedTools", "Bash(ssh:*)"]
        }
        if !model.isEmpty { arguments += ["--model", model] }
        arguments.append(instructions)
        let result = try runProcess(executable, arguments: arguments, directory: work, timeout: 300)
        guard result.exitCode == 0 else {
            throw AIChatClientError(message: result.error.isEmpty ? "\(name) CLI exited with status \(result.exitCode)." : result.error)
        }
        guard !result.output.isEmpty else { throw AIChatClientError(message: "\(name) CLI returned an empty response.") }
        return result.output
    }

    private struct ProcessResult {
        let output: String
        let error: String
        let exitCode: Int32
    }

    private static func runProcess(
        _ executable: URL, arguments: [String], environment: [String: String] = [:],
        directory: URL, timeout: TimeInterval
    ) throws -> ProcessResult {
        let outputURL = directory.appendingPathComponent(UUID().uuidString)
        let errorURL = directory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? outputHandle.close(); try? errorHandle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var processEnvironment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        processEnvironment["PATH"] = ([processEnvironment["PATH"] ?? ""] + additionalExecutablePaths())
            .filter { !$0.isEmpty }.joined(separator: ":")
        process.environment = processEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
            throw AIChatClientError(message: "AI CLI or SSH connection timed out.")
        }
        return ProcessResult(
            output: String(decoding: (try? Data(contentsOf: outputURL)) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            error: String(decoding: (try? Data(contentsOf: errorURL)) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: process.terminationStatus
        )
    }

    private static func localExecutable(named name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var directories = path.split(separator: ":").map(String.init) + additionalExecutablePaths()
        if name == "codex" { directories.append("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS") }
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func additionalExecutablePaths() -> [String] {
        let home = NSHomeDirectory()
        var paths = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.volta/bin", home + "/.asdf/shims", home + "/.local/share/mise/shims", home + "/.claude/local"]
        let nodeVersions = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nodeVersions) {
            paths += versions.sorted().reversed().map { nodeVersions + "/" + $0 + "/bin" }
        }
        return paths
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
