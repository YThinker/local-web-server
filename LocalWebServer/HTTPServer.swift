import Foundation
import Network

struct ServerStatus {
    var running: Bool = false
    var port: UInt16 = 0
    var message: String = "未启动"
}

/// 极简 HTTP/1.1 静态文件服务器，基于 Network.framework，零第三方依赖。
/// 只做一件事：把 rootURL 目录下的文件通过 http://127.0.0.1:port/ 暴露出去。
final class LocalHTTPServer {

    // MARK: - 对外状态

    var onStatus: ((ServerStatus) -> Void)?
    private(set) var status = ServerStatus()

    /// true = 监听所有网卡（同 Wi-Fi 的其他设备也能访问，会触发 iOS 本地网络授权）
    /// false = 只监听 127.0.0.1（默认，最安全，也不会和本机其他服务抢端口）
    var bindToLAN = false

    var rootURL: URL {
        get { rootLock.lock(); defer { rootLock.unlock() }; return _rootURL }
        set { rootLock.lock(); _rootURL = newValue; rootLock.unlock() }
    }

    // MARK: - 内部

    private let queue = DispatchQueue(label: "com.localweb.http", qos: .userInitiated)
    private let rootLock = NSLock()
    private var _rootURL: URL

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var candidates: [UInt16] = []
    private var candidateIndex = 0
    private var stopping = false

    private static let preferredPorts: [UInt16] = [8080, 8081, 8082, 8083, 8084, 8085]

    private static func portCandidates() -> [UInt16] {
        var list = preferredPorts
        // 兜底：再随机试几个高位端口，几乎不可能全被占用
        for _ in 0..<8 { list.append(UInt16.random(in: 49_152...65_000)) }
        return list
    }

    init(rootURL: URL) {
        self._rootURL = rootURL
    }

    // MARK: - 启动 / 停止

    func start() {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            self.stopping = false
            self.candidates = LocalHTTPServer.portCandidates()
            self.candidateIndex = 0
            self.tryNextPort()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopping = true
            self.tearDownListener()
            self.publish(ServerStatus(running: false, port: 0, message: "已停止"))
        }
    }

    func restart() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopping = true
            self.tearDownListener()
            self.stopping = false
            self.candidates = LocalHTTPServer.portCandidates()
            self.candidateIndex = 0
            self.tryNextPort()
        }
    }

    /// 切换「是否允许同 Wi-Fi 下的其他设备访问」，会自动重启监听。
    func setBindToLAN(_ value: Bool) {
        queue.async { [weak self] in
            guard let self, self.bindToLAN != value else { return }
            self.bindToLAN = value
            self.stopping = true
            self.tearDownListener()
            self.stopping = false
            self.candidates = LocalHTTPServer.portCandidates()
            self.candidateIndex = 0
            self.tryNextPort()
        }
    }

    private func tearDownListener() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for (_, conn) in connections {
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        connections.removeAll()
    }

    private func publish(_ newStatus: ServerStatus) {
        status = newStatus
        let callback = onStatus
        DispatchQueue.main.async { callback?(newStatus) }
    }

    private func tryNextPort() {
        guard !stopping else { return }
        guard candidateIndex < candidates.count else {
            publish(ServerStatus(running: false, port: 0, message: "启动失败：没有可用端口"))
            return
        }

        let raw = candidates[candidateIndex]
        candidateIndex += 1

        guard let nwPort = NWEndpoint.Port(rawValue: raw) else {
            tryNextPort()
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            let newListener: NWListener
            if bindToLAN {
                newListener = try NWListener(using: params, on: nwPort)
            } else {
                // 只绑回环地址：外部设备访问不到，也不会和本机其他服务抢端口，
                // 同时不会触发 iOS 的「本地网络」授权弹窗。
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
                newListener = try NWListener(using: params)
            }

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let actual = newListener.port?.rawValue ?? raw
                    self.publish(ServerStatus(running: true, port: actual, message: "运行中"))
                case .failed:
                    guard self.listener === newListener else { return }
                    newListener.stateUpdateHandler = nil
                    newListener.newConnectionHandler = nil
                    newListener.cancel()
                    self.listener = nil
                    self.tryNextPort()
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }

            listener = newListener
            newListener.start(queue: queue)
        } catch {
            tryNextPort()
        }
    }

    // MARK: - 连接处理

    private func accept(_ conn: NWConnection) {
        let id = UUID()
        connections[id] = conn

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.closeConnection(id)
            default:
                break
            }
        }

        conn.start(queue: queue)
        readRequest(on: conn, id: id, buffer: Data())
    }

    private func closeConnection(_ id: UUID) {
        guard let conn = connections.removeValue(forKey: id) else { return }
        conn.stateUpdateHandler = nil
        conn.cancel()
    }

    private func readRequest(on conn: NWConnection, id: UUID, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var accumulated = buffer
            if let data, !data.isEmpty { accumulated.append(data) }

            if let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let head = accumulated.subdata(in: accumulated.startIndex..<headerEnd.lowerBound)
                self.handle(head, on: conn, id: id)
                return
            }

            if accumulated.count > 256 * 1024 || isComplete || error != nil {
                self.closeConnection(id)
                return
            }

            self.readRequest(on: conn, id: id, buffer: accumulated)
        }
    }

    // MARK: - 请求路由

    private func handle(_ head: Data, on conn: NWConnection, id: UUID) {
        guard let text = String(data: head, encoding: .utf8) else {
            respond(status: 400, reason: "Bad Request", contentType: nil, body: Data(), headOnly: false, on: conn, id: id)
            return
        }

        guard let firstLine = text.components(separatedBy: "\r\n").first, !firstLine.isEmpty else {
            respond(status: 400, reason: "Bad Request", contentType: nil, body: Data(), headOnly: false, on: conn, id: id)
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(status: 400, reason: "Bad Request", contentType: nil, body: Data(), headOnly: false, on: conn, id: id)
            return
        }

        let method = String(parts[0]).uppercased()
        var rawPath = String(parts[1])
        let headOnly = (method == "HEAD")

        guard method == "GET" || method == "HEAD" else {
            let page = Self.errorPage(code: 405, title: "Method Not Allowed", detail: "只支持 GET / HEAD。")
            respond(status: 405, reason: "Method Not Allowed", contentType: "text/html; charset=utf-8", body: Data(page.utf8), headOnly: false, on: conn, id: id)
            return
        }

        if let q = rawPath.firstIndex(of: "?") { rawPath = String(rawPath[..<q]) }
        if let h = rawPath.firstIndex(of: "#") { rawPath = String(rawPath[..<h]) }
        rawPath = rawPath.removingPercentEncoding ?? rawPath
        if rawPath.isEmpty { rawPath = "/" }

        let components = rawPath.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }

        if components.contains("..") {
            let page = Self.errorPage(code: 403, title: "Forbidden", detail: "路径不合法。")
            respond(status: 403, reason: "Forbidden", contentType: "text/html; charset=utf-8", body: Data(page.utf8), headOnly: headOnly, on: conn, id: id)
            return
        }

        var target = rootURL
        for component in components { target.appendPathComponent(component) }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            let page = Self.errorPage(code: 404, title: "404 Not Found", detail: "/" + components.joined(separator: "/"))
            respond(status: 404, reason: "Not Found", contentType: "text/html; charset=utf-8", body: Data(page.utf8), headOnly: headOnly, on: conn, id: id)
            return
        }

        if isDirectory.boolValue {
            let indexURL = target.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: indexURL.path) {
                serveFile(indexURL, headOnly: headOnly, on: conn, id: id)
            } else {
                let listing = directoryListing(at: target, requestPath: rawPath)
                respond(status: 200, reason: "OK", contentType: "text/html; charset=utf-8", body: Data(listing.utf8), headOnly: headOnly, on: conn, id: id)
            }
        } else {
            serveFile(target, headOnly: headOnly, on: conn, id: id)
        }
    }

    private func serveFile(_ url: URL, headOnly: Bool, on conn: NWConnection, id: UUID) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            let page = Self.errorPage(code: 500, title: "500", detail: "无法读取文件：\(url.lastPathComponent)")
            respond(status: 500, reason: "Internal Server Error", contentType: "text/html; charset=utf-8", body: Data(page.utf8), headOnly: headOnly, on: conn, id: id)
            return
        }
        let mime = Self.mimeType(for: url.pathExtension)
        respond(status: 200, reason: "OK", contentType: mime, body: data, headOnly: headOnly, on: conn, id: id)
    }

    // MARK: - 响应

    private func respond(status: Int, reason: String, contentType: String?, body: Data, headOnly: Bool, on conn: NWConnection, id: UUID) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Cache-Control: no-store, no-cache, must-revalidate\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        if !headOnly { payload.append(body) }

        conn.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.closeConnection(id)
        })
    }

    // MARK: - 辅助

    private func directoryListing(at directory: URL, requestPath: String) -> String {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let sorted = entries.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let base = requestPath.hasSuffix("/") ? requestPath : requestPath + "/"
        var rows = ""
        if base != "/" {
            rows += "<li><a href=\"\(base)..\">⬆︎ 返回上一级</a></li>"
        }
        for entry in sorted {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = entry.lastPathComponent
            let href = base + name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).orEmpty
            rows += "<li><a href=\"\(href)\">\(name)\(isDir ? "/" : "")</a></li>"
        }

        return """
        <!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(requestPath)</title>
        <style>
        body{font:-apple-system,system-ui,sans-serif;margin:0;padding:24px;background:#f6f7f9;color:#111}
        h1{font-size:18px;margin:0 0 16px}
        code{font-family:ui-monospace,Menlo,monospace;color:#666;font-size:13px}
        ul{list-style:none;padding:0;margin:0;background:#fff;border-radius:12px;overflow:hidden}
        li+li{border-top:1px solid #eee}
        a{display:block;padding:14px 16px;color:#0a63ff;text-decoration:none}
        </style></head><body>
        <h1>目录索引</h1><p><code>\(requestPath)</code></p><ul>\(rows)</ul>
        </body></html>
        """
    }

    private static func errorPage(code: Int, title: String, detail: String) -> String {
        """
        <!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(code)</title>
        <style>
        body{font:-apple-system,system-ui,sans-serif;margin:0;padding:48px 24px;background:#f6f7f9;color:#111;text-align:center}
        h1{font-size:56px;margin:0;color:#c8ccd4}
        p{font-size:15px;color:#555}
        code{font-family:ui-monospace,Menlo,monospace;font-size:13px;color:#888;word-break:break-all}
        </style></head><body>
        <h1>\(code)</h1><p>\(title)</p><p><code>\(detail)</code></p>
        </body></html>
        """
    }

    private static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "cjs": "text/javascript; charset=utf-8",
        "jsx": "text/javascript; charset=utf-8",
        "ts": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "map": "application/json; charset=utf-8",
        "webmanifest": "application/manifest+json; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "avif": "image/avif",
        "ico": "image/x-icon",
        "bmp": "image/bmp",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "wasm": "application/wasm",
        "txt": "text/plain; charset=utf-8",
        "md": "text/plain; charset=utf-8",
        "xml": "application/xml; charset=utf-8",
        "pdf": "application/pdf",
        "mp4": "video/mp4",
        "webm": "video/webm",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "m4a": "audio/mp4",
        "zip": "application/zip",
    ]

    private static func mimeType(for ext: String) -> String {
        mimeTypes[ext.lowercased()] ?? "application/octet-stream"
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
