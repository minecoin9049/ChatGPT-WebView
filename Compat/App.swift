import UIKit
import WebKit
import SafariServices

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = BrowserController()
        window?.makeKeyAndVisible()
        return true
    }
}
final class BrowserController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private var browser: WKWebView!
    private var events = [String]()
    private var safariUA = false
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        if !UserDefaults.standard.bool(forKey: "diagnostics2Welcome") {
            UserDefaults.standard.set(true, forKey: "diagnostics2Welcome")
            let a = UIAlertController(title: "ChatGPT 测试版 0.2（2）", message: "请先尝试发送消息。若仍无反应，摇一摇手机，或用两根手指长按页面 1.5 秒，打开诊断菜单。报告仅保存在本次运行内，分享前可以查看。", preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "开始测试", style: .default))
            present(a, animated: true)
        }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        c.allowsInlineMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = []
        c.defaultWebpagePreferences.preferredContentMode = .mobile
        c.userContentController.add(self, name: "compatDiagnostics")
        c.userContentController.addUserScript(WKUserScript(source: Self.diagnostics, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        browser = WKWebView(frame: .zero, configuration: c)
        browser.translatesAutoresizingMaskIntoConstraints = false
        browser.uiDelegate = self
        browser.navigationDelegate = self
        browser.allowsBackForwardNavigationGestures = true
        view.addSubview(browser)
        NSLayoutConstraint.activate([
            browser.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            browser.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            browser.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        gesture.numberOfTouchesRequired = 2
        gesture.minimumPressDuration = 1.5
        gesture.cancelsTouchesInView = false
        view.addGestureRecognizer(gesture)
        browser.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
    }
    private func log(_ value: String) {
        events.append(String(value.prefix(1200)))
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              ["chatgpt.com", "chat.openai.com", "auth.openai.com", "auth0.openai.com"].contains(message.frameInfo.securityOrigin.host),
              let value = message.body as? String else { return }
        log(value)
    }
    @objc private func longPress(_ sender: UILongPressGestureRecognizer) {
        if sender.state == .began { showMenu() }
    }
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { showMenu() }
    }
    private func showMenu() {
        guard presentedViewController == nil else { return }
        let a = UIAlertController(title: "测试版 0.2（2）", message: "当前模式：" + (safariUA ? "真实系统版本的 Safari 标识" : "默认 WKWebView 标识"), preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: "查看诊断报告", style: .default) { [weak self] _ in self?.showReport() })
        a.addAction(UIAlertAction(title: "在应用内对比 Safari 视图", style: .default) { [weak self] _ in
            let c = SFSafariViewController.Configuration()
            c.barCollapsingEnabled = true
            let s = SFSafariViewController(url: URL(string: "https://chatgpt.com/")!, configuration: c)
            s.modalPresentationStyle = .fullScreen
            self?.present(s, animated: true)
        })
        a.addAction(UIAlertAction(title: safariUA ? "切回默认标识并重载" : "用真实 Safari 标识重载", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.safariUA.toggle()
            let version = UIDevice.current.systemVersion
            self.browser.customUserAgent = self.safariUA ? "Mozilla/5.0 (iPhone; CPU iPhone OS " + version.replacingOccurrences(of: ".", with: "_") + " like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/" + version + " Mobile/15E148 Safari/604.1" : nil
            self.log("Mode changed: " + (self.safariUA ? "Safari UA" : "WK default"))
            self.browser.reloadFromOrigin()
        })
        a.addAction(UIAlertAction(title: "重新加载", style: .default) { [weak self] _ in self?.browser.reloadFromOrigin() })
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.popoverPresentationController?.sourceView = view
        a.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(a, animated: true)
    }
    private func showReport() {
        browser.evaluateJavaScript("window.__compatSnapshot ? window.__compatSnapshot() : 'diagnostic script did not start'") { [weak self] result, error in
            guard let self = self else { return }
            if let value = result as? String { self.log(value) }
            if let error = error as NSError? { self.log("Snapshot error: " + error.domain + " " + String(error.code)) }
            let report = "ChatGPTCompat 0.2 (2)\niOS " + UIDevice.current.systemVersion + "\nMode: " + (self.safariUA ? "Safari UA" : "WK default") + "\n" + self.events.joined(separator: "\n")
            let controller = ReportController()
            controller.report = report
            self.present(UINavigationController(rootViewController: controller), animated: true)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { log("Navigation finished: " + (webView.url?.host ?? "?")) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { record(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { record(error) }
    private func record(_ error: Error) {
        let e = error as NSError
        log("Navigation error: " + e.domain + " " + String(e.code))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { log("Web content process terminated") }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }
    // No DOM text, input, cookies, response bodies or account data are collected.
    private static let diagnostics = #"""
    (function () {
        if (window.__compatSnapshot) return;
        function send(s) { try { window.webkit.messageHandlers.compatDiagnostics.postMessage(s); } catch (_) {} }
        function source(s) {
            try {
                var u = new URL(s, location.href);
                var name = u.pathname.split('/').pop();
                return u.hostname + (/^[a-zA-Z0-9_.-]+\.m?js$/.test(name) ? '/' + name : '/[path omitted]');
            } catch (_) { return '[source unavailable]'; }
        }
        function category(s) {
            s = String(s || '');
            var known = ['SyntaxError', 'TypeError', 'ReferenceError', 'Load failed', 'Failed to fetch', 'Importing a module', 'module specifier', 'regular expression', 'Invalid regular expression', 'Unexpected token', 'Script error', 'Content Security Policy', 'is not a function', 'is not defined', 'undefined is not an object', 'null is not an object'];
            var labels = known.filter(function (v) { return s.toLowerCase().indexOf(v.toLowerCase()) >= 0; });
            var api = ['requestIdleCallback','matchMedia','Segmenter','toSorted','toReversed','toSpliced','withResolvers','groupBy','CompressionStream','DecompressionStream','randomUUID','structuredClone','AbortSignal','replaceAll','findLast','ResizeObserver','IntersectionObserver','canParse'];
            api.forEach(function (v) { if (s.indexOf(v) >= 0) labels.push(v); });
            return labels.join(', ') || '[unclassified message omitted]';
        }
        addEventListener('error', function (e) {
            if (e.target && e.target !== window) {
                var t = e.target;
                if (t.tagName === 'SCRIPT' || t.tagName === 'LINK') send('Resource failure: ' + t.tagName + ' ' + source(t.src || t.href));
            } else send('JS error: ' + category(e.message) + ' @ ' + source(e.filename) + ':' + e.lineno + ':' + e.colno);
        }, true);
        addEventListener('unhandledrejection', function (e) { send('Promise error: ' + category(e.reason && (e.reason.name + ': ' + e.reason.message))); });
        addEventListener('securitypolicyviolation', function (e) { send('CSP: ' + e.violatedDirective + ' blocked ' + source(e.blockedURI)); });
        var f = {
            importMaps: !!(HTMLScriptElement.supports && HTMLScriptElement.supports('importmap')),
            idle: typeof requestIdleCallback, segmenter: typeof Intl.Segmenter,
            compression: typeof CompressionStream, decompression: typeof DecompressionStream,
            withResolvers: typeof Promise.withResolvers, groupBy: typeof Object.groupBy,
            toSorted: typeof Array.prototype.toSorted, toSpliced: typeof Array.prototype.toSpliced,
            findLast: typeof Array.prototype.findLast, clone: typeof structuredClone,
            abortAny: typeof AbortSignal.any, canParse: typeof URL.canParse,
            serviceWorker: 'serviceWorker' in navigator
        };
        try { new RegExp('(?<=a)b'); f.lookbehind = true; } catch (_) { f.lookbehind = false; }
        try { new RegExp('', 'v'); f.regexpV = true; } catch (_) { f.regexpV = false; }
        send('Features: ' + JSON.stringify(f));
        send('UA: ' + navigator.userAgent);
        window.__compatSnapshot = function () {
            return 'DOM: ' + JSON.stringify({
                ready: document.readyState, online: navigator.onLine,
                scripts: document.scripts.length,
                modules: document.querySelectorAll('script[type="module"]').length,
                importmaps: document.querySelectorAll('script[type="importmap"]').length,
                buttons: document.querySelectorAll('button').length,
                disabledButtons: document.querySelectorAll('button:disabled').length,
                editors: document.querySelectorAll('[contenteditable="true"],textarea').length
            });
        };
        addEventListener('DOMContentLoaded', function () { send(window.__compatSnapshot()); });
    })();
    """#
}
final class ReportController: UIViewController {
    var report = ""
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "诊断报告 · 0.2（2）"
        let text = UITextView(frame: .zero)
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.text = report
        view = text
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "分享", style: .plain, target: self, action: #selector(share))
    }
    @objc private func close() { dismiss(animated: true) }
    @objc private func share() {
        let c = UIActivityViewController(activityItems: [report], applicationActivities: nil)
        c.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(c, animated: true)
    }
}
