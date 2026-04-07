import SwiftUI
import WebKit

struct MarkdownPreviewView: NSViewRepresentable {
    let content: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let body = MarkdownRenderer.toHTML(content)
        webView.loadHTMLString(pageHTML(body: body), baseURL: nil)
    }

    // MARK: - Navigation Delegate

    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow the initial HTML load; intercept link clicks and open in system browser
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    // MARK: - HTML template

    private func pageHTML(body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
        <script>
        document.addEventListener("DOMContentLoaded", function() {
            mermaid.initialize({
                startOnLoad: false,
                theme: window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "default",
                securityLevel: "loose"
            });
            mermaid.run({ nodes: document.querySelectorAll(".mermaid") });
        });
        </script>
        <style>
        :root {
            --bg: transparent;
            --fg: #1a1a1a;
            --secondary: #555;
            --code-bg: #f0f0f0;
            --pre-bg: #f5f5f5;
            --quote-border: #ccc;
            --quote-fg: #555;
            --mark-bg: #fff176;
            --mark-fg: #1a1a1a;
            --link: #0066cc;
            --hr: #ddd;
            --del: #999;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --fg: #e0e0e0;
                --secondary: #aaa;
                --code-bg: #2a2a2a;
                --pre-bg: #252525;
                --quote-border: #555;
                --quote-fg: #aaa;
                --mark-bg: #5c4d00;
                --mark-fg: #f5e17a;
                --link: #4fa3e8;
                --hr: #444;
                --del: #777;
            }
        }
        * { box-sizing: border-box; }
        html, body {
            margin: 0; padding: 0;
            background: transparent;
            color: var(--fg);
            font-family: -apple-system, "Helvetica Neue", Arial, sans-serif;
            font-size: 15px;
            line-height: 1.75;
        }
        body { padding: 20px 24px 40px; max-width: 760px; }
        h1, h2, h3, h4, h5, h6 {
            color: var(--fg);
            margin: 1.4em 0 0.4em;
            line-height: 1.3;
            font-weight: 600;
        }
        h1:first-child, h2:first-child, h3:first-child { margin-top: 0.2em; }
        h1 { font-size: 1.9em; }
        h2 { font-size: 1.5em; }
        h3 { font-size: 1.25em; }
        h4 { font-size: 1.1em; }
        h5, h6 { font-size: 1em; color: var(--secondary); }
        p { margin: 0.5em 0 0.7em; }
        a { color: var(--link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        strong { font-weight: 700; }
        em { font-style: italic; }
        del { color: var(--del); text-decoration: line-through; }
        mark {
            background: var(--mark-bg);
            color: var(--mark-fg);
            padding: 0.05em 0.25em;
            border-radius: 3px;
        }
        code {
            font-family: "SF Mono", "Menlo", "Monaco", monospace;
            font-size: 0.875em;
            background: var(--code-bg);
            padding: 0.1em 0.35em;
            border-radius: 4px;
        }
        pre {
            background: var(--pre-bg);
            padding: 14px 18px;
            border-radius: 8px;
            overflow-x: auto;
            margin: 0.9em 0;
        }
        pre code {
            background: none;
            padding: 0;
            font-size: 0.875em;
            border-radius: 0;
        }
        blockquote {
            border-left: 3px solid var(--quote-border);
            padding: 0 0 0 16px;
            margin: 0.8em 0;
            color: var(--quote-fg);
        }
        blockquote p { margin: 0.3em 0; }
        ul, ol { padding-left: 1.8em; margin: 0.4em 0 0.6em; }
        li { margin: 0.2em 0; }
        li > ul, li > ol { margin: 0.1em 0; }
        ul.task-list { list-style: none; padding-left: 0.3em; }
        input[type="checkbox"] { margin-right: 0.45em; vertical-align: middle; }
        hr {
            border: none;
            border-top: 1px solid var(--hr);
            margin: 1.4em 0;
        }
        img { max-width: 100%; border-radius: 4px; }
        /* Mermaid diagram container */
        .mermaid {
            margin: 1.4em 0;
            text-align: center;
            background: transparent;
        }
        /* Footnote references in text */
        sup { font-size: 0.75em; line-height: 0; vertical-align: super; }
        a.footnote-ref {
            color: var(--link);
            text-decoration: none;
            font-weight: 500;
            padding: 0 0.1em;
        }
        a.footnote-ref:hover { text-decoration: underline; }
        /* Footnotes section */
        section.footnotes {
            margin-top: 2.5em;
            font-size: 0.875em;
            color: var(--secondary);
        }
        hr.footnotes-sep {
            border: none;
            border-top: 1px solid var(--hr);
            margin-bottom: 1em;
        }
        ol.footnotes-list {
            padding-left: 1.6em;
            margin: 0;
        }
        ol.footnotes-list li { margin: 0.35em 0; }
        ol.footnotes-list p { margin: 0; display: inline; }
        ol.footnotes-list img {
            display: block;
            max-width: 100%;
            border-radius: 4px;
            margin-top: 0.4em;
        }
        a.footnote-backref {
            color: var(--link);
            text-decoration: none;
            margin-left: 0.3em;
            font-size: 0.95em;
        }
        a.footnote-backref:hover { text-decoration: underline; }
        </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }
}
