import AppKit
import Foundation
import Darwin
import WebKit

final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSToolbarDelegate, NSToolbarItemValidation {
    let paths = LauncherPaths()
    var base: URL { paths.base }
    var installation: RuntimeInstallation?
    var setupProcess: Process?
    var setupWasCancelled = false
    var resolvingRuntime = false
    var setupButton: NSButton!
    var bun: String { installation?.bun.path ?? "" }
    var cli: String { installation?.cli.path ?? "" }
    let viewer = URL(string: "http://127.0.0.1:8898")!
    var webWindow: NSWindow?
    var webView: WKWebView?
    var popupWindows: [ObjectIdentifier: NSWindow] = [:]
    var activeDownloads: [ObjectIdentifier: WKDownload] = [:]
    var webObservations: [NSKeyValueObservation] = []
    var window: NSWindow!
    var status: NSTextField!
    var browserButton: NSButton!
    var portButton: NSButton!
    var child: Process?
    var logURL: URL?
    var output: FileHandle?
    var ready = false
    var starting = false
    var stopping = false
    var probeTimer: Timer?
    var probeBusy = false
    var deadline = Date()
    let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.timeoutIntervalForResource = 6
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenus()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 245), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Delegatus — Керування"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        let title = NSTextField(labelWithString: "Delegatus")
        title.font = .boldSystemFont(ofSize: 27)
        title.frame = NSRect(x: 26, y: 187, width: 510, height: 35)
        window.contentView!.addSubview(title)
        setupButton = NSButton(title: "Налаштувати", target: self, action: #selector(configureRuntime))
        setupButton.frame = NSRect(x: 425, y: 185, width: 170, height: 34)
        setupButton.bezelStyle = .rounded
        window.contentView!.addSubview(setupButton)
        status = NSTextField(wrappingLabelWithString: "Перевіряю локальний сервер…")
        status.frame = NSRect(x: 26, y: 82, width: 568, height: 94)
        status.font = .systemFont(ofSize: 14)
        window.contentView!.addSubview(status)
        browserButton = NSButton(title: "Відкрити Delegatus", target: self, action: #selector(openBrowser))
        browserButton.frame = NSRect(x: 22, y: 25, width: 180, height: 34)
        browserButton.bezelStyle = .rounded
        browserButton.isEnabled = false
        window.contentView!.addSubview(browserButton)
        let logs = NSButton(title: "Журнал", target: self, action: #selector(openLog))
        logs.frame = NSRect(x: 210, y: 25, width: 105, height: 34)
        logs.bezelStyle = .rounded
        window.contentView!.addSubview(logs)
        portButton = NSButton(title: "Звільнити порт", target: self, action: #selector(freePort))
        portButton.frame = NSRect(x: 320, y: 25, width: 145, height: 34)
        portButton.bezelStyle = .rounded
        portButton.isEnabled = false
        window.contentView!.addSubview(portButton)
        let quit = NSButton(title: "Завершити", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.frame = NSRect(x: 475, y: 25, width: 120, height: 34)
        quit.bezelStyle = .rounded
        window.contentView!.addSubview(quit)
        showWindow()
        makeLog()
        guard logURL != nil else { return }
        writeLog("Delegatus community launcher 2.0\n")
        beginLaunch()
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if ready { openBrowser() } else { showWindow() }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func makeLog() {
        do {
            let logs = base.appendingPathComponent("Logs", isDirectory: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let name = "launch-\(formatter.string(from: Date()))-\(ProcessInfo.processInfo.processIdentifier).log"
            let url = logs.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw NSError(domain: "DelegatusLauncher", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не вдалося створити журнал у папці користувача."])
            }
            output = try FileHandle(forWritingTo: url)
            logURL = url
        } catch { fail("Не вдалося відкрити журнал: \(error.localizedDescription)") }
    }
    func writeLog(_ message: String) { try? output?.write(contentsOf: Data(message.utf8)) }
    func checkViewer(_ completion: @escaping (Bool, Bool) -> Void) {
        var request = URLRequest(url: viewer)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        session.dataTask(with: request) { data, response, error in
            let occupied = response != nil || ((try? self.listeners().isEmpty) == false)
            guard error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == self.viewer.host, http.url?.port == self.viewer.port,
                  let data = data, let html = String(data: data, encoding: .utf8),
                  html.localizedCaseInsensitiveContains("Delegatus"),
                  let expression = try? NSRegularExpression(pattern: #"src=["']([^"']+\.js(?:\?[^"']*)?)["']"#),
                  let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html),
                  let scriptURL = URL(string: String(html[range]).replacingOccurrences(of: "&amp;", with: "&"), relativeTo: self.viewer)?.absoluteURL,
                  scriptURL.host == self.viewer.host, scriptURL.port == self.viewer.port else {
                DispatchQueue.main.async { completion(false, occupied) }
                return
            }
            self.session.dataTask(with: scriptURL) { data, response, error in
                let valid = error == nil && (response as? HTTPURLResponse)?.statusCode == 200 && !(data?.isEmpty ?? true)
                DispatchQueue.main.async { completion(valid, true) }
            }.resume()
        }.resume()
    }
    func beginLaunch() {
        guard !starting, setupProcess?.isRunning != true else { return }
        checkViewer { healthy, occupied in
            if healthy { self.becameReady(reused: true) }
            else if occupied { self.portButton.isEnabled = true; self.fail("Порт 8898 зайнятий. Натисніть «Звільнити порт», щоб переглянути процес і повторити запуск.") }
            else { self.startServer() }
        }
    }
    func startServer() {
        guard !starting, !resolvingRuntime, !stopping, setupProcess?.isRunning != true else { return }
        resolvingRuntime = true
        status.stringValue = "Шукаю Bun і Delegatus…"
        let settings = LauncherSettings.load(from: paths.settings)
        DispatchQueue.global().async {
            let result = RuntimeLocator(paths: self.paths).discover(settings: settings)
            DispatchQueue.main.async {
                self.resolvingRuntime = false
                guard !self.stopping else { return }
                guard let runtime = result.installation else {
                    self.status.stringValue = result.issue
                    self.showWindow()
                    self.configureRuntime()
                    return
                }
                self.installation = runtime
                self.launchResolvedServer()
            }
        }
    }
    func launchResolvedServer() {
        stopping = false
        ready = false
        probeBusy = false
        portButton.isEnabled = false
        guard FileManager.default.isExecutableFile(atPath: bun) else { fail("Не знайдено Bun: \(bun)"); return }
        guard FileManager.default.fileExists(atPath: cli) else { fail("Не знайдено встановлену програму Delegatus: \(cli)"); return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bun)
        process.arguments = [cli, "--port", "8898", "--hostname", "127.0.0.1", "--no-open"]
        process.currentDirectoryURL = base
        process.environment = RuntimeLocator(paths: paths).processEnvironment(bun: installation?.bun)
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { process in
            DispatchQueue.main.async {
                self.probeTimer?.invalidate()
                guard !self.stopping else { return }
                self.starting = false
                self.fail("Delegatus завершив роботу (код \(process.terminationStatus)). Деталі збережено в журналі.")
            }
        }
        child = process
        writeLog("Command: \(bun) \(process.arguments!.joined(separator: " "))\n")
        do { try process.run() }
        catch { fail("Не вдалося запустити Delegatus: \(error.localizedDescription)"); return }
        starting = true
        status.stringValue = "Запускаю Delegatus…\nПерше відкриття може тривати до 90 секунд."
        deadline = Date().addingTimeInterval(90)
        probeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            guard !self.probeBusy else { return }
            guard Date() < self.deadline else {
                self.probeTimer?.invalidate()
                self.starting = false
                if process.isRunning { self.stopping = true; process.terminate() }
                self.fail("Сервер не став готовим за 90 секунд. Відкрийте журнал, щоб побачити причину.")
                return
            }
            self.probeBusy = true
            self.checkViewer { healthy, _ in
                self.probeBusy = false
                guard self.starting, process.isRunning else { return }
                if healthy { self.becameReady(reused: false) }
            }
        }
    }
    func becameReady(reused: Bool) {
        probeTimer?.invalidate()
        starting = false
        ready = true
        portButton.isEnabled = false
        browserButton.isEnabled = true
        status.stringValue = reused
            ? "Delegatus працює у власному вікні.\nВикористано вже запущений сервер.\nЗавершення цієї програми не зупинить цей сервер."
            : "Delegatus працює у власному вікні.\nЗакриття вікна залишає сервер працювати.\n«Завершити» зупинить запущений тут сервер."
        writeLog(reused ? "REUSED: verified Delegatus HTML and JavaScript.\n" : "READY: verified Delegatus HTML and JavaScript.\n")
        window.orderOut(nil)
        openBrowser()
    }
    @objc func openBrowser() {
        guard ready else { showWindow(); return }
        if webWindow == nil { makeWebWindow() }
        webWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showControls() { showWindow() }
    @objc func goBack() { webView?.goBack() }
    @objc func goForward() { webView?.goForward() }
    @objc func reloadWeb() {
        if webView?.url == nil { webView?.load(URLRequest(url: viewer)) }
        else { webView?.reload() }
    }
    @objc func openInBrowser() { NSWorkspace.shared.open(viewer) }
    func setupMenus() {
        let root = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Delegatus")
        appItem.submenu!.addItem(withTitle: "Керування запуском…", action: #selector(showControls), keyEquivalent: ",")
        appItem.submenu!.addItem(withTitle: "Налаштувати залежності…", action: #selector(configureRuntime), keyEquivalent: "")
        appItem.submenu!.addItem(withTitle: "Відкрити журнал", action: #selector(openLog), keyEquivalent: "")
        appItem.submenu!.addItem(.separator())
        appItem.submenu!.addItem(withTitle: "Приховати Delegatus", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appItem.submenu!.addItem(.separator())
        appItem.submenu!.addItem(withTitle: "Завершити Delegatus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.addItem(appItem)
        let file = NSMenuItem(title: "Файл", action: nil, keyEquivalent: "")
        file.submenu = NSMenu(title: "Файл")
        file.submenu!.addItem(withTitle: "Вікно Delegatus", action: #selector(openBrowser), keyEquivalent: "0")
        file.submenu!.addItem(withTitle: "Закрити вікно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        root.addItem(file)
        let edit = NSMenuItem(title: "Редагування", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Редагування")
        for (title, selector, key) in [("Скасувати", "undo:", "z"), ("Повторити", "redo:", "Z"), ("Вирізати", "cut:", "x"), ("Копіювати", "copy:", "c"), ("Вставити", "paste:", "v"), ("Вибрати все", "selectAll:", "a")] {
            edit.submenu!.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        root.addItem(edit)
        let view = NSMenuItem(title: "Перегляд", action: nil, keyEquivalent: "")
        view.submenu = NSMenu(title: "Перегляд")
        view.submenu!.addItem(withTitle: "Оновити сторінку", action: #selector(reloadWeb), keyEquivalent: "r")
        view.submenu!.addItem(withTitle: "Відкрити в браузері", action: #selector(openInBrowser), keyEquivalent: "")
        root.addItem(view)
        let windows = NSMenuItem(title: "Вікно", action: nil, keyEquivalent: "")
        windows.submenu = NSMenu(title: "Вікно")
        windows.submenu!.addItem(withTitle: "Згорнути", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        root.addItem(windows)
        NSApp.windowsMenu = windows.submenu
        NSApp.mainMenu = root
    }
    func makeWebWindow() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.autoresizingMask = [.width, .height]
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 1000)
        let size = NSSize(width: min(1280, screen.width * 0.92), height: min(860, screen.height * 0.9))
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = "Delegatus"
        win.minSize = NSSize(width: 760, height: 520)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        win.setFrameAutosaveName("DelegatusWebWindow")
        win.contentView = web
        let toolbar = NSToolbar(identifier: "DelegatusToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        win.toolbar = toolbar
        win.toolbarStyle = .unified
        webWindow = win
        webView = web
        webObservations = [web.observe(\.canGoBack) { [weak self] _, _ in self?.webWindow?.toolbar?.validateVisibleItems() }, web.observe(\.canGoForward) { [weak self] _, _ in self?.webWindow?.toolbar?.validateVisibleItems() }]
        web.load(URLRequest(url: viewer))
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [NSToolbarItem.Identifier("back"), NSToolbarItem.Identifier("forward"), NSToolbarItem.Identifier("reload"), .flexibleSpace, NSToolbarItem.Identifier("controls"), NSToolbarItem.Identifier("log")]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let definitions: [String: (String, String, Selector)] = [
            "back": ("Назад", "chevron.left", #selector(goBack)),
            "forward": ("Вперед", "chevron.right", #selector(goForward)),
            "reload": ("Оновити", "arrow.clockwise", #selector(reloadWeb)),
            "controls": ("Керування запуском", "slider.horizontal.3", #selector(showControls)),
            "log": ("Журнал", "doc.text", #selector(openLog))
        ]
        guard let (title, symbol, action) = definitions[id.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = title
        item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.target = self
        item.action = action
        return item
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier.rawValue {
        case "back": return webView?.canGoBack ?? false
        case "forward": return webView?.canGoForward ?? false
        default: return true
        }
    }
    func isLocal(_ url: URL) -> Bool { url.scheme == viewer.scheme && url.host == viewer.host && url.port == viewer.port }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.shouldPerformDownload { decisionHandler(.download); return }
        let topLevel = action.targetFrame?.isMainFrame ?? true
        if topLevel && !isLocal(url) && url.scheme != "about" && url.scheme != "blob" {
            decisionHandler(.cancel)
            if ["http", "https", "mailto", "tel"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            if let popup = popupWindows.removeValue(forKey: ObjectIdentifier(webView)) { popup.close() }
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView {
            webWindow?.title = "Delegatus"
            webWindow?.toolbar?.validateVisibleItems()
            writeLog("WEB: page loaded in dedicated Delegatus window.\n")
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showWebError(webView, error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showWebError(webView, error) }
    func showWebError(_ web: WKWebView, _ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        writeLog("WEB ERROR: \(error.localizedDescription)\n")
        guard web === webView else { return }
        let alert = NSAlert()
        alert.messageText = "Не вдалося завантажити Delegatus"
        alert.informativeText = error.localizedDescription + "\nМожна оновити сторінку або відкрити керування запуском."
        alert.addButton(withTitle: "Оновити")
        alert.addButton(withTitle: "Керування")
        if alert.runModal() == .alertFirstButtonReturn { reloadWeb() } else { showWindow() }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showWebError(webView, NSError(domain: "DelegatusLauncher", code: 5, userInfo: [NSLocalizedDescriptionKey: "Процес вікна завершив роботу. Сервер Delegatus продовжує працювати."]))
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = "Delegatus"
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.contentView = popup
        popupWindows[ObjectIdentifier(popup)] = win
        win.center()
        win.makeKeyAndOrderFront(nil)
        return popup
    }
    func webViewDidClose(_ webView: WKWebView) { popupWindows.removeValue(forKey: ObjectIdentifier(webView))?.close() }
    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        if let key = popupWindows.first(where: { $0.value === win })?.key { popupWindows.removeValue(forKey: key) }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = "Delegatus"; alert.informativeText = message
        alert.addButton(withTitle: "Гаразд"); alert.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = "Delegatus"; alert.informativeText = message
        alert.addButton(withTitle: "Підтвердити"); alert.addButton(withTitle: "Скасувати")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = "Delegatus"; alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); field.stringValue = defaultText ?? ""
        alert.accessoryView = field; alert.addButton(withTitle: "Гаразд"); alert.addButton(withTitle: "Скасувати")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { trackDownload(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { trackDownload(download) }
    func trackDownload(_ download: WKDownload) { activeDownloads[ObjectIdentifier(download)] = download; download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { completionHandler(nil); return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            completionHandler(url)
        } catch { completionHandler(nil); showWebError(webView!, error) }
    }
    func downloadDidFinish(_ download: WKDownload) { activeDownloads.removeValue(forKey: ObjectIdentifier(download)); writeLog("WEB: download finished.\n") }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { activeDownloads.removeValue(forKey: ObjectIdentifier(download)); showWebError(webView!, error) }

    @objc func configureRuntime() {
        guard !resolvingRuntime else { return }
        if let installer = setupProcess, installer.isRunning {
            let alert = NSAlert()
            alert.messageText = "Скасувати встановлення?"
            alert.informativeText = "Буде зупинено поточне завантаження або встановлення залежностей."
            alert.addButton(withTitle: "Продовжити встановлення")
            alert.addButton(withTitle: "Скасувати встановлення")
            if alert.runModal() == .alertSecondButtonReturn { setupWasCancelled = true; installer.terminate() }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Налаштування Delegatus"
        if ready || starting || child?.isRunning == true {
            let noticePreference = "suppressRunningRuntimeNoticeV1"
            if UserDefaults.standard.bool(forKey: noticePreference) { return }
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Не показувати більше"
            alert.informativeText = "Delegatus уже працює. Залежності можна змінити після завершення сервера.\n\nДля агентних задач кожен користувач установлює та підключає власний Codex або Claude Code у майстрі Delegatus."
            alert.addButton(withTitle: "Зрозуміло")
            alert.addButton(withTitle: "Інструкція Delegatus")
            let response = alert.runModal()
            UserDefaults.standard.set(alert.suppressionButton?.state == .on, forKey: noticePreference)
            if response == .alertSecondButtonReturn { NSWorkspace.shared.open(URL(string: "https://github.com/Latand/delegatus#quick-start")!) }
            return
        }
        alert.informativeText = "Запускатор може використати встановлені Bun і Delegatus або завантажити окремі залежності.\n\nУстановлення потребує інтернету: Bun 1.4.3 з GitHub oven-sh/bun, Delegatus 1.11.0 з npm. Файли буде збережено лише в папці цього користувача:\n\(paths.runtime.path)\n\nВхід у Codex або Claude Code кожен користувач налаштовує сам у Delegatus."
        alert.addButton(withTitle: "Установити залежності")
        alert.addButton(withTitle: "Вибрати наявні файли")
        alert.addButton(withTitle: "Скасувати")
        switch alert.runModal() {
        case .alertFirstButtonReturn: installPrivateRuntime()
        case .alertSecondButtonReturn: chooseRuntime()
        default: break
        }
    }
    func chooseRuntime() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.message = "Виберіть виконуваний файл Bun (зазвичай ~/.bun/bin/bun)."
        guard panel.runModal() == .OK, let bunFile = panel.url else { return }
        panel.message = "Виберіть Delegatus: bin/cli.mjs у пакеті delegatus-cli або посилання delegatus."
        guard panel.runModal() == .OK, let cliFile = panel.url else { return }
        status.stringValue = "Перевіряю вибрані залежності…"
        DispatchQueue.global().async {
            let locator = RuntimeLocator(paths: self.paths)
            guard let canonicalBun = locator.canonicalFile(bunFile, executable: true),
                  let (_, _, packageMinimum) = locator.packageMetadata(at: cliFile),
                  let output = locator.probeVersion(canonicalBun), let version = SemanticVersion(output),
                  version >= max(packageMinimum, SemanticVersion("1.4.0")!) else {
                DispatchQueue.main.async { self.fail("Вибрані файли не підходять. Потрібні Bun 1.4+ і файл запуску з пакета delegatus-cli.") }
                return
            }
            let settings = LauncherSettings(bunPath: bunFile.path, cliPath: cliFile.path)
            do {
                try settings.save(to: self.paths.settings)
                DispatchQueue.main.async { self.beginLaunch() }
            } catch { DispatchQueue.main.async { self.fail("Не вдалося зберегти налаштування: \(error.localizedDescription)") } }
        }
    }
    func installPrivateRuntime() {
        guard setupProcess?.isRunning != true, !starting, !ready, child?.isRunning != true else { return }
        guard let script = Bundle.main.url(forResource: "setup-runtime", withExtension: "sh") else {
            fail("У програмі немає файла встановлення. Розпакуйте повний архів запускатора ще раз."); return
        }
        setupButton.isEnabled = false
        resolvingRuntime = true
        DispatchQueue.global().async {
            let discovery = RuntimeLocator(paths: self.paths).discover(settings: LauncherSettings.load(from: self.paths.settings))
            DispatchQueue.main.async {
                self.resolvingRuntime = false
                guard !self.stopping else { return }
                let installer = Process()
                installer.executableURL = URL(fileURLWithPath: "/bin/bash")
                installer.arguments = [script.path, self.paths.runtime.path, discovery.usableBun?.path ?? ""]
                installer.environment = RuntimeLocator(paths: self.paths).processEnvironment(bun: discovery.usableBun)
                installer.currentDirectoryURL = self.base
                installer.standardOutput = self.output; installer.standardError = self.output
                installer.standardInput = FileHandle.nullDevice
                self.setupWasCancelled = false
                installer.terminationHandler = { process in
                    DispatchQueue.main.async {
                        self.setupProcess = nil
                        self.setupButton.title = "Налаштувати"
                        self.setupButton.isEnabled = true
                        if self.stopping { return }
                        if self.setupWasCancelled {
                            self.status.stringValue = "Установлення скасовано. Його можна запустити знову кнопкою «Налаштувати»."
                        } else if process.terminationStatus == 0 {
                            do {
                                let settings = LauncherSettings(bunPath: (discovery.usableBun ?? self.paths.managedBun).path, cliPath: self.paths.managedCLI.path)
                                try settings.save(to: self.paths.settings)
                                self.status.stringValue = "Залежності встановлено. Перевіряю запуск…"
                                self.beginLaunch()
                            } catch { self.fail("Залежності встановлено, але не вдалося зберегти їхні шляхи: \(error.localizedDescription)") }
                        } else {
                            self.fail("Не вдалося встановити залежності (код \(process.terminationStatus)). Деталі — у журналі. Перевірте інтернет і повторіть спробу.")
                        }
                    }
                }
                self.setupProcess = installer
                do { try installer.run() }
                catch { self.setupProcess = nil; self.setupButton.isEnabled = true; self.fail("Не вдалося почати встановлення: \(error.localizedDescription)"); return }
                self.setupButton.title = "Скасувати встановлення"
                self.setupButton.isEnabled = true
                self.status.stringValue = "Установлюю залежності…\nЦе може тривати кілька хвилин. Хід установлення доступний кнопкою «Журнал»."
                self.writeLog("SETUP: user approved private dependencies.\n")
            }
        }
    }

    struct Listener: Equatable {
        let pid: Int32
        let name: String
        let started: String
    }
    func command(_ path: String, _ arguments: [String]) throws -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        try p.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
    func listeners() throws -> [Listener] {
        let (code, out, err) = try command("/usr/sbin/lsof", ["-nP", "-a", "-iTCP:8898", "-sTCP:LISTEN", "-Fpc"])
        if (code != 0 && code != 1) || !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NSError(domain: "DelegatusLauncher", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не вдалося перевірити власника порту: \(err)"])
        }
        var result: [Listener] = []
        var pid: Int32?
        for line in out.split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()) }
            if line.first == "c", let pid = pid {
                let (status, born, _) = try command("/bin/ps", ["-p", String(pid), "-o", "lstart="])
                guard status == 0, !born.isEmpty else { continue }
                result.append(Listener(pid: pid, name: String(line.dropFirst()), started: born))
            }
        }
        return result.sorted { $0.pid < $1.pid }
    }
    @objc func freePort() {
        guard child?.isRunning != true else { fail("Цей запускатор уже керує Delegatus. Натисніть «Завершити», щоб коректно зупинити його сервер."); return }
        portButton.isEnabled = false
        DispatchQueue.global().async {
            do {
                let snapshot = try self.listeners()
                DispatchQueue.main.async {
                    if snapshot.isEmpty { self.startServer(); return }
                    let alert = NSAlert()
                    alert.messageText = "Звільнити порт 8898?"
                    alert.informativeText = "Порт використовують:\n" + snapshot.map { "\($0.name) — PID \($0.pid)" }.joined(separator: "\n") + "\n\nЦі процеси отримають команду завершення. Їхня поточна робота може перерватися. Після звільнення порту Delegatus запуститься автоматично."
                    alert.addButton(withTitle: "Скасувати")
                    alert.addButton(withTitle: "Завершити процес і запустити")
                    guard alert.runModal() == .alertSecondButtonReturn else { self.portButton.isEnabled = true; return }
                    self.status.stringValue = "Звільняю порт 8898…"
                    DispatchQueue.global().async {
                        do {
                            guard try self.listeners() == snapshot else {
                                throw NSError(domain: "DelegatusLauncher", code: 3, userInfo: [NSLocalizedDescriptionKey: "Власник порту змінився. Натисніть «Звільнити порт» ще раз, щоб перевірити новий процес."])
                            }
                            for listener in snapshot {
                                guard try self.listeners().contains(listener) else { continue }
                                if Darwin.kill(listener.pid, SIGTERM) != 0 && errno != ESRCH {
                                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Немає дозволу завершити \(listener.name) (PID \(listener.pid))."])
                                }
                                self.writeLog("PORT: user approved SIGTERM to \(listener.name) pid \(listener.pid).\n")
                            }
                            let end = Date().addingTimeInterval(8)
                            while Date() < end {
                                if try self.listeners().isEmpty {
                                    DispatchQueue.main.async { self.startServer() }
                                    return
                                }
                                Thread.sleep(forTimeInterval: 0.25)
                            }
                            throw NSError(domain: "DelegatusLauncher", code: 4, userInfo: [NSLocalizedDescriptionKey: "Процес не звільнив порт за 8 секунд. Примусове завершення не застосовувалося. Закрийте відповідну програму й повторіть спробу."])
                        } catch {
                            DispatchQueue.main.async { self.portButton.isEnabled = true; self.fail(error.localizedDescription) }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { self.portButton.isEnabled = true; self.fail(error.localizedDescription) }
            }
        }
    }
    @objc func openLog() {
        if let url = logURL { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.open(base.appendingPathComponent("Logs")) }
    }
    func fail(_ message: String) {
        ready = false
        browserButton?.isEnabled = false
        status?.stringValue = message
        writeLog("ERROR: \(message)\n")
        showWindow()
        let alert = NSAlert()
        alert.messageText = "Помилка запуску Delegatus"
        alert.informativeText = message + (logURL.map { "\n\nЖурнал: \($0.path)" } ?? "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Зрозуміло")
        if logURL != nil { alert.addButton(withTitle: "Відкрити журнал") }
        if alert.runModal() == .alertSecondButtonReturn { openLog() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        probeTimer?.invalidate()
        stopping = true
        if let installer = setupProcess, installer.isRunning {
            setupWasCancelled = true
            installer.terminate()
            DispatchQueue.global().async {
                let limit = Date().addingTimeInterval(12)
                while installer.isRunning && Date() < limit { Thread.sleep(forTimeInterval: 0.1) }
                DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            return .terminateLater
        }
        if let process = child, process.isRunning {
            writeLog("STOP: user quit launcher; sending SIGTERM to owned CLI.\n")
            process.terminate()
            DispatchQueue.global().async {
                process.waitUntilExit()
                DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            return .terminateLater
        }
        return .terminateNow
    }
}
@main
struct DelegatusApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = Launcher()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
