import Foundation

/// `agweb mcp`: an MCP server on stdin and stdout, for clients that can't run shell commands (the Claude desktop
/// app's Chat tab). One tool, `agweb`, runs one CLI command per call through `run`, so the app sees exactly what a
/// shell agent sends and the CLI keeps doing what only it does (launching the app, absolute paths, writing files).
///
/// A shell agent can already run anything; an MCP client can't, so the tool must not hand it more than a browser:
/// commands that hit every agent or the install are refused, `--secret-cmd` (a shell command) and `--secret-file` are
/// refused, and every file path, read or written, stays inside `files`. Navigating to a local file counts as reading it.
public struct MCPServer: Sendable {
    public typealias Runner = @Sendable (_ argv: [String]) -> (ok: Bool, output: String)

    /// Newest first; an initialize asking for one of these gets it back, anything else the newest.
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// What the tool won't run, and why: only the person may.
    static let refused: [String: String] = [
        "quit": "quit stops agweb for every agent; only the person quits it",
        "close-all": "close-all closes every agent's workspaces; close your own with the close command",
        "update": "updating restarts agweb for every agent; the person runs Agweb ▸ Check for Updates…",
        "install-cli": "installing is the person's: Help ▸ Install Command Line Tool",
        "install-skill": "installing is the person's: Help ▸ Install Agent Skill",
        "profile-delete": "deleting a profile and its logins is the person's: agweb profile-delete in a terminal",
        "mcp": "this is the MCP server already",
    ]
    static let refusedOptions: [String: String] = [
        "secret-cmd": "secrets aren't available over MCP (--secret-cmd runs a shell command); use a named profile that is "
            + "already signed in, or the ask command to have the person sign in",
        "secret-file": "secrets aren't available over MCP; use a named profile that is already signed in, or the ask command",
        "workspace": "pass the workspace in the tool's workspace field",
    ]
    static var commands: [String] { Commands.all.filter { refused[$0] == nil } }
    /// Options naming a file on disk (`path` is a file only for screenshot; for cookies it is a URL path).
    static let fileOptions: Set = ["filename", "download-dir"]
    static let imageTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg"]
    /// Larger screenshots stay on disk: clients cap an image near 5 MB.
    static let maxImageBytes = 4_500_000

    let files: URL
    let version: String
    let usage: String
    let run: Runner

    /// `files`: the one folder the tool's paths may name; relative paths are inside it.
    public init(files: URL, version: String, usage: String, run: @escaping Runner) {
        self.files = Self.resolved(files.standardizedFileURL)
        self.version = version
        self.usage = usage
        self.run = run
    }

    // MARK: JSON-RPC

    /// The reply to one message (a line of JSON-RPC 2.0), or nil for a notification.
    public func reply(to line: String) -> String? {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
        }
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            result = [
                "protocolVersion": asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "agweb", "version": version],
                "instructions": instructions,
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": [tool]]
        case "tools/call":
            guard params["name"] as? String == "agweb" else {
                return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "no tool \(params["name"] ?? "")"]])
            }
            result = call(params["arguments"] as? [String: Any] ?? [:])
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found: \(method)"]])
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: The tool

    var instructions: String {
        """
        agweb is a real, visible WebKit browser on the person's Mac, shared with other agents; nothing it does takes \
        their focus. Work in a workspace of your own, named uniquely for the task (task-7f3a), on every call: open \
        a URL, snapshot to get [ref=eN] handles, act on refs (click, fill, select, press), read the ### Changes in \
        each reply instead of snapshotting again, and close the workspace when done. For a login, MFA code or \
        CAPTCHA, use ask: the person does it and clicks Done. A named profile (options.profile on open) keeps \
        logins. Files are read and written only in \(files.path); screenshots also come back as images.
        """
    }

    var tool: [String: Any] {
        let description = """
        Run one agweb command in a workspace, as `agweb -w <workspace> <command> <args> --<options>` would. \
        args are the positional arguments (a target, text, a URL); options are the --options without dashes, \
        a boolean for a flag ({"submit": true}) or a string for a value ({"timeout": "10000"}). \
        Not available here: \(Self.refused.keys.sorted().joined(separator: ", ")), --secret-cmd and --secret-file. \
        File paths are relative to \(files.path) and can't leave it.

        \(usage)
        """
        return [
            "name": "agweb",
            "title": "agweb browser",
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "workspace": ["type": "string", "description": "Your workspace: a unique name for this task (task-7f3a), the same on every call. Another agent's is not yours."],
                    "command": ["type": "string", "enum": Self.commands, "description": "The agweb command."],
                    "args": ["type": "array", "items": ["type": "string"], "description": "Positional arguments in order: click [\"e12\"], fill [\"e3\", \"Paul\"], open [\"https://example.com\"]."],
                    "options": ["type": "object", "additionalProperties": ["type": ["string", "boolean", "number"]],
                                "description": "--options without the dashes: {\"profile\": \"work\"}, {\"diff\": true}, {\"timeout\": 10000}."],
                ],
                "required": ["workspace", "command"],
            ],
        ]
    }

    /// Runs the call, or explains why not, as a tool result.
    func call(_ arguments: [String: Any]) -> [String: Any] {
        let argv: [String]
        do {
            argv = try self.argv(arguments)
        } catch {
            return ["content": [["type": "text", "text": "Error: \(error)"]], "isError": true]
        }
        let (ok, output) = run(argv)
        var content: [[String: Any]] = [["type": "text", "text": output]]
        if ok { content += images(in: output) }
        return ["content": content, "isError": !ok]
    }

    /// The CLI's arguments for a tool call: options first, then `--`, so text that starts with dashes stays text.
    func argv(_ arguments: [String: Any]) throws -> [String] {
        guard let workspace = (arguments["workspace"] as? String)?.trimmingCharacters(in: .whitespaces), !workspace.isEmpty else {
            throw Failure("workspace is required: a unique name for this task, the same on every call")
        }
        guard let command = arguments["command"] as? String, !command.isEmpty else { throw Failure("command is required") }
        if let why = Self.refused[command] { throw Failure(why) }
        guard Commands.all.contains(command) else { throw Failure(Commands.unknown(command)) }
        guard let rawArgs = arguments["args"] as? [Any] ?? (arguments["args"] == nil ? [] : nil) else { throw Failure("args is a list of strings") }
        var args = try rawArgs.map { value -> String in
            switch value {
            case let text as String: return text
            case let number as NSNumber where !Self.isBool(number): return number.stringValue
            default: throw Failure("args is a list of strings")
            }
        }
        guard let rawOptions = arguments["options"] as? [String: Any] ?? (arguments["options"] == nil ? [:] : nil) else {
            throw Failure("options is an object: {\"submit\": true, \"timeout\": \"10000\"}")
        }
        var options: [String: String?] = [:]  // nil: a flag
        for (name, value) in rawOptions {
            let name = name.hasPrefix("--") ? String(name.dropFirst(2)) : name
            guard name.range(of: "^[A-Za-z][A-Za-z-]*$", options: .regularExpression) != nil else { throw Failure("bad option name \(name)") }
            if let why = Self.refusedOptions[name] { throw Failure(why) }
            switch value {
            case let number as NSNumber where Self.isBool(number):
                if number.boolValue { options[name] = .some(nil) }
            case let number as NSNumber: options[name] = number.stringValue
            case let text as String: options[name] = text
            default: throw Failure("option \(name) takes a string, a number or true")
            }
        }

        // Every path the command reads or writes, kept inside the files folder.
        for name in Self.fileOptions.union(command == "screenshot" ? ["path"] : []) {
            if let value = options[name], let path = value { options[name] = try inside(path) }
        }
        switch command {
        case "upload":
            if args.count > 1 { args = [args[0]] + (try args.dropFirst().map { try inside($0, mustExist: true) }) }
        case "state-load":
            if !args.isEmpty { args[0] = try inside(args[0], mustExist: true) }
        case "pdf", "video-start", "state-save":
            if !args.isEmpty { args[0] = try inside(args[0]) }
        case "screenshot":
            // The CLI takes an image path here for a target, a playwright-cli habit.
            if let first = args.first, Self.isImage(first) { args[0] = try inside(first) }
        case "open", "goto", "tab-new":
            if let first = args.first, let path = localPath(first) { args[0] = try inside(path, mustExist: true) }
        default:
            break
        }
        // Without a name the CLI writes to a hidden .agweb folder; here they go where the person looks.
        let stamp = Self.stamp()
        let defaults = ["screenshot": "page-\(stamp).png", "pdf": "page-\(stamp).pdf", "video-start": "video-\(stamp).mp4", "state-save": "state-\(stamp).json"]
        let named = options["filename"] != nil
            || (command == "screenshot" ? options["path"] != nil || args.first.map(Self.isImage) == true : !args.isEmpty)
        if let name = defaults[command], !named { options["filename"] = files.appendingPathComponent(name).path }
        if options["download-dir"] == nil { options["download-dir"] = files.path }

        // An empty value goes as its own argument: the CLI reads `--body=` as `--body` with the value to follow.
        return ["-w", workspace, command] + options.keys.sorted().flatMap { name -> [String] in
            guard let value = options[name]! else { return ["--\(name)"] }
            return value.isEmpty ? ["--\(name)", ""] : ["--\(name)=\(value)"]
        } + ["--"] + args
    }

    static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }
    static func isImage(_ path: String) -> Bool { imageTypes[URL(fileURLWithPath: path).pathExtension.lowercased()] != nil }

    /// What a navigation target names on disk, if anything: an absolute or home path, a file URL, or a file in the folder.
    private func localPath(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("file:") { return URL(string: text)?.path ?? String(text.dropFirst(5)) }
        if text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix(".") { return text }
        return FileManager.default.fileExists(atPath: files.appendingPathComponent(text).path) ? text : nil
    }

    /// `path` made absolute against the files folder, or a failure if it leaves the folder.
    func inside(_ path: String, mustExist: Bool = false) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = Self.resolved(URL(fileURLWithPath: expanded.hasPrefix("/") ? expanded : files.path + "/" + expanded).standardizedFileURL)
        guard url.path == files.path || url.path.hasPrefix(files.path + "/") else {
            throw Failure("\(path) is outside \(files.path); over MCP, files are read and written only there")
        }
        if mustExist, !FileManager.default.fileExists(atPath: url.path) { throw Failure("no such file in \(files.path): \(path)") }
        return url.path
    }

    /// Symlinks resolved, for a path that may not exist yet: the part that exists is resolved, the rest appended.
    static func resolved(_ url: URL) -> URL {
        var existing = url, rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }

    /// The screenshots a reply names, as image content, so a client that can't open files still sees them.
    func images(in output: String) -> [[String: Any]] {
        Output.sections(output).filter { $0.title == "Screenshot" }.compactMap { section in
            guard let path = section.body.split(separator: "\n").first.map(String.init),
                  let type = Self.imageTypes[URL(fileURLWithPath: path).pathExtension.lowercased()],
                  (try? inside(path)) != nil,
                  let data = FileManager.default.contents(atPath: path), data.count <= Self.maxImageBytes else { return nil }
            return ["type": "image", "data": data.base64EncodedString(), "mimeType": type]
        }
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"
        return formatter.string(from: Date())
    }
}
