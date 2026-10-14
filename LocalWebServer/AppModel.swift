import Foundation
import SwiftUI
import Combine
import UIKit

@MainActor
final class AppModel: ObservableObject {

    @Published var status = ServerStatus()
    @Published var rootDisplayPath: String = ""
    @Published var usingExternalFolder = false
    @Published var showPicker = false
    @Published var showBrowser = false
    @Published var reloadToken = 0
    @Published var toast: String?
    @Published var allowLAN = false

    let server: LocalHTTPServer

    private let documentsURL: URL
    private var scopedURL: URL?
    private let bookmarkKey = "com.localweb.externalRootBookmark"
    private let lanKey = "com.localweb.allowLAN"

    var siteURL: URL? {
        guard status.running else { return nil }
        return URL(string: "http://127.0.0.1:\(status.port)/")
    }

    /// 同 Wi-Fi 下其他设备应该访问的地址，仅在开启局域网访问时有意义。
    var lanURLString: String? {
        guard status.running, allowLAN, let ip = NetworkInfo.wifiIPv4() else { return nil }
        return "http://\(ip):\(status.port)/"
    }

    // MARK: - Init

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        documentsURL = docs
        SampleSite.seedIfNeeded(into: docs)

        server = LocalHTTPServer(rootURL: docs)
        rootDisplayPath = "App 文件夹 · On My iPhone/LocalWeb"
        server.onStatus = { [weak self] newStatus in
            self?.status = newStatus
        }

        allowLAN = UserDefaults.standard.bool(forKey: lanKey)
        server.bindToLAN = allowLAN
    }

    func setAllowLAN(_ value: Bool) {
        allowLAN = value
        UserDefaults.standard.set(value, forKey: lanKey)
        server.setBindToLAN(value)
    }

    // MARK: - 生命周期

    func start() {
        server.start()
    }

    func restart() {
        server.restart()
    }

    func stop() {
        server.stop()
    }

    // MARK: - 目录切换

    func handlePickedFolder(_ url: URL) {
        let granted = url.startAccessingSecurityScopedResource()

        // 存书签，下次启动还能用
        if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        }

        releaseScopedResource()

        if granted { scopedURL = url }

        server.rootURL = url
        usingExternalFolder = true
        rootDisplayPath = url.path
        showToast("已切换到：\(url.lastPathComponent)")
        server.restart()
    }

    func restoreExternalRootIfPossible() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        releaseScopedResource()
        scopedURL = url
        server.rootURL = url
        usingExternalFolder = true
        rootDisplayPath = url.path
    }

    func resetToAppFolder() {
        releaseScopedResource()
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        SampleSite.seedIfNeeded(into: documentsURL)
        server.rootURL = documentsURL
        usingExternalFolder = false
        rootDisplayPath = "App 文件夹 · On My iPhone/LocalWeb"
        showToast("已恢复为 App 文件夹")
        server.restart()
    }

    private func releaseScopedResource() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    // MARK: - 动作

    func openInSafari() {
        guard let siteURL else { return }
        UIApplication.shared.open(siteURL)
    }

    func copyAddress() {
        guard let siteURL else { return }
        UIPasteboard.general.string = siteURL.absoluteString
        showToast("已复制 \(siteURL.absoluteString)")
    }

    /// 跳到「文件」App 里本 App 的文件夹，方便把前端文件拷进去。
    func revealInFiles() {
        guard let url = URL(string: "shareddocuments://") else { return }
        UIApplication.shared.open(url)
    }

    func bumpReload() {
        reloadToken += 1
    }

    private func showToast(_ text: String) {
        toast = text
        let snapshot = text
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if self.toast == snapshot { self.toast = nil }
        }
    }
}

// MARK: - 取本机 Wi-Fi 地址

enum NetworkInfo {

    /// 当前 Wi-Fi（en0）的 IPv4 地址，取不到返回 nil。
    static func wifiIPv4() -> String? {
        var result: String?
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else { return nil }
        defer { freeifaddrs(ifaddrPointer) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            defer { cursor = interface.ifa_next }

            guard let addr = interface.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard String(cString: interface.ifa_name) == "en0" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(addr,
                                     socklen_t(addr.pointee.sa_len),
                                     &host, socklen_t(host.count),
                                     nil, 0,
                                     NI_NUMERICHOST)
            if status == 0 {
                result = String(cString: host)
            }
        }
        return result
    }
}

// MARK: - 首次启动写入一个示例站点，用来验证模块 / fetch 是否正常

enum SampleSite {

    private static let marker = ".localweb-seeded"

    static func seedIfNeeded(into docs: URL) {
        let fm = FileManager.default
        let index = docs.appendingPathComponent("index.html")
        let markerURL = docs.appendingPathComponent(marker)

        guard !fm.fileExists(atPath: index.path),
              !fm.fileExists(atPath: markerURL.path) else { return }

        for (name, content) in files {
            let url = docs.appendingPathComponent(name)
            try? content.data(using: .utf8)?.write(to: url)
        }
        try? Data().write(to: markerURL)
    }

    private static let files: [(String, String)] = [
        ("index.html", #"""
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>LocalWeb 示例</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
  <main>
    <h1>本地服务器跑起来了 🎉</h1>
    <p class="sub">这一页是通过 <code>http://127.0.0.1</code> 加载的，不是 <code>file://</code>。</p>

    <section class="card">
      <h2>ES Module 导入</h2>
      <p id="module-out">加载中…</p>
    </section>

    <section class="card">
      <h2>fetch 本地 JSON</h2>
      <p id="fetch-out">加载中…</p>
    </section>

    <section class="card">
      <h2>说明</h2>
      <p class="hint">把你的 <code>index.html</code> 和 js 文件放进「文件」App 里的
      <b>On My iPhone → LocalWeb</b> 文件夹，然后回到本 App 点「打开页面」即可。</p>
    </section>
  </main>
  <script type="module" src="app.js"></script>
</body>
</html>
"""#),

        ("style.css", #"""
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body {
  margin: 0;
  font: -apple-system-body, system-ui, -apple-system, sans-serif;
  background: #f2f3f7;
  color: #14161a;
  -webkit-text-size-adjust: 100%;
}
main { padding: 28px 18px 48px; max-width: 720px; margin: 0 auto; }
h1 { font-size: 26px; line-height: 1.25; margin: 0 0 8px; }
.sub { color: #666; margin: 0 0 22px; font-size: 15px; }
.card {
  background: #fff;
  border-radius: 16px;
  padding: 18px;
  margin-bottom: 14px;
  box-shadow: 0 1px 2px rgba(0,0,0,.06), 0 8px 24px rgba(0,0,0,.04);
}
.card h2 { font-size: 15px; margin: 0 0 10px; color: #0a63ff; letter-spacing: .02em; }
.card p { margin: 0; font-size: 15px; line-height: 1.6; }
.hint { color: #555; }
code {
  font-family: ui-monospace, Menlo, monospace;
  font-size: 13px;
  background: rgba(10,99,255,.08);
  padding: 2px 5px;
  border-radius: 5px;
}
.ok { color: #0a8f3c; font-weight: 600; }
.bad { color: #d33; font-weight: 600; }
@media (prefers-color-scheme: dark) {
  body { background: #0f1115; color: #f2f3f7; }
  .card { background: #1a1d23; box-shadow: none; }
  .sub, .hint { color: #9aa1ad; }
}
"""#),

        ("utils.js", #"""
export function greet(name) {
  return `你好，${name}！这段文字由 utils.js 的 ES Module 导出。`;
}

export function now() {
  return new Date().toLocaleString('zh-CN');
}
"""#),

        ("app.js", #"""
import { greet, now } from './utils.js';

const moduleOut = document.getElementById('module-out');
moduleOut.innerHTML = `<span class="ok">✓</span> ${greet('LocalWeb')}<br><small>模块加载时间：${now()}</small>`;

const fetchOut = document.getElementById('fetch-out');
try {
  const res = await fetch('./data.json', { cache: 'no-store' });
  const data = await res.json();
  fetchOut.innerHTML = `<span class="ok">✓</span> 读到 ${data.items.length} 条数据：`
    + data.items.map(i => i.name).join('、');
} catch (err) {
  fetchOut.innerHTML = `<span class="bad">✗</span> fetch 失败：${err.message}`;
}

console.log('[LocalWeb] app.js 执行完成');
"""#),

        ("data.json", #"""
{
  "items": [
    { "id": 1, "name": "index.html" },
    { "id": 2, "name": "app.js" },
    { "id": 3, "name": "utils.js" },
    { "id": 4, "name": "data.json" }
  ]
}
"""#),
    ]
}
