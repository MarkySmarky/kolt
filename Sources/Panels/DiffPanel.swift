import Foundation
import Combine
import WebKit
import AppKit
import Bonsplit

/// A panel that displays a live git diff viewer using a WKWebView.
/// Watches the git working directory for changes and renders diffs
/// via a bundled HTML/JS diff viewer.
@MainActor
final class DiffPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .diff

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Title shown in the tab bar (branch name or "Changes").
    @Published private(set) var displayTitle: String = String(
        localized: "diff.defaultTitle",
        defaultValue: "Changes"
    )

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "arrow.left.arrow.right" }

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// The WKWebView used to render the diff viewer.
    private(set) var webView: WKWebView

    /// Git watcher that monitors the working directory.
    private(set) var gitWatcher: GitWatcher

    /// Combine subscriptions for GitWatcher updates.
    private var cancellables = Set<AnyCancellable>()

    /// Script message handler name for communication from the web view.
    static let messageHandlerName = "diffPanel"

    /// Whether the HTML page has finished loading and is ready for JS calls.
    private var isWebViewReady: Bool = false

    /// Queued updates to send once the web view is ready.
    private var pendingFileListUpdate: String?
    private var pendingDiffUpdate: String?

    /// The working directory this panel is associated with.
    let workingDirectory: String

    // MARK: - Init

    init(workspaceId: UUID, workingDirectory: String, gitWatcher: GitWatcher) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.workingDirectory = workingDirectory

        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView

        self.gitWatcher = gitWatcher

        let handler = DiffPanelScriptMessageHandler()
        handler.panel = self
        userContentController.add(handler, name: Self.messageHandlerName)

        subscribeToGitWatcher()
    }

    // MARK: - Panel Protocol

    func focus() {
        // The diff panel focuses the web view for keyboard navigation.
        if let window = webView.window {
            window.makeFirstResponder(webView)
        }
    }

    func unfocus() {
        // No-op; the web view resigns naturally when another responder takes over.
    }

    func close() {
        cancellables.removeAll()
        // Do NOT stop the gitWatcher here — the workspace manages the shared watcher lifecycle.
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.messageHandlerName
        )
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        guard let window else { return .panel }
        let firstResponder = window.firstResponder
        if firstResponder === webView || isResponderInWebView(firstResponder) {
            return .diff(.webView)
        }
        return .panel
    }

    func preferredFocusIntentForActivation() -> PanelFocusIntent {
        .diff(.webView)
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .diff(.webView):
            focus()
            return true
        case .panel:
            focus()
            return true
        default:
            return false
        }
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        _ = window
        if responder === webView || isResponderInWebView(responder) {
            return .diff(.webView)
        }
        return nil
    }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        _ = intent
        _ = window
        return false
    }

    // MARK: - Web View Loading

    /// Load the bundled diff viewer HTML into the web view.
    func loadDiffViewer() {
        guard let resourceURL = Bundle.main.resourceURL else {
            #if DEBUG
            dlog("[DiffPanel] Bundle.main.resourceURL is nil")
            #endif
            return
        }

        let diffViewerDir = resourceURL.appendingPathComponent("diff-viewer")
        let indexURL = diffViewerDir.appendingPathComponent("index.html")

        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            #if DEBUG
            dlog("[DiffPanel] diff-viewer/index.html not found at \(indexURL.path)")
            #endif
            return
        }

        webView.loadFileURL(indexURL, allowingReadAccessTo: diffViewerDir)
    }

    /// Called by the navigation delegate when the page finishes loading.
    func webViewDidFinishLoading() {
        isWebViewReady = true

        // Flush any pending updates that arrived before the page was ready.
        if let files = pendingFileListUpdate {
            pushFileListToWebView(files)
            pendingFileListUpdate = nil
        }
        if let diff = pendingDiffUpdate {
            pushDiffToWebView(diff)
            pendingDiffUpdate = nil
        }
    }

    /// Force a refresh of the git watcher data.
    func forceRefresh() {
        gitWatcher.refresh()
    }

    // MARK: - Private

    private func subscribeToGitWatcher() {
        gitWatcher.$changedFiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] files in
                self?.handleChangedFilesUpdate(files)
            }
            .store(in: &cancellables)

        gitWatcher.$currentDiff
            .receive(on: DispatchQueue.main)
            .sink { [weak self] diff in
                self?.handleDiffUpdate(diff)
            }
            .store(in: &cancellables)

        gitWatcher.$branchName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] branch in
                if let branch, !branch.isEmpty {
                    self?.displayTitle = branch
                } else {
                    self?.displayTitle = String(
                        localized: "diff.defaultTitle",
                        defaultValue: "Changes"
                    )
                }
            }
            .store(in: &cancellables)
    }

    private func handleChangedFilesUpdate(_ files: [ChangedFile]) {
        let jsonArray = files.map { file -> [String: Any] in
            [
                "path": file.path,
                "status": file.status,
                "insertions": file.insertions,
                "deletions": file.deletions
            ]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: jsonArray),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        if isWebViewReady {
            pushFileListToWebView(jsonString)
        } else {
            pendingFileListUpdate = jsonString
        }
    }

    private func handleDiffUpdate(_ diff: String) {
        // Escape the diff text for safe JavaScript string embedding.
        let escaped = escapeForJavaScript(diff)

        if isWebViewReady {
            pushDiffToWebView(escaped)
        } else {
            pendingDiffUpdate = escaped
        }
    }

    private func pushFileListToWebView(_ jsonString: String) {
        let js = "window.updateFileList(\(jsonString));"
        webView.evaluateJavaScript(js) { _, error in
            #if DEBUG
            if let error {
                dlog("[DiffPanel] updateFileList JS error: \(error)")
            }
            #endif
        }
    }

    private func pushDiffToWebView(_ escapedDiff: String) {
        let js = "window.updateFileDiff(\"\(escapedDiff)\");"
        webView.evaluateJavaScript(js) { _, error in
            #if DEBUG
            if let error {
                dlog("[DiffPanel] updateFileDiff JS error: \(error)")
            }
            #endif
        }
    }

    private func escapeForJavaScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func isResponderInWebView(_ responder: NSResponder?) -> Bool {
        var current: NSResponder? = responder
        while let node = current {
            if node === webView {
                return true
            }
            current = node.nextResponder
        }
        return false
    }

    // MARK: - Script Message Handling

    /// Handle messages from the web view JavaScript.
    func handleScriptMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            return
        }

        switch action {
        case "selectFile":
            if let path = body["path"] as? String {
                gitWatcher.selectFile(path)
            }
        case "ready":
            webViewDidFinishLoading()
        case "stageFile":
            if let path = body["path"] as? String {
                gitWatcher.stageFile(path) { [weak self] _ in
                    self?.gitWatcher.refresh()
                }
            }
        case "unstageFile":
            if let path = body["path"] as? String {
                gitWatcher.unstageFile(path) { [weak self] _ in
                    self?.gitWatcher.refresh()
                }
            }
        case "revertFile":
            if let path = body["path"] as? String {
                gitWatcher.revertFile(path) { [weak self] _ in
                    self?.gitWatcher.refresh()
                }
            }
        case "stageAll":
            gitWatcher.stageAll { [weak self] _ in
                self?.gitWatcher.refresh()
            }
        case "revertAll":
            gitWatcher.revertAll { [weak self] _ in
                self?.gitWatcher.refresh()
            }
        default:
            #if DEBUG
            dlog("[DiffPanel] Unknown script message action: \(action)")
            #endif
            break
        }
    }
}

// MARK: - Script Message Handler

/// Non-isolated message handler that forwards messages to the DiffPanel on the main actor.
/// WKScriptMessageHandler methods are called on the main thread by WebKit,
/// but the protocol is not annotated as @MainActor.
final class DiffPanelScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var panel: DiffPanel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            panel?.handleScriptMessage(message)
        }
    }
}
