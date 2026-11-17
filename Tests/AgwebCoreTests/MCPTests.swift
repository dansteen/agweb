import Foundation
import Testing
@testable import AgwebCore

/// Every argv a server's runner got.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [[String]] = []
    func append(_ argv: [String]) { lock.withLock { all.append(argv) } }
    func withLock<T>(_ body: ([[String]]) -> T) -> T { lock.withLock { body(all) } }
}

/// A server on a fresh folder whose runner records each argv and answers `reply`.
private func server(ok: Bool = true, reply: String = "### Page\n- URL: https://example.com/") -> (MCPServer, Calls, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agweb-mcp-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let calls = Calls()
    let server = MCPServer(files: folder, version: "9.9.9", usage: "usage text") { argv in
        calls.append(argv)
        return (ok, reply)
    }
    return (server, calls, MCPServer.resolved(folder))
}

private func object(_ line: String?) throws -> [String: Any] {
    let line = try #require(line)
    return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
}

private func call(_ server: MCPServer, _ arguments: [String: Any]) throws -> [String: Any] {
    let request: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "agweb", "arguments": arguments]]
    let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
    return try #require(try object(server.reply(to: line))["result"] as? [String: Any])
}

private func text(_ result: [String: Any]) -> String {
    ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
}

@Test func initializeAnswersWithToolsAndTheAskedVersion() throws {
    let (server, _, _) = server()
    let reply = try object(server.reply(to: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#))
    let result = try #require(reply["result"] as? [String: Any])
    #expect(reply["id"] as? Int == 1)
    #expect(result["protocolVersion"] as? String == "2025-03-26")
    #expect(result["capabilities"] as? [String: Any]? != nil)
    #expect((result["serverInfo"] as? [String: String])?["version"] == "9.9.9")
    let unknown = try object(server.reply(to: #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
    #expect((unknown["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.protocolVersions[0])
    #expect(unknown["id"] as? String == "a")
}

@Test func notificationsGetNoReplyAndUnknownMethodsAnError() throws {
    let (server, _, _) = server()
    #expect(server.reply(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    let unknown = try object(server.reply(to: #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#))
    #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    let garbage = try object(server.reply(to: "{not json"))
    #expect((garbage["error"] as? [String: Any])?["code"] as? Int == -32700)
}

@Test func theToolListsCommandsButNotThePersonsOnes() throws {
    let (server, _, _) = server()
    let reply = try object(server.reply(to: #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))
    let tool = try #require(((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.first)
    #expect(tool["name"] as? String == "agweb")
    let schema = try #require(tool["inputSchema"] as? [String: Any])
    let commands = try #require(((schema["properties"] as? [String: Any])?["command"] as? [String: Any])?["enum"] as? [String])
    #expect(commands.contains("click") && commands.contains("snapshot"))
    for refused in ["quit", "close-all", "update", "install-cli", "install-skill", "profile-delete", "mcp"] { #expect(!commands.contains(refused)) }
    #expect((tool["description"] as? String)?.contains("usage text") == true)
}

@Test func aCallBecomesCLIArgumentsWithOptionsBeforeTheArgs() throws {
    let (server, calls, folder) = server()
    let result = try call(server, ["workspace": "t1", "command": "fill", "args": ["e3", "--not-an-option"], "options": ["submit": true, "timeout": 10000, "instant": false]])
    #expect(result["isError"] as? Bool == false)
    #expect(text(result).contains("example.com"))
    #expect(calls.withLock { $0 } == [["-w", "t1", "fill", "--download-dir=\(folder.path)", "--submit", "--timeout=10000", "--", "e3", "--not-an-option"]])
}

@Test func anEmptyValueIsItsOwnArgument() throws {
    let (server, calls, _) = server()
    _ = try call(server, ["workspace": "t", "command": "route", "args": ["**/api"], "options": ["body": ""]])
    #expect(calls.withLock { $0 }.first?.contains(where: { $0 == "--body" }) == true)
    #expect(calls.withLock { $0 }.first?.firstIndex(of: "--body").map { calls.withLock { $0 }[0][$0 + 1] } == "")
}

@Test(arguments: [
    (["workspace": "t", "command": "quit"], "only the person"),
    (["workspace": "t", "command": "close-all"], "close your own"),
    (["workspace": "t", "command": "fill", "args": ["e1"], "options": ["secret-cmd": "pass show x"]], "secrets aren't available"),
    (["workspace": "t", "command": "click", "args": ["e1"], "options": ["workspace": "other"]], "workspace field"),
    (["command": "click", "args": ["e1"]], "workspace is required"),
    (["workspace": "t", "command": "snapshto"], "did you mean snapshot"),
    (["workspace": "t", "command": "upload", "args": ["e1", "/etc/hosts"]], "outside"),
    (["workspace": "t", "command": "open", "args": ["/etc/hosts"]], "outside"),
    (["workspace": "t", "command": "goto", "args": ["file:///etc/hosts"]], "outside"),
    (["workspace": "t", "command": "goto", "args": ["../../etc/hosts"]], "outside"),
    (["workspace": "t", "command": "screenshot", "options": ["filename": "~/Desktop/x.png"]], "outside"),
    (["workspace": "t", "command": "state-load", "args": ["missing.json"]], "no such file"),
] as [([String: Any], String)])
func refusedCallsNeverRun(arguments: [String: Any], why: String) throws {
    let (server, calls, _) = server()
    let result = try call(server, arguments)
    #expect(result["isError"] as? Bool == true)
    #expect(text(result).contains(why), "\(text(result))")
    #expect(calls.withLock { $0 }.isEmpty)
}

@Test func filesInsideTheFolderAreFine() throws {
    let (server, calls, folder) = server()
    FileManager.default.createFile(atPath: folder.appendingPathComponent("page.html").path, contents: Data("<p>hi".utf8))
    _ = try call(server, ["workspace": "t", "command": "open", "args": ["page.html"]])
    _ = try call(server, ["workspace": "t", "command": "upload", "args": ["e1", "page.html"]])
    _ = try call(server, ["workspace": "t", "command": "pdf", "args": ["out/doc.pdf"]])
    let argvs = calls.withLock { $0 }
    #expect(argvs.count == 3)
    #expect(argvs[0].last == folder.appendingPathComponent("page.html").path)
    #expect(argvs[1].suffix(2) == ["e1", folder.appendingPathComponent("page.html").path])
    #expect(argvs[2].last == folder.appendingPathComponent("out/doc.pdf").path)
    // A URL is not a file.
    _ = try call(server, ["workspace": "t", "command": "goto", "args": ["example.com"]])
    #expect(calls.withLock { $0 }.last?.last == "example.com")
}

@Test func screenshotsLandInTheFolderAndComeBackAsImages() throws {
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let folder = MCPServer.resolved(FileManager.default.temporaryDirectory.appendingPathComponent("agweb-mcp-\(UUID().uuidString)"))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let server = MCPServer(files: folder, version: "1", usage: "") { argv in
        let path = argv.first { $0.hasPrefix("--filename=") }.map { String($0.dropFirst("--filename=".count)) } ?? ""
        FileManager.default.createFile(atPath: path, contents: png)
        return (true, "### Screenshot\n\(path)\n### Page\n- URL: x")
    }
    let result = try call(server, ["workspace": "t", "command": "screenshot", "args": ["e5"]])
    let content = try #require(result["content"] as? [[String: Any]])
    #expect(content.count == 2)
    #expect((content[0]["text"] as? String)?.contains(folder.path + "/page-") == true)
    #expect(content[1]["type"] as? String == "image" && content[1]["mimeType"] as? String == "image/png")
    #expect(content[1]["data"] as? String == png.base64EncodedString())
}

@Test func aFailedCommandIsAToolError() throws {
    let (server, _, _) = server(ok: false, reply: "Error: no workspace 't'")
    let result = try call(server, ["workspace": "t", "command": "click", "args": ["e1"]])
    #expect(result["isError"] as? Bool == true)
    #expect(text(result) == "Error: no workspace 't'")
}
