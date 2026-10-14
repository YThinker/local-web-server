import SwiftUI
import WebKit

/// 把 WKWebView 包成 SwiftUI 视图。
/// 页面从 http://127.0.0.1:<port>/ 加载，所以 ES Module / fetch / CORS 全部正常。
struct BrowserView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        if #available(iOS 14.0, *) {
            config.defaultWebpagePreferences.preferredContentMode = .mobile
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 通过 .id() 强制重建来刷新，这里不做增量更新。
    }
}
