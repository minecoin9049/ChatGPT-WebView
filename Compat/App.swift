import UIKit
import WebKit
import SafariServices
import Network

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
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
final class BrowserController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    private var browser: WKWebView!
    private var events = [String]()
    private let cacheQueue = DispatchQueue(label: "chat.offline.cache", qos: .utility)
    private let cache = ChatCache(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OfflineChats", isDirectory: true))
    private let monitor = NWPathMonitor()
    private var isOnline = true
    private var loadFailed = false
    private var needsRecovery = false
    private var crashTimes: [Date] = []
    private var logoutPending = false
    private var cacheEnabled: Bool { !UserDefaults.standard.bool(forKey: "offlineCacheDisabled") }
    private let banner = UIButton(type: .system)
    private var bannerHeight: NSLayoutConstraint!
    private var observations: [NSObjectProtocol] = []
    private var downloadFiles: [ObjectIdentifier: URL] = [:]
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        let handler = WeakScriptHandler(self)
        config.userContentController.add(handler, name: "compatDiagnostics")
        config.userContentController.add(handler, name: "mobileShell")
        config.userContentController.addUserScript(WKUserScript(source: Self.diagnostics, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let path = Bundle.main.url(forResource: "Mobile", withExtension: "js"), let script = try? String(contentsOf: path) {
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.userContentController.addUserScript(WKUserScript(source: "window.__setChatCacheEnabled && window.__setChatCacheEnabled(" + (cacheEnabled ? "true" : "false") + ");", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        browser = WKWebView(frame: .zero, configuration: config)
        // This is the exact UA variant confirmed working on the user's iOS 16.1.1 device.
        let version = UIDevice.current.systemVersion
        browser.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS " + version.replacingOccurrences(of: ".", with: "_") + " like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/" + version + " Mobile/15E148 Safari/604.1"
        browser.translatesAutoresizingMaskIntoConstraints = false
        browser.uiDelegate = self
        browser.navigationDelegate = self
        browser.allowsBackForwardNavigationGestures = false
        browser.scrollView.keyboardDismissMode = .interactive
        browser.scrollView.contentInsetAdjustmentBehavior = .never
        browser.scrollView.bounces = false
        browser.scrollView.alwaysBounceHorizontal = false
        browser.scrollView.delaysContentTouches = false
        browser.backgroundColor = .systemBackground
        browser.isOpaque = false
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        banner.backgroundColor = .secondarySystemBackground
        banner.addTarget(self, action: #selector(showMenu), for: .touchUpInside)
        banner.clipsToBounds = true
        view.addSubview(banner)
        view.addSubview(browser)
        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor), bannerHeight,
            browser.topAnchor.constraint(equalTo: banner.bottomAnchor),
            browser.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            browser.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        gesture.numberOfTouchesRequired = 2
        gesture.minimumPressDuration = 1.5
        gesture.cancelsTouchesInView = false
        view.addGestureRecognizer(gesture)
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isOnline = path.status == .satisfied
                self?.updateBanner()
                // Never reload a working/streaming chat merely because the network changed.
            }
        }
        monitor.start(queue: DispatchQueue(label: "chat.network"))
        observations.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.browser.evaluateJavaScript("window.__captureChatCache && window.__captureChatCache()", completionHandler: nil)
        })
        observations.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if self.needsRecovery { self.recover() }
        })
        cacheQueue.async { [weak self] in _ = try? self?.cache.list() }
        let saved = UserDefaults.standard.string(forKey: "lastChatID") ?? ""
        let age = Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "lastChatAt")
        if UUID(uuidString: saved) != nil && age < 7 * 86400 {
            openChat(saved)
        } else { loadHome() }
    }
    deinit {
        monitor.cancel()
        for item in observations { NotificationCenter.default.removeObserver(item) }
    }
    private func loadHome() { browser.load(URLRequest(url: URL(string: "https://chatgpt.com/")!, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 45)) }
    private func openChat(_ id: String) {
        guard UUID(uuidString: id) != nil else { return }
        browser.load(URLRequest(url: URL(string: "https://chatgpt.com/c/" + id)!, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 45))
    }
    private func updateBanner() {
        let show = !isOnline || loadFailed
        bannerHeight.constant = show ? 34 : 0
        banner.isHidden = !show
        banner.setTitle(!isOnline ? "当前离线 · 点击查看缓存聊天" : "页面加载失败 · 点击重试或查看缓存", for: .normal)
    }
    private func log(_ value: String) {
        events.append(String(value.prefix(1200)))
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "https" else { return }
        let host = message.frameInfo.securityOrigin.host
        if message.name == "compatDiagnostics", ["chatgpt.com", "chat.openai.com", "auth.openai.com", "auth0.openai.com"].contains(host), let value = message.body as? String {
            log(value); return
        }
        guard message.name == "mobileShell", host == "chatgpt.com", let payload = message.body as? [String: Any], let kind = payload["kind"] as? String else { return }
        if kind == "theme", let dark = payload["dark"] as? Bool {
            overrideUserInterfaceStyle = dark ? .dark : .light
            setNeedsStatusBarAppearanceUpdate()
            return
        }
        if kind == "logout" { clearForLogout(); return }
        if kind == "route", !logoutPending {
            let id = payload["id"] as? String ?? ""
            if UUID(uuidString: id) != nil {
                UserDefaults.standard.set(id, forKey: "lastChatID")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastChatAt")
            } else { UserDefaults.standard.removeObject(forKey: "lastChatID") }
            return
        }
        guard kind == "snapshot", cacheEnabled, !logoutPending,
              let id = payload["id"] as? String, UUID(uuidString: id) != nil,
              browser.url?.path.lowercased() == "/c/" + id.lowercased(),
              !(URLComponents(url: browser.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "temporary-chat" && $0.value == "true" }) ?? false),
              let title = payload["title"] as? String,
              let values = payload["messages"] as? [[String: Any]], values.count <= 80 else { return }
        let messages = values.compactMap { value -> CachedMessage? in
            guard let role = value["role"] as? String, let text = value["text"] as? String,
                  ["user", "assistant"].contains(role), text.count <= 12000 else { return nil }
            return CachedMessage(role: role, text: text)
        }
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            do { try self.cache.save(id: id, title: title, messages: messages) }
            catch { DispatchQueue.main.async { self.log("Offline cache write unavailable") } }
        }
    }
    private func clearForLogout() {
        logoutPending = true
        UserDefaults.standard.removeObject(forKey: "lastChatID")
        cacheQueue.async { [weak self] in try? self?.cache.clear() }
    }
    @objc private func longPress(_ sender: UILongPressGestureRecognizer) { if sender.state == .began { showMenu() } }
    // Shake-to-open was a diagnostic shortcut; remove it to restore normal editing behavior.
    @objc private func showMenu() {
        guard presentedViewController == nil else { return }
        let a = UIAlertController(title: "ChatGPT · 0.3（3）", message: "自动保存最近 20 个聊天已加载的文字，最多 7 天、10 MB。两指长按可打开此菜单。", preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: "离线聊天", style: .default) { [weak self] _ in self?.showOffline() })
        a.addAction(UIAlertAction(title: cacheEnabled ? "关闭自动离线缓存" : "开启自动离线缓存", style: .default) { [weak self] _ in self?.toggleCache() })
        a.addAction(UIAlertAction(title: "清空离线副本", style: .destructive) { [weak self] _ in self?.confirmClear() })
        a.addAction(UIAlertAction(title: "重新加载页面", style: .default) { [weak self] _ in self?.browser.reload() })
        a.addAction(UIAlertAction(title: "查看诊断报告", style: .default) { [weak self] _ in self?.showReport() })
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.popoverPresentationController?.sourceView = view
        a.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(a, animated: true)
    }
    private func toggleCache() {
        let newValue = !cacheEnabled
        UserDefaults.standard.set(!newValue, forKey: "offlineCacheDisabled")
        browser.evaluateJavaScript("window.__setChatCacheEnabled && window.__setChatCacheEnabled(" + (newValue ? "true" : "false") + ")", completionHandler: nil)
        // Native validation also gates future navigations, even before script settings apply.
        if !newValue { cacheQueue.async { [weak self] in try? self?.cache.clear() } }
    }
    private func confirmClear() {
        let a = UIAlertController(title: "清空离线副本？", message: "只删除本机副本，不影响服务器上的聊天。自动缓存开启时，之后打开的聊天会重新保存。", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            self?.cacheQueue.async { [weak self] in try? self?.cache.clear() }
        })
        present(a, animated: true)
    }
    private func showOffline() {
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let records = try self.cache.list()
                DispatchQueue.main.async {
                    let list = OfflineController(style: .insetGrouped)
                    list.chats = records
                    list.openOnline = { [weak self] id in self?.openChat(id) }
                    self.present(UINavigationController(rootViewController: list), animated: true)
                }
            } catch { DispatchQueue.main.async { self.showError("暂时无法读取离线副本，请解锁设备后重试。") } }
        }
    }
    private func showError(_ text: String) {
        guard presentedViewController == nil else { return }
        let a = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }
    private func showReport() {
        browser.evaluateJavaScript("window.__compatSnapshot ? window.__compatSnapshot() : 'diagnostic script did not start'") { [weak self] result, error in
            guard let self = self else { return }
            if let value = result as? String { self.log(value) }
            if let error = error as NSError? { self.log("Snapshot error: " + error.domain + " " + String(error.code)) }
            let controller = ReportController()
            controller.report = "ChatGPTCompat 0.3 (3)\niOS " + UIDevice.current.systemVersion + "\nMode: confirmed Safari UA\nCache: " + (self.cacheEnabled ? "on" : "off") + "\n" + self.events.joined(separator: "\n")
            self.present(UINavigationController(rootViewController: controller), animated: true)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("Navigation finished: " + (webView.url?.host ?? "?"))
        loadFailed = false; needsRecovery = false; updateBanner()
        if webView.url?.host == "chatgpt.com" {
            logoutPending = false
            webView.evaluateJavaScript("window.__setChatCacheEnabled && window.__setChatCacheEnabled(" + (cacheEnabled ? "true" : "false") + ")", completionHandler: nil)
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { record(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { record(error) }
    private func record(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        log("Navigation error: " + e.domain + " " + String(e.code))
        loadFailed = true; updateBanner()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("Web content process terminated")
        needsRecovery = true
        if UIApplication.shared.applicationState == .active { recover() }
    }
    private func recover() {
        crashTimes = crashTimes.filter { Date().timeIntervalSince($0) < 300 }
        guard crashTimes.count < 2 else { needsRecovery = false; loadFailed = true; updateBanner(); return }
        crashTimes.append(Date())
        needsRecovery = false
        browser.reload() // Reload GET only; never replay a message submission.
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        if ["chatgpt.com", "chat.openai.com", "auth.openai.com", "auth0.openai.com"].contains(url.host ?? ""),
           url.path.lowercased().contains("logout") || url.path.lowercased().contains("signout") { clearForLogout() }
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["mailto", "tel"].contains(scheme), navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
            UIApplication.shared.open(url); return
        }
        // Keep login redirects in the existing cookie store. Only tapped external articles open separately.
        let internalHosts = ["chatgpt.com", "chat.openai.com", "auth.openai.com", "auth0.openai.com", "accounts.google.com", "appleid.apple.com", "login.microsoftonline.com", "login.live.com"]
        if navigationAction.navigationType == .linkActivated, ["https", "http"].contains(scheme),
           !internalHosts.contains(url.host ?? ""), presentedViewController == nil {
            decisionHandler(.cancel)
            let s = SFSafariViewController(url: url)
            present(s, animated: true); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            let name = String((suggestedFilename as NSString).lastPathComponent.prefix(160))
            let file = folder.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "download" : name)
            downloadFiles[ObjectIdentifier(download)] = file
            completionHandler(file)
        } catch { completionHandler(nil); showError("无法保存文件，请检查剩余空间。") }
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloadFiles.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = view
        share.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        if presentedViewController == nil { present(share, animated: true) }
        else { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()); showError("请关闭当前弹窗后重试下载。") }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let file = downloadFiles.removeValue(forKey: ObjectIdentifier(download)) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        showError("下载失败，请检查网络后重试。")
    }
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
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
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
        title = "诊断报告 · 0.3（3）"
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

