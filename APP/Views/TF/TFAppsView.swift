import SwiftUI
import WebKit
import Foundation

@MainActor
class WebCacheManager: ObservableObject, @unchecked Sendable {
    static let shared = WebCacheManager()

    private let cacheDirectory: URL
    private let cacheExpirationTime: TimeInterval = 30 * 60

    private init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        cacheDirectory = documentsPath.appendingPathComponent("WebCache")

        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func cacheFilePath(for url: URL) -> URL {
        let fileName = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? "default"
        return cacheDirectory.appendingPathComponent("\(fileName).html")
    }

    private func timestampFilePath(for url: URL) -> URL {
        let fileName = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? "default"
        return cacheDirectory.appendingPathComponent("\(fileName).timestamp")
    }

    func isCacheValid(for url: URL) -> Bool {
        let timestampFile = timestampFilePath(for: url)

        guard let timestampData = try? Data(contentsOf: timestampFile),
              let timestamp = try? JSONDecoder().decode(Date.self, from: timestampData) else {
            return false
        }

        return Date().timeIntervalSince(timestamp) < cacheExpirationTime
    }

    func getCachedContent(for url: URL) -> String? {
        let cacheFile = cacheFilePath(for: url)

        guard isCacheValid(for: url),
              let content = try? String(contentsOf: cacheFile, encoding: .utf8) else {
            return nil
        }

        return content
    }

    func saveCachedContent(_ content: String, for url: URL) {
        let cacheFile = cacheFilePath(for: url)
        let timestampFile = timestampFilePath(for: url)

        do {
            try content.write(to: cacheFile, atomically: true, encoding: .utf8)

            let timestamp = Date()
            let timestampData = try JSONEncoder().encode(timestamp)
            try timestampData.write(to: timestampFile)

        } catch {

        }
    }

    func clearCache() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            for file in files {
                try FileManager.default.removeItem(at: file)
            }

        } catch {

        }
    }

    func getCacheSize() -> String {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])
            let totalSize = files.reduce(0) { total, file in
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return total + size
            }

            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: Int64(totalSize))
        } catch {
            return "0 KB"
        }
    }
}

func isAdUrl(_ urlString: String) -> Bool {

    let adDomains = [
        "googleads.g.doubleclick.net",
        "googlesyndication.com",
        "doubleclick.net",
        "amazon-adsystem.com",
        "facebook.com/tr",
        "connect.facebook.net/tr",
        "twitter.com/i/adsct",
        "ads-twitter.com",
        "baidu.com/afp",
        "cpro.baidu.com",
        "sogou.com/ads",
        "ads.sogou.com",
        "googletagmanager.com/gtag/js",
        "googletagservices.com",
        "google-analytics.com/analytics.js",
        "analytics.google.com",
        "adnxs.com",
        "adsrvr.org"
    ]

    return adDomains.contains { domain in
        urlString.lowercased().contains(domain.lowercased())
    }
}

struct TFAppsView: View {
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var webView: WKWebView?
    @State private var adBlockCount = 0
    @State private var hasCachedContent = false
    @State private var cacheTimestamp: Date?
    private let url = URL(string: "https://departures.to/apps")!
    private let cacheManager = WebCacheManager.shared

    var body: some View {
        ZStack {

            if let errorMessage = errorMessage {

                VStack(spacing: 20) {
                    Spacer()

                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.orange)

                    Text("加载失败")
                        .font(.system(size: 22, weight: .semibold))

                    Text(errorMessage)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button("重试") {
                        self.errorMessage = nil
                        self.isLoading = true
                        self.webView?.reload()
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()
                }
                .background(Color(.systemBackground))
            } else {

                WebViewRepresentable(
                    url: url,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage,
                    webView: $webView,
                    adBlockCount: $adBlockCount,
                    hasCachedContent: $hasCachedContent,
                    cacheTimestamp: $cacheTimestamp
                )
                .ignoresSafeArea(.all, edges: .all)
                .overlay(
                    Group {
                        if isLoading && !hasCachedContent {

                            VStack {
                                ProgressView()
                                    .scaleEffect(1.5)
                                Text("正在加载...")
                                    .font(.headline)
                                    .padding(.top, 16)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(.systemBackground).opacity(0.9))
                        }
                    }
                )
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            checkCacheStatus()
        }
    }

    private func checkCacheStatus() {
        hasCachedContent = cacheManager.isCacheValid(for: url)
        if hasCachedContent {

        }
    }

}

struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    @Binding var webView: WKWebView?
    @Binding var adBlockCount: Int
    @Binding var hasCachedContent: Bool
    @Binding var cacheTimestamp: Date?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let adBlockScript = WKUserScript(
            source: getAdBlockScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(adBlockScript)

        configuration.userContentController.add(context.coordinator, name: "adBlocker")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor.systemBackground

        DispatchQueue.main.async {
            self.webView = webView
        }

        return webView
    }

    private func getAdBlockScript() -> String {
        return """
        (function() {
            const adSelectors = [
                '.ads',
                '.advertisement',
                '.ad-banner',
                '.ad-container',
                '.ad-wrapper',
                '.advertisement-container',
                '.banner-ad',
                '.popup-ad',
                '.modal-ad',
                '.sidebar-ad',
                '.header-ad',
                '.footer-ad',
                '.google-ads',
                '.google-ad',
                '.doubleclick',
                '.amazon-ads',
                '.facebook-ad',
                '.twitter-ad',
                '[data-ad]',
                '[data-advertisement]',
                '[data-banner]',
                '.fb-ad',
                '.twitter-ad',
                '.instagram-ad',
                '.video-ad',
                '.pre-roll-ad',
                '.mid-roll-ad',
                '.post-roll-ad'
            ];

            function removeAds() {
                adSelectors.forEach(selector => {
                    try {
                        const elements = document.querySelectorAll(selector);
                        elements.forEach(element => {
                            if (isDefinitelyAd(element)) {
                                element.style.display = 'none';
                                element.remove();
                                window.webkit.messageHandlers.adBlocker.postMessage({
                                    type: 'ad_blocked',
                                    selector: selector,
                                    text: (element.textContent || '').substring(0, 50)
                                });
                            }
                        });
                    } catch (e) {
                    }
                });
            }

            function isDefinitelyAd(element) {
                const text = element.textContent || '';
                const className = element.className || '';
                const id = element.id || '';
                const src = element.src || '';
                const href = element.href || '';

                const adKeywords = [
                    'advertisement', 'sponsored', 'promotion',
                    'click here', 'download now', 'install now',
                    'banner ad', 'popup ad', 'modal ad'
                ];

                const lowerText = text.toLowerCase();
                const hasAdText = adKeywords.some(keyword => lowerText.includes(keyword));

                const hasAdUrl = isAdUrl(src) || isAdUrl(href);

                const rect = element.getBoundingClientRect();
                const isAdSize = (rect.width === 728 && rect.height === 90) ||
                                (rect.width === 300 && rect.height === 250) ||
                                (rect.width === 160 && rect.height === 600);

                return (hasAdText || hasAdUrl) && !isImportantElement(element);
            }

            function isImportantElement(element) {
                const importantSelectors = [
                    'nav', 'header', 'footer', 'main', 'section', 'article',
                    '.navigation', '.header', '.footer', '.main', '.content',
                    '.menu', '.sidebar', '.toolbar', '.button', '.link',
                    'button', 'a', 'input', 'select', 'textarea'
                ];

                return importantSelectors.some(selector => {
                    return element.matches && element.matches(selector);
                });
            }

            const originalFetch = window.fetch;
            window.fetch = function(...args) {
                const url = args[0];
                if (typeof url === 'string' && isAdUrl(url)) {
                    window.webkit.messageHandlers.adBlocker.postMessage({
                        type: 'fetch_blocked',
                        url: url
                    });
                    return Promise.reject(new Error('Ad blocked'));
                }
                return originalFetch.apply(this, args);
            };

            function isAdUrl(url) {
                const adDomains = [
                    'googleads.g.doubleclick.net',
                    'googlesyndication.com',
                    'doubleclick.net',
                    'amazon-adsystem.com',
                    'facebook.com/tr',
                    'connect.facebook.net/tr',
                    'twitter.com/i/adsct',
                    'ads-twitter.com',
                    'baidu.com/afp',
                    'cpro.baidu.com',
                    'sogou.com/ads',
                    'ads.sogou.com',
                    'googletagmanager.com/gtag/js',
                    'googletagservices.com',
                    'google-analytics.com/analytics.js',
                    'analytics.google.com',
                    'adnxs.com',
                    'adsrvr.org'
                ];

                return adDomains.some(domain => url.toLowerCase().includes(domain.toLowerCase()));
            }

            setTimeout(() => {
                removeAds();

                const observer = new MutationObserver(() => {
                    setTimeout(removeAds, 100);
                });
                observer.observe(document.body, {
                    childList: true,
                    subtree: true
                });

                console.log('🛡️ 精确广告拦截器已启动');
            }, 1000);
        })();
        """
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url == nil {

            let cacheManager = WebCacheManager.shared
            if let cachedContent = cacheManager.getCachedContent(for: url) {

                DispatchQueue.main.async {
                    self.hasCachedContent = true
                    self.cacheTimestamp = Date()
                }
                webView.loadHTMLString(cachedContent, baseURL: url)
            } else {

                var request = URLRequest(url: url)
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 30
                webView.load(request)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: WebViewRepresentable

        init(_ parent: WebViewRepresentable) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "adBlocker" {

                DispatchQueue.main.async {
                    self.parent.adBlockCount += 1
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {

            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.errorMessage = nil
            }
        }

                func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {

                    DispatchQueue.main.async {
                        self.parent.isLoading = false
                    }

                    webView.evaluateJavaScript("document.documentElement.outerHTML") { result, error in
                        if let htmlContent = result as? String {
                            let cacheManager = WebCacheManager.shared
                            cacheManager.saveCachedContent(htmlContent, for: self.parent.url)
                        }
                    }
                }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {

            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.errorMessage = "网页加载失败: \(error.localizedDescription)"
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {

            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.errorMessage = "无法连接到服务器: \(error.localizedDescription)"
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let urlString = navigationAction.request.url?.absoluteString ?? ""

            if isAdUrl(urlString) {

                DispatchQueue.main.async {
                    self.parent.adBlockCount += 1
                }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

    }
}

#Preview {
    NavigationView {
        TFAppsView()
    }
}
