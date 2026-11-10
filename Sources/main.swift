import Cocoa
import WebKit

// MARK: - Viewer window (one per open file)

final class ViewerWindowController: NSWindowController, WKNavigationDelegate, NSToolbarDelegate,
                                    WKScriptMessageHandler, NSWindowDelegate {
    let webView: WKWebView
    var fileURL: URL?
    private(set) var isDirty = false
    /// New, untitled documents open side by side so pasted text has an editor and a preview.
    private var mode: String = "split"
    private static let modes = ["rendered", "edit", "split"]
    private static let modeKey = "viewMode"
    private static let liveKey = "livePreview"
    /// The view a file opens in: whichever the user last picked.
    static var preferredMode: String {
        let m = UserDefaults.standard.string(forKey: modeKey) ?? "rendered"
        return modes.contains(m) ? m : "rendered"
    }
    static var livePreview: Bool {
        get { UserDefaults.standard.bool(forKey: liveKey) }
        set { UserDefaults.standard.set(newValue, forKey: liveKey) }
    }
    var onClose: ((ViewerWindowController) -> Void)?
    /// An untitled window nobody has typed into; opening a file replaces it.
    var isPristineUntitled: Bool { fileURL == nil && !isDirty }
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
        window.title = "Untitled"
        super.init(window: window)

        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "dirty")
        webView.configuration.userContentController.add(self, name: "openLink")
        webView.configuration.userContentController.add(self, name: "copyText")
        window.delegate = self
        window.contentView = webView
        setupToolbar()
        widenForSplit()

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
        let seg = NSSegmentedControl(labels: ["Rendered", "Edit", "Side by Side"],
                                     trackingMode: .selectOne,
                                     target: self, action: #selector(segChanged(_:)))
        seg.selectedSegment = Self.modes.firstIndex(of: mode) ?? 0
        segmented = seg
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = seg
        item.label = "View"
        return item
    }

    @objc private func segChanged(_ sender: NSSegmentedControl) {
        setMode(Self.modes[sender.selectedSegment], remember: true)
    }

    /// `remember` records the choice as the view new files open in.
    func setMode(_ m: String, remember: Bool = false) {
        guard Self.modes.contains(m) else { return }
        mode = m
        if remember { UserDefaults.standard.set(m, forKey: Self.modeKey) }
        segmented?.selectedSegment = Self.modes.firstIndex(of: m) ?? 0
        widenForSplit()
        if pageReady {
            webView.evaluateJavaScript("window.MDSetMode('\(m)')", completionHandler: nil)
        }
    }

    /// Closes an untitled window only once the page confirms its editor is empty.
    func closeIfEmpty() {
        guard fileURL == nil, !isDirty else { return }
        guard pageReady else { window?.close(); return }   // not loaded yet: nothing typed
        webView.evaluateJavaScript("window.MDGetContent() === ''") { [weak self] result, _ in
            guard let self = self, (result as? Bool) == true,
                  self.fileURL == nil, !self.isDirty else { return }
            self.window?.close()
        }
    }

    func applyLivePreview() {
        guard pageReady else { return }
        webView.evaluateJavaScript("window.MDSetLivePreview(\(Self.livePreview))", completionHandler: nil)
    }

    /// Two panes need room: grow a narrow window when it shows side by side.
    private func widenForSplit() {
        guard mode == "split", let w = window, w.frame.width < 1100,
              let screen = w.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var f = w.frame
        let width = min(1280, visible.width)
        f.origin.x = max(visible.minX, min(f.midX - width / 2, visible.maxX - width))
        f.size.width = width
        w.setFrame(f, display: true, animate: w.isVisible)
    }

    func findInPage() { webView.evaluateJavaScript("window.MDFind()", completionHandler: nil) }
    func findNext()   { webView.evaluateJavaScript("window.MDFindNext()", completionHandler: nil) }
    func findPrev()   { webView.evaluateJavaScript("window.MDFindPrev()", completionHandler: nil) }

    // MARK: Loading a file

    func open(_ url: URL) {
        setMode(Self.preferredMode)
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
        applyLivePreview()
        if let b64 = pendingB64 {
            webView.evaluateJavaScript("window.MDRender('\(b64)')", completionHandler: nil)
            pendingB64 = nil
        }
        webView.evaluateJavaScript("window.MDSetMode('\(mode)')", completionHandler: nil)
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
        } else if message.name == "copyText", let text = message.body as? String {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
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

    /// Writes the buffer to disk. Nothing else in the app writes files: there is no autosave.
    /// `askForLocation` forces the save panel (Save As…); untitled documents always get it.
    func save(askForLocation: Bool = false, completion: ((Bool) -> Void)? = nil) {
        webView.evaluateJavaScript("window.MDGetContent()") { [weak self] result, _ in
            guard let self = self, let b64 = result as? String,
                  let data = Data(base64Encoded: b64) else { completion?(false); return }
            if let url = self.fileURL, !askForLocation {
                self.write(data, to: url, completion: completion)
            } else {
                let panel = NSSavePanel()
                panel.allowedFileTypes = ["md", "markdown", "txt"]
                panel.nameFieldStringValue = self.fileURL?.lastPathComponent ?? "Untitled.md"
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

    func windowWillClose(_ notification: Notification) {
        stopWatching()
        // the content controller retains its handlers (and so this controller)
        let ucc = webView.configuration.userContentController
        for name in ["dirty", "openLink", "copyText"] { ucc.removeScriptMessageHandler(forName: name) }
        onClose?(self)
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
    private var livePreviewItem: NSMenuItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        if controllers.isEmpty {
            // launched with no document: open an untitled one, ready for typing or pasting
            newDocument(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeController() -> ViewerWindowController {
        let c = ViewerWindowController()
        c.onClose = { [weak self] closed in self?.controllers.removeAll { $0 === closed } }
        // offset from the current window instead of stacking exactly on top of it
        if let key = NSApp.keyWindow ?? controllers.last?.window, let w = c.window {
            let topLeft = NSPoint(x: key.frame.minX, y: key.frame.maxY)
            w.setFrameTopLeftPoint(w.cascadeTopLeft(from: topLeft))
        }
        controllers.append(c)
        return c
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
            else { newDocument(nil) }
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
        if let existing = controllers.first(where: { $0.fileURL == url }) {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        // A file always gets a fresh window. Loading it into an existing untitled
        // window is unsafe: the dirty flag reaches Swift asynchronously, so text
        // typed a moment earlier could stay in the editor under the file's name,
        // and saving would overwrite the file with it.
        let placeholder = controllers.first(where: { $0.isPristineUntitled })
        let c = makeController()
        if let frame = placeholder?.window?.frame { c.window?.setFrame(frame, display: false) }
        c.open(url)
        c.showWindow(nil); c.window?.makeKeyAndOrderFront(nil)
        placeholder?.closeIfEmpty()
    }

    // MARK: Menu

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["md", "markdown", "mdown", "mkd", "markdn", "mdtext", "txt"]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for u in panel.urls { present(u) } }
    }

    @objc func newDocument(_ sender: Any?) {
        let c = makeController()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    @objc func saveDocument(_ s: Any?) { keyVC()?.save() }
    @objc func saveDocumentAs(_ s: Any?) { keyVC()?.save(askForLocation: true) }
    @objc func showRendered(_ s: Any?) { keyVC()?.setMode("rendered", remember: true) }
    @objc func showEditor(_ s: Any?)   { keyVC()?.setMode("edit", remember: true) }
    @objc func showSplit(_ s: Any?)    { keyVC()?.setMode("split", remember: true) }
    @objc func toggleLivePreview(_ s: Any?) {
        ViewerWindowController.livePreview.toggle()
        livePreviewItem?.state = ViewerWindowController.livePreview ? .on : .off
        for c in controllers { c.applyLivePreview() }
    }
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
        fileMenu.addItem(withTitle: "New", action: #selector(newDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(withTitle: "Save As…", action: #selector(saveDocumentAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
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
        viewMenu.addItem(withTitle: "Side by Side", action: #selector(showSplit(_:)), keyEquivalent: "3")
        viewMenu.addItem(.separator())
        let live = viewMenu.addItem(withTitle: "Live Preview", action: #selector(toggleLivePreview(_:)), keyEquivalent: "l")
        live.keyEquivalentModifierMask = [.command, .shift]
        live.state = ViewerWindowController.livePreview ? .on : .off
        livePreviewItem = live
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
