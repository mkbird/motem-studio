import Darwin
import Foundation

/// Unix domain socket server inside the main app. Accepts connections from
/// `motem-mcp-bridge` helper processes (one per agent CLI), parses the
/// simplified JSON line protocol, and dispatches Godot operations on the
/// main actor.
///
/// Protocol (newline-delimited JSON, one request → one response, then close):
///
///     helper → app    {"op": "preview", "project_dir": "/abs/path"}
///     helper → app    {"op": "reload"}
///     helper → app    {"op": "stop"}
///     helper → app    {"op": "status"}
///
///     app → helper    {"ok": true, "data": {...}}
///     app → helper    {"ok": false, "error": "msg"}
@MainActor
final class MCPBridgeServer: ObservableObject {

    static let shared = MCPBridgeServer()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private var listenFD: Int32 = -1
    private var acceptThread: Thread?

    private init() {}

    var socketURL: URL { MCPConfigInjector.socketURL }

    /// Bind and start accepting. Idempotent.
    func start() {
        guard !isRunning else { return }
        let path = socketURL.path
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            lastError = "socket() failed: errno=\(errno)"
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            lastError = "socket path too long: \(path)"
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: bytes.count) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = b }
                dst[bytes.count] = 0
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            close(fd)
            lastError = "bind() failed: errno=\(errno)"
            return
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            lastError = "listen() failed: errno=\(errno)"
            return
        }
        chmod(path, 0o600)
        listenFD = fd
        isRunning = true
        lastError = nil

        let thread = Thread { [weak self] in
            self?.acceptLoop(fd: fd)
        }
        thread.name = "MCPBridgeServer.accept"
        thread.start()
        acceptThread = thread
    }

    func stop() {
        guard isRunning else { return }
        let fd = listenFD
        listenFD = -1
        isRunning = false
        if fd >= 0 { close(fd) }
        unlink(socketURL.path)
    }

    // MARK: - Accept loop (background thread)

    nonisolated private func acceptLoop(fd: Int32) {
        while true {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(fd, sockPtr, &clientLen)
                }
            }
            if client < 0 {
                if errno == EBADF || errno == EINVAL { return } // socket closed
                continue
            }
            Thread.detachNewThread { [weak self] in
                self?.handleClient(client)
            }
        }
    }

    nonisolated private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { buf -> Int in
                Darwin.recv(fd, buf.baseAddress, buf.count, 0)
            }
            if n <= 0 { return }
            buffer.append(chunk, count: n)
            if buffer.contains(0x0A) { break }
        }
        guard let nl = buffer.firstIndex(of: 0x0A) else { return }
        let lineData = buffer.prefix(upTo: nl)
        guard let object = try? JSONSerialization.jsonObject(with: Data(lineData)),
              let request = object as? [String: Any],
              let op = request["op"] as? String else {
            sendResponse(to: fd, ok: false, error: "malformed request")
            return
        }

        // Bounce onto the main actor — Godot APIs are not thread-safe.
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        DispatchQueue.main.async { [weak self] in
            Task { @MainActor in
                let result = await self?.dispatch(op: op, request: request) ?? .failure("server gone")
                box.set(Self.encode(result: result))
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 30)

        let responseData = box.take()
        if responseData.isEmpty {
            sendResponse(to: fd, ok: false, error: "timeout")
            return
        }
        _ = responseData.withUnsafeBytes { ptr -> Int in
            Darwin.send(fd, ptr.baseAddress, responseData.count, 0)
        }
    }

    nonisolated private func sendResponse(to fd: Int32, ok: Bool, data: [String: Any]? = nil, error: String? = nil) {
        var payload: [String: Any] = ["ok": ok]
        if let data { payload["data"] = data }
        if let error { payload["error"] = error }
        var out = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"ok\":false}".utf8)
        out.append(0x0A)
        _ = out.withUnsafeBytes { ptr -> Int in
            Darwin.send(fd, ptr.baseAddress, out.count, 0)
        }
    }

    nonisolated private static func encode(result: BridgeResult) -> Data {
        var payload: [String: Any]
        switch result {
        case .success(let data):
            payload = ["ok": true]
            if let data { payload["data"] = data }
        case .failure(let message):
            payload = ["ok": false, "error": message]
        }
        var out = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"ok\":false}".utf8)
        out.append(0x0A)
        return out
    }

    // MARK: - Dispatch on main actor

    @MainActor
    private func dispatch(op: String, request: [String: Any]) async -> BridgeResult {
        let controller = GodotPreviewController.shared
        switch op {
        case "preview":
            guard let dir = request["project_dir"] as? String else {
                return .failure("project_dir is required")
            }
            return await controller.preview(projectDir: URL(fileURLWithPath: dir))
        case "reload":
            return await controller.reload()
        case "stop":
            return await controller.stop()
        case "status":
            return .success(controller.statusPayload())
        default:
            return .failure("unknown op: \(op)")
        }
    }
}

enum BridgeResult {
    case success([String: Any]?)
    case failure(String)
}

/// Reference-typed box used to hand a single value across the
/// main-actor → background-thread boundary without violating Swift 6
/// sendable-closure-capture rules.
private final class ResponseBox: @unchecked Sendable {
    private var data: Data = Data()
    private let lock = NSLock()

    func set(_ value: Data) {
        lock.lock(); defer { lock.unlock() }
        data = value
    }

    func take() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
