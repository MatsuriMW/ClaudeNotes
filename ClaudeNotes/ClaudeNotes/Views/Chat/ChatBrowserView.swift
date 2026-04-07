import SwiftUI

struct ChatBrowserView: View {
    let provider: LLMProvider

    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var currentURL = ""
    @State private var goBackTrigger = false
    @State private var goForwardTrigger = false
    @State private var reloadTrigger = false

    var body: some View {
        VStack(spacing: 0) {
            // Navigation bar
            HStack(spacing: 12) {
                // Back / Forward
                HStack(spacing: 4) {
                    Button {
                        goBackTrigger.toggle()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!canGoBack)
                    .help("后退")

                    Button {
                        goForwardTrigger.toggle()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!canGoForward)
                    .help("前进")
                }
                .buttonStyle(.borderless)

                // Reload
                Button {
                    reloadTrigger.toggle()
                } label: {
                    Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(isLoading ? "停止" : "重新加载")

                // URL display
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }

                    Text(displayURL)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Home button - go back to provider's main page
                Button {
                    // Reset by removing cached webview and reloading
                    goToHome()
                } label: {
                    Image(systemName: "house")
                }
                .buttonStyle(.borderless)
                .help("回到首页")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Web content
            LLMWebView(
                provider: provider,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                isLoading: $isLoading,
                currentURL: $currentURL,
                goBackTrigger: goBackTrigger,
                goForwardTrigger: goForwardTrigger,
                reloadTrigger: reloadTrigger
            )
        }
    }

    private var displayURL: String {
        guard !currentURL.isEmpty else { return provider.url.absoluteString }
        return currentURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private func goToHome() {
        let webView = WebViewStore.shared.webView(for: provider)
        let request = URLRequest(url: provider.url)
        webView.load(request)
    }
}
