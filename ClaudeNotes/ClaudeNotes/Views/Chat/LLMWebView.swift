import SwiftUI
import WebKit

/// A persistent WKWebView wrapper that preserves login sessions
struct LLMWebView: NSViewRepresentable {
    let provider: LLMProvider
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var isLoading: Bool
    @Binding var currentURL: String

    // Action triggers
    var goBackTrigger: Bool
    var goForwardTrigger: Bool
    var reloadTrigger: Bool

    func makeNSView(context: Context) -> WKWebView {
        let webView = WebViewStore.shared.webView(for: provider)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // Load URL if the web view hasn't loaded anything yet
        if webView.url == nil {
            let request = URLRequest(url: provider.url)
            webView.load(request)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Handle navigation actions via trigger changes
        if goBackTrigger != context.coordinator.lastGoBack {
            context.coordinator.lastGoBack = goBackTrigger
            if webView.canGoBack { webView.goBack() }
        }
        if goForwardTrigger != context.coordinator.lastGoForward {
            context.coordinator.lastGoForward = goForwardTrigger
            if webView.canGoForward { webView.goForward() }
        }
        if reloadTrigger != context.coordinator.lastReload {
            context.coordinator.lastReload = reloadTrigger
            webView.reload()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: LLMWebView
        var lastGoBack = false
        var lastGoForward = false
        var lastReload = false

        init(_ parent: LLMWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.canGoBack = webView.canGoBack
                self.parent.canGoForward = webView.canGoForward
                self.parent.currentURL = webView.url?.absoluteString ?? ""
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.canGoBack = webView.canGoBack
                self.parent.canGoForward = webView.canGoForward
                self.parent.currentURL = webView.url?.absoluteString ?? ""
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        // Handle target="_blank" links (open in same web view)
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil || !(navigationAction.targetFrame!.isMainFrame) {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // Handle permission requests (camera, microphone for voice features)
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.prompt)
        }
    }
}

/// Manages persistent WKWebView instances to preserve login sessions
class WebViewStore {
    static let shared = WebViewStore()

    private var webViews: [String: WKWebView] = [:]
    private let configuration: WKWebViewConfiguration

    private init() {
        // Use a persistent data store so cookies/sessions survive app restarts
        let dataStore = WKWebsiteDataStore.default()

        configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.isElementFullscreenEnabled = true

        // Allow JavaScript
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = prefs
    }

    func webView(for provider: LLMProvider) -> WKWebView {
        if let existing = webViews[provider.id] {
            return existing
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        webViews[provider.id] = webView
        return webView
    }

    func clearData(for provider: LLMProvider) {
        webViews.removeValue(forKey: provider.id)
    }

    func clearAllData() {
        webViews.removeAll()
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {}
    }
}
