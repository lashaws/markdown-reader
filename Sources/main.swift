import Cocoa
import WebKit

// MARK: - Viewer window (one per open file)

final class ViewerWindowController: NSWindowController, WKNavigationDelegate, NSToolbarDelegate,
                                    WKScriptMessageHandler, NSWindowDelegate {
    let webView: WKWebView
    var fileURL: URL?
    private(set) var isDirty = false
    private var mode: String = "rendered"
    private static let modes = ["rendered", "edit"]
    private var pageReady = false
    private var pendingB64: String?
    private var watchSource: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1
    private var segmented: NSSegmentedControl?

    init() {
        let cfg = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.setValue(false, forKey: "drawsBackground")  // let CSS bg show, avoids white flash
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.center()
        window.setFrameAutosaveName("MarkdownReaderWindow")
        super.init(window: window)

        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "dirty")
        webView.configuration.userContentController.add(self, name: "openLink")
        window.delegate = self
        window.contentView = webView
        setupToolbar()

        let viewer = Bundle.main.url(forResource: "viewer", withExtension: "html")!
        webView.loadFileURL(viewer, allowingReadAccessTo: viewer.deletingLastPathComponent())
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Toolbar

    private func setupToolbar() {
        let tb = NSToolbar(identifier: "MainToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        window?.toolbar = tb
        if #available(macOS 11.0, *) { window?.toolbarStyle = .unified }
    }

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, NSToolbarItem.Identifier("viewMode")]
    }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, NSToolbarItem.Identifier("viewMode")]
    }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id.rawValue == "viewMode" else { return nil }
        let seg = NSSegmentedControl(labels: ["Rendered", "Edit"],
                                     trackingMode: .selectOne,
                                     target: self, action: #selector(segChanged(_:)))
        seg.selectedSegment = 0
        segmented = seg
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = seg
        item.label = "View"
        return item
    }

    @objc private func segChanged(_ sender: NSSegmentedControl) {
        setMode(Self.modes[sender.selectedSegment])
    }

    func setMode(_ m: String) {
        mode = m
        segmented?.selectedSegment = Self.modes.firstIndex(of: m) ?? 0
        webView.evaluateJavaScript("window.MDSetMode('\(m)')", completionHandler: nil)
    }

    func findInPage() { webView.evaluateJavaScript("window.MDFind()", completionHandler: nil) }
    func findNext()   { webView.evaluateJavaScript("window.MDFindNext()", completionHandler: nil) }
    func findPrev()   { webView.evaluateJavaScript("window.MDFindPrev()", completionHandler: nil) }

    // MARK: Loading a file

    func open(_ url: URL) {
        fileURL = url
        window?.title = url.lastPathComponent
        window?.representedURL = url
        reloadContent(preserveScroll: false)
        startWatching(url)
    }

    private func reloadContent(preserveScroll: Bool) {
        guard let url = fileURL else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        let b64 = data.base64EncodedString()
        let push = { [weak self] in
            guard let self = self else { return }
            if self.pageReady {
                self.webView.evaluateJavaScript("window.MDRender('\(b64)')", completionHandler: nil)
                self.webView.evaluateJavaScript("window.MDSetMode('\(self.mode)')", completionHandler: nil)
            } else {
                self.pendingB64 = b64
            }
        }
        if preserveScroll && pageReady {
            webView.evaluateJavaScript("window.MDScrollFraction()") { [weak self] result, _ in
                push()
                if let f = result as? Double, let self = self {
                    self.webView.evaluateJavaScript("window.MDScrollTo(\(f))", completionHandler: nil)
                }
            }
        } else {
            push()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        if let b64 = pendingB64 {
            webView.evaluateJavaScript("window.MDRender('\(b64)')", completionHandler: nil)
            webView.evaluateJavaScript("window.MDSetMode('\(mode)')", completionHandler: nil)
            pendingB64 = nil
        }
    }

    // open external links in the default browser, keep local nav internal
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           navigationAction.navigationType == .linkActivated,
           let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: Editing & saving

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "dirty", let d = message.body as? Bool {
            isDirty = d
            window?.isDocumentEdited = d
        } else if message.name == "openLink", let href = message.body as? String {
            openLink(href)
        }
    }

    private func openLink(_ href: String) {
        guard !href.isEmpty else { return }

        let target: URL?
        if let absolute = URL(string: href), absolute.scheme != nil {
            target = absolute
        } else if let source = fileURL {
            let directory = source.deletingLastPathComponent()
                .appendingPathComponent("", isDirectory: true)
            target = URL(string: href, relativeTo: directory)?.absoluteURL
        } else {
            target = nil
        }

        guard let url = target,
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "file"].contains(scheme) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    func save(completion: ((Bool) -> Void)? = nil) {
        webView.evaluateJavaScript("window.MDGetContent()") { [weak self] result, _ in
            guard let self = self, let b64 = result as? String,
                  let data = Data(base64Encoded: b64) else { completion?(false); return }
            if let url = self.fileURL {
                self.write(data, to: url, completion: completion)
            } else {
                let panel = NSSavePanel()
                panel.allowedFileTypes = ["md", "markdown", "txt"]
                panel.nameFieldStringValue = "Untitled.md"
                panel.beginSheetModal(for: self.window!) { resp in
                    guard resp == .OK, let url = panel.url else { completion?(false); return }
                    self.write(data, to: url, completion: completion)
                }
            }
        }
    }

    private func write(_ data: Data, to url: URL, completion: ((Bool) -> Void)?) {
        do {
            try data.write(to: url, options: .atomic)
            if fileURL != url {
                fileURL = url
                window?.title = url.lastPathComponent
                window?.representedURL = url
                startWatching(url)
            }
            webView.evaluateJavaScript("window.MDMarkSaved()", completionHandler: nil)
            isDirty = false
            window?.isDocumentEdited = false
            completion?(true)
        } catch {
            NSAlert(error: error).runModal()
            completion?(false)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to \u{201C}\(sender.title)\u{201D}?"
        alert.informativeText = "Your changes will be lost if you don\u{2019}t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don\u{2019}t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save { [weak self] ok in if ok { self?.window?.close() } }
            return false
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: Live reload (file watching)

    private func startWatching(_ url: URL) {
        stopWatching()
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .link],
            queue: DispatchQueue.main)
        src.setEventHandler { [weak self] in
            guard let self = self, let src = self.watchSource else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // atomic save: re-establish the watch on the (recreated) path shortly
                self.stopWatching()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self = self, let u = self.fileURL else { return }
                    self.reloadContent(preserveScroll: true)
                    self.startWatching(u)
                }
            } else {
                self.reloadContent(preserveScroll: true)
            }
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.watchFD, fd >= 0 { Darwin.close(fd) }
            self?.watchFD = -1
        }
        watchSource = src
        src.resume()
    }

    private func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
    }

    deinit { stopWatching() }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controllers: [ViewerWindowController] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        if controllers.isEmpty {
            // launched with no document: show an empty window inviting a file
            let c = ViewerWindowController()
            controllers.append(c)
            c.showWindow(nil)
            c.window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        for url in urls { present(url) }
    }

    // legacy single-file entry (still used by some LaunchServices paths)
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        present(URL(fileURLWithPath: filename)); return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let c = controllers.last { c.showWindow(nil) }
            else { openDocument(nil) }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // route dirty windows through the standard close prompt; if a save is
        // chosen it completes asynchronously, so cancel and let the app quit
        // when the last window closes
        for c in controllers where c.isDirty && c.window?.isVisible == true {
            c.window?.makeKeyAndOrderFront(nil)
            guard let w = c.window else { continue }
            if !c.windowShouldClose(w) { return .terminateCancel }
            w.close()
        }
        return .terminateNow
    }

    private func present(_ url: URL) {
        // reuse an empty placeholder window if present
        if let empty = controllers.first(where: { $0.fileURL == nil }) {
            empty.open(url)
            empty.showWindow(nil); empty.window?.makeKeyAndOrderFront(nil)
            return
        }
        if let existing = controllers.first(where: { $0.fileURL == url }) {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let c = ViewerWindowController()
        controllers.append(c)
        c.open(url)
        c.showWindow(nil); c.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["md", "markdown", "mdown", "mkd", "markdn", "mdtext", "txt"]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for u in panel.urls { present(u) } }
    }

    @objc func saveDocument(_ s: Any?) { keyVC()?.save() }
    @objc func showRendered(_ s: Any?) { keyVC()?.setMode("rendered") }
    @objc func showEditor(_ s: Any?)   { keyVC()?.setMode("edit") }
    @objc func performFindAction(_ s: Any?) { keyVC()?.findInPage() }
    @objc func findNextAction(_ s: Any?)    { keyVC()?.findNext() }
    @objc func findPrevAction(_ s: Any?)    { keyVC()?.findPrev() }

    private func keyVC() -> ViewerWindowController? {
        NSApp.keyWindow?.windowController as? ViewerWindowController
    }

    private func buildMenu() {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Markdown Reader", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Markdown Reader", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Markdown Reader", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // File menu
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        fileMenu.addItem(.separator())
        let close = fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        close.keyEquivalentModifierMask = [.command]
        fileItem.submenu = fileMenu

        // Edit menu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find…", action: #selector(performFindAction(_:)), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Find Next", action: #selector(findNextAction(_:)), keyEquivalent: "g")
        let fp = editMenu.addItem(withTitle: "Find Previous", action: #selector(findPrevAction(_:)), keyEquivalent: "g")
        fp.keyEquivalentModifierMask = [.command, .shift]
        editItem.submenu = editMenu

        // View menu
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Rendered View", action: #selector(showRendered(_:)), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Edit Mode", action: #selector(showEditor(_:)), keyEquivalent: "2")
        viewItem.submenu = viewMenu

        // Window menu
        let winItem = NSMenuItem(); main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winItem.submenu = winMenu
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = main
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
