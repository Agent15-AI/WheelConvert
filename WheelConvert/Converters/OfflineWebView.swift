import AppKit
import PDFKit
import WebKit

/// An offscreen WKWebView that can never reach the network, used to lay out and print
/// SVG, HTML, DOCX and EPUB content locally.
@MainActor
final class OfflineWebView: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private var navigation: CheckedContinuation<Void, Error>?
    private var printing: CheckedContinuation<Bool, Never>?
    /// File URLs under this directory may load (EPUB chapters and their images); everything else is blocked.
    private let allowedDirectory: URL?

    private static var ruleList: WKContentRuleList?

    /// Blocks every http(s) request. Pages only see local files they were given.
    static func prepareRules() async throws -> WKContentRuleList {
        if let ruleList { return ruleList }
        // Content-blocker regexes can't use alternation, so each scheme gets its own rule.
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]"#
        guard let store = WKContentRuleListStore.default() else { throw WheelError("Offline rendering could not be prepared.") }
        let list = try await store.compileContentRuleList(forIdentifier: "WheelConvertOffline", encodedContentRuleList: rules)
        guard let list else { throw WheelError("Offline rendering could not be prepared.") }
        ruleList = list
        return list
    }

    init(width: CGFloat = 1024, height: CGFloat = 768, allowedDirectory: URL? = nil, rules: WKContentRuleList) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        configuration.suppressesIncrementalRendering = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        self.allowedDirectory = allowedDirectory?.standardizedFileURL
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    static func make(width: CGFloat = 1024, height: CGFloat = 768, allowedDirectory: URL? = nil) async throws -> OfflineWebView {
        OfflineWebView(width: width, height: height, allowedDirectory: allowedDirectory, rules: try await prepareRules())
    }

    func close() {
        webView.stopLoading()
        window.close()
    }

    func loadHTML(_ html: String, baseURL: URL? = nil, timeout: TimeInterval = 60) async throws {
        try await waitForNavigation(timeout: timeout) { webView.loadHTMLString(html, baseURL: baseURL) }
    }

    func loadFile(_ url: URL, timeout: TimeInterval = 60) async throws {
        let directory = allowedDirectory ?? url.deletingLastPathComponent()
        try await waitForNavigation(timeout: timeout) { webView.loadFileURL(url, allowingReadAccessTo: directory) }
    }

    private var navigationID = 0

    /// Starts a load and waits for it to finish, fail, or time out — whichever happens first.
    private func waitForNavigation(timeout: TimeInterval, _ start: () -> Void) async throws {
        navigationID += 1
        let id = navigationID
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigation = continuation
            start()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.navigationID == id, let pending = self.navigation else { return }
                self.navigation = nil
                self.webView.stopLoading()
                pending.resume(throwing: WheelError("Rendering timed out."))
            }
        }
    }

    @discardableResult
    func evaluate(_ script: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    @discardableResult
    func evaluate(_ script: String, arguments: [String: Any]) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
    }

    func resize(to size: CGSize) {
        window.setContentSize(size)
        webView.frame = NSRect(origin: .zero, size: size)
        webView.layoutSubtreeIfNeeded()
    }

    /// Vector PDF of a rectangle of the page (in CSS pixels = PDF points), as one page.
    func pdf(of rect: CGRect) async throws -> Data {
        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        return try await webView.pdf(configuration: configuration)
    }

    func snapshot(of rect: CGRect, pixelWidth: CGFloat) async throws -> CGImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: Double(pixelWidth / (window.backingScaleFactor > 0 ? window.backingScaleFactor : 1)))
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            throw WheelError("Vector artwork could not be rasterized.")
        }
        return cg
    }

    /// Prints the current page through WebKit's paginator into a PDF file.
    func print(to url: URL, paper: CGSize, margins: NSEdgeInsets) async throws {
        let info = NSPrintInfo()
        info.paperSize = paper
        info.topMargin = margins.top
        info.bottomMargin = margins.bottom
        info.leftMargin = margins.left
        info.rightMargin = margins.right
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.orientation = paper.width > paper.height ? .landscape : .portrait
        info.jobDisposition = .save
        info.dictionary().setObject(url, forKey: NSPrintInfo.AttributeKey.jobSavingURL as NSCopying)
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            printing = continuation
            operation.runModal(for: window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard ok, FileManager.default.fileExists(atPath: url.path), PDFDocument(url: url) != nil else {
            throw WheelError("The document could not be printed as PDF.")
        }
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printing?.resume(returning: success)
        printing = nil
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.navigation?.resume()
        self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: WheelError("The document could not load: \(error.localizedDescription)"))
        self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: WheelError("The document could not load: \(error.localizedDescription)"))
        self.navigation = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        switch url.scheme {
        case "about", "data", "blob":
            return .allow
        case "file":
            if let allowed = allowedDirectory {
                let path = url.standardizedFileURL.path
                guard path == allowed.path || path.hasPrefix(allowed.path + "/") else { return .cancel }
            }
            return .allow
        default:
            return .cancel
        }
    }
}

/// Merges single-document PDFs in order.
enum PDFMerge {
    static func combine(_ urls: [URL], to destination: URL) throws {
        let output = PDFDocument()
        for url in urls {
            guard let document = PDFDocument(url: url) else { throw WheelError("A rendered page is missing.") }
            for index in 0..<document.pageCount {
                if let page = document.page(at: index) { output.insert(page, at: output.pageCount) }
            }
        }
        guard output.pageCount > 0, output.write(to: destination) else {
            throw WheelError("The generated PDF could not be saved.")
        }
    }
}
