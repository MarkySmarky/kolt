import AppKit
import SwiftUI
import WebKit

/// SwiftUI view that wraps the DiffPanel's WKWebView for rendering git diffs.
struct DiffPanelView: View {
    @ObservedObject var panel: DiffPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0

    var body: some View {
        DiffWebViewRepresentable(panel: panel, onRequestPanelFocus: onRequestPanelFocus)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                    .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                    .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                    .padding(FocusFlashPattern.ringInset)
                    .allowsHitTesting(false)
            }
            .onAppear {
                panel.loadDiffViewer()
            }
            .onChange(of: panel.focusFlashToken) { _ in
                triggerFocusFlashAnimation()
            }
    }

    // MARK: - Focus Flash

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}

// MARK: - NSViewRepresentable

/// Wraps the DiffPanel's WKWebView as an NSViewRepresentable for embedding in SwiftUI.
private struct DiffWebViewRepresentable: NSViewRepresentable {
    let panel: DiffPanel
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRequestPanelFocus: onRequestPanelFocus)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true

        let webView = panel.webView
        webView.navigationDelegate = context.coordinator
        webView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onRequestPanelFocus = onRequestPanelFocus

        // Ensure the web view is still in the container.
        let webView = panel.webView
        if webView.superview !== nsView {
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            nsView.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: nsView.topAnchor),
                webView.bottomAnchor.constraint(equalTo: nsView.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: nsView.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: nsView.trailingAnchor)
            ])
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onRequestPanelFocus: () -> Void

        init(onRequestPanelFocus: @escaping () -> Void) {
            self.onRequestPanelFocus = onRequestPanelFocus
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Page readiness is signaled by the "ready" script message from JS,
            // which routes through DiffPanelScriptMessageHandler to webViewDidFinishLoading().
            // No additional action needed here.
        }
    }
}
