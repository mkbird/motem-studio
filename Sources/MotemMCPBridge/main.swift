// motem-mcp-bridge: stdio MCP server that forwards Godot tool calls back to
// the running Motem Studio app via a Unix domain socket.
//
// Spawned per-terminal by each agent CLI (claude / codex / gemini) via the
// project's `.mcp.json`. One process per CLI session; lifetime tied to the
// CLI's lifetime. Holds no engine state — translation only.

import Darwin
import Foundation

// MARK: - Constants

let kServerName = "motem-studio"
let kServerVersion = "0.1.0"
let kProtocolVersion = "2024-11-05"

let kSocketEnv = "MOTEM_MCP_SOCKET"
let kWorkdirEnv = "MOTEM_WORKDIR"

// MARK: - Logging (stderr only — stdout is the MCP transport)

func log(_ message: String) {
    FileHandle.standardError.write(Data("[motem-mcp-bridge] \(message)\n".utf8))
}

// MARK: - Unix socket client to main app

final class BridgeClient {
    private let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Send one JSON request, wait for one JSON line response, then close.
    /// Each call is short-lived: connect → send → recv → close.
    func send(op: String, params: [String: Any]) -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return ["ok": false, "error": "socket() failed: errno=\(errno)"]
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            return ["ok": false, "error": "socket path too long: \(socketPath)"]
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: pathBytes.count) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = b }
                dst[pathBytes.count] = 0
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, addrLen)
            }
        }
        if connectResult != 0 {
            return ["ok": false, "error": "connect() failed: errno=\(errno) — is Motem Studio running?"]
        }

        var request: [String: Any] = ["op": op]
        request.merge(params) { _, new in new }
        guard let payload = try? JSONSerialization.data(withJSONObject: request),
              var line = String(data: payload, encoding: .utf8) else {
            return ["ok": false, "error": "failed to serialize request"]
        }
        line.append("\n")
        let outBytes = Array(line.utf8)
        var sent = 0
        while sent < outBytes.count {
            let n = outBytes[sent...].withUnsafeBufferPointer { buf -> Int in
                Darwin.send(fd, buf.baseAddress, buf.count, 0)
            }
            if n <= 0 {
                return ["ok": false, "error": "send() failed: errno=\(errno)"]
            }
            sent += n
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { buf -> Int in
                Darwin.recv(fd, buf.baseAddress, buf.count, 0)
            }
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            if let nl = buffer.firstIndex(of: 0x0A) {
                buffer = buffer.prefix(through: nl)
                break
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: buffer),
              let dict = object as? [String: Any] else {
            return ["ok": false, "error": "bad response from app"]
        }
        return dict
    }
}

// MARK: - MCP JSON-RPC

struct JSONRPCRequest {
    let id: Any?
    let method: String
    let params: [String: Any]
}

func parseRequest(_ data: Data) -> JSONRPCRequest? {
    guard let obj = try? JSONSerialization.jsonObject(with: data),
          let dict = obj as? [String: Any],
          let method = dict["method"] as? String else {
        return nil
    }
    let params = (dict["params"] as? [String: Any]) ?? [:]
    return JSONRPCRequest(id: dict["id"], method: method, params: params)
}

func writeResponse(id: Any?, result: [String: Any]? = nil, error: [String: Any]? = nil) {
    var payload: [String: Any] = ["jsonrpc": "2.0"]
    if let id { payload["id"] = id }
    if let result { payload["result"] = result }
    if let error { payload["error"] = error }
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

// MARK: - Tool schemas

let kTools: [[String: Any]] = [
    [
        "name": "godot_preview",
        "description": "Preview a Godot 4 project in Motem Studio's embedded engine pane. Call after generating a Godot project under the working directory. The directory must contain a project.godot file.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "project_dir": [
                    "type": "string",
                    "description": "Absolute path to the directory containing project.godot",
                ],
            ],
            "required": ["project_dir"],
        ],
    ],
    [
        "name": "godot_reload",
        "description": "Reload the current scene from disk after modifying any .gd or .tscn file. Faster than godot_preview because it skips the rsync step.",
        "inputSchema": [
            "type": "object",
            "properties": [:],
        ],
    ],
    [
        "name": "godot_stop",
        "description": "Unload the current scene and return the preview pane to its placeholder state.",
        "inputSchema": [
            "type": "object",
            "properties": [:],
        ],
    ],
    [
        "name": "godot_status",
        "description": "Return the engine status: whether the engine is booted, which project is loaded, the active scene, and any error.",
        "inputSchema": [
            "type": "object",
            "properties": [:],
        ],
    ],
]

// MARK: - Dispatch

func handleInitialize(id: Any?) {
    let result: [String: Any] = [
        "protocolVersion": kProtocolVersion,
        "capabilities": [
            "tools": [:],
        ],
        "serverInfo": [
            "name": kServerName,
            "version": kServerVersion,
            "description": "Motem Studio Godot preview bridge. After generating a Godot 4 project, call godot_preview with the absolute path. After editing .gd or .tscn files, call godot_reload.",
        ],
    ]
    writeResponse(id: id, result: result)
}

func handleToolsList(id: Any?) {
    writeResponse(id: id, result: ["tools": kTools])
}

func handleToolsCall(id: Any?, params: [String: Any], client: BridgeClient) {
    guard let name = params["name"] as? String else {
        writeResponse(id: id, error: ["code": -32602, "message": "missing tool name"])
        return
    }
    let arguments = (params["arguments"] as? [String: Any]) ?? [:]
    let op: String
    var fwd: [String: Any] = [:]
    switch name {
    case "godot_preview":
        op = "preview"
        if let dir = arguments["project_dir"] as? String {
            fwd["project_dir"] = dir
        } else {
            writeResponse(id: id, error: ["code": -32602, "message": "godot_preview requires project_dir"])
            return
        }
    case "godot_reload":
        op = "reload"
    case "godot_stop":
        op = "stop"
    case "godot_status":
        op = "status"
    default:
        writeResponse(id: id, error: ["code": -32601, "message": "unknown tool: \(name)"])
        return
    }
    let response = client.send(op: op, params: fwd)
    let ok = (response["ok"] as? Bool) ?? false
    let text: String
    if ok {
        if let data = response["data"], let json = try? JSONSerialization.data(withJSONObject: data),
           let str = String(data: json, encoding: .utf8) {
            text = str
        } else {
            text = "ok"
        }
    } else {
        let err = (response["error"] as? String) ?? "unknown error"
        text = "ERROR: \(err)"
    }
    writeResponse(
        id: id,
        result: [
            "content": [[
                "type": "text",
                "text": text,
            ]],
            "isError": !ok,
        ]
    )
}

// MARK: - Main loop

let env = ProcessInfo.processInfo.environment
guard let socketPath = env[kSocketEnv], !socketPath.isEmpty else {
    log("\(kSocketEnv) not set — cannot reach Motem Studio. Exiting.")
    exit(1)
}
let client = BridgeClient(socketPath: socketPath)

let stdin = FileHandle.standardInput
var pending = Data()
while true {
    let chunk = stdin.availableData
    if chunk.isEmpty { break }
    pending.append(chunk)
    while let nl = pending.firstIndex(of: 0x0A) {
        let lineData = pending.prefix(upTo: nl)
        pending.removeSubrange(...nl)
        guard !lineData.isEmpty else { continue }
        guard let req = parseRequest(Data(lineData)) else {
            log("malformed JSON line: \(String(data: Data(lineData), encoding: .utf8) ?? "?")")
            continue
        }
        switch req.method {
        case "initialize":
            handleInitialize(id: req.id)
        case "notifications/initialized":
            break
        case "tools/list":
            handleToolsList(id: req.id)
        case "tools/call":
            handleToolsCall(id: req.id, params: req.params, client: client)
        default:
            if req.id != nil {
                writeResponse(id: req.id, error: ["code": -32601, "message": "method not found: \(req.method)"])
            }
        }
    }
}
