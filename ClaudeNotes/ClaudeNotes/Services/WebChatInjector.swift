import Foundation
import WebKit

/// Handles injecting note content into web-based LLM chat inputs
enum WebChatInjector {

    /// Injects text into the chat input of the given provider's web view.
    /// Returns a user-facing status message.
    @MainActor
    static func injectNoteContent(_ text: String, into webView: WKWebView, provider: LLMProvider) async -> InjectResult {
        let escaped = escapeForJS(text)

        // Build provider-specific + generic JS
        let script = buildInjectionScript(escapedText: escaped, providerId: provider.id)

        do {
            let result = try await webView.evaluateJavaScript(script)
            if let dict = result as? [String: Any],
               let ok = dict["ok"] as? Bool, ok {
                return .success
            } else if let dict = result as? [String: Any],
                      let error = dict["error"] as? String {
                return .failed(error)
            }
            // If JS returned a string result (some evaluations do)
            if let str = result as? String, str == "SUCCESS" {
                return .success
            }
            return .failed("UNKNOWN")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    enum InjectResult {
        case success
        case failed(String)

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    // MARK: - Script Building

    private static func buildInjectionScript(escapedText: String, providerId: String) -> String {
        """
        (function() {
            var text = "\(escapedText)";

            // Provider-specific selectors (ordered by priority)
            var selectorSets = {
                'claude': [
                    'div.ProseMirror[contenteditable="true"]',
                    'fieldset div[contenteditable="true"]',
                    'div[contenteditable="true"][translate="no"]'
                ],
                'chatgpt': [
                    'div#prompt-textarea[contenteditable="true"]',
                    'div#prompt-textarea',
                    'textarea#prompt-textarea'
                ],
                'gemini': [
                    'div.ql-editor[contenteditable="true"]',
                    'rich-textarea div[contenteditable="true"]',
                    'div[contenteditable="true"][role="textbox"]'
                ],
                'deepseek': [
                    'textarea#chat-input',
                    'textarea.n-input__textarea-el',
                    'textarea[placeholder]'
                ],
                'grok': [
                    'textarea[placeholder]',
                    'div[contenteditable="true"][role="textbox"]'
                ],
                'copilot': [
                    'textarea#searchbox',
                    'textarea[name="searchbox"]',
                    'cib-serp textarea',
                    'textarea[placeholder]'
                ],
                'poe': [
                    'textarea.GrowingTextArea_textArea__ZWQbP',
                    'div[contenteditable="true"][role="textbox"]',
                    'textarea[placeholder]'
                ]
            };

            // Generic fallback selectors
            var genericSelectors = [
                'div[contenteditable="true"][role="textbox"]',
                'div[contenteditable="true"][data-placeholder]',
                'div.ProseMirror[contenteditable="true"]',
                'div[contenteditable="true"]',
                'textarea:not([readonly]):not([disabled])'
            ];

            var providerSels = selectorSets['\(providerId)'] || [];
            var allSelectors = providerSels.concat(genericSelectors);

            var input = null;
            for (var i = 0; i < allSelectors.length; i++) {
                var els = document.querySelectorAll(allSelectors[i]);
                // Pick the last visible one (chat input is usually at the bottom)
                for (var j = 0; j < els.length; j++) {
                    var el = els[j];
                    if (el.offsetParent !== null || el.offsetHeight > 0 || el.offsetWidth > 0) {
                        input = el;
                    }
                }
                if (input) break;
            }

            if (!input) {
                return {ok: false, error: 'NO_INPUT_FOUND'};
            }

            // Focus the element
            input.focus();
            input.click();

            var isContentEditable = (input.contentEditable === 'true' || input.isContentEditable);
            var isTextArea = (input.tagName === 'TEXTAREA' || input.tagName === 'INPUT');

            if (isContentEditable) {
                // --- ContentEditable (Claude, ChatGPT, Gemini, etc.) ---

                // Method 1: execCommand (works with ProseMirror & most editors)
                // Select all existing content first
                var sel = window.getSelection();
                var range = document.createRange();
                range.selectNodeContents(input);
                sel.removeAllRanges();
                sel.addRange(range);

                // Try execCommand insertText (triggers all editor event handlers)
                var success = document.execCommand('insertText', false, text);

                if (!success) {
                    // Method 2: Direct DOM manipulation + input events
                    // Split text into paragraphs
                    var paragraphs = text.split('\\n');
                    var html = paragraphs.map(function(p) {
                        return '<p>' + p.replace(/</g, '&lt;').replace(/>/g, '&gt;') + '</p>';
                    }).join('');
                    input.innerHTML = html;
                    input.dispatchEvent(new Event('input', {bubbles: true}));
                    input.dispatchEvent(new Event('change', {bubbles: true}));
                }

                // Move cursor to end
                var endRange = document.createRange();
                endRange.selectNodeContents(input);
                endRange.collapse(false);
                sel.removeAllRanges();
                sel.addRange(endRange);

                return {ok: true, method: 'contenteditable'};

            } else if (isTextArea) {
                // --- Textarea (DeepSeek, some others) ---

                // Use native setter to bypass React's synthetic event system
                var nativeSetter = Object.getOwnPropertyDescriptor(
                    window.HTMLTextAreaElement.prototype, 'value'
                );
                if (nativeSetter && nativeSetter.set) {
                    nativeSetter.set.call(input, text);
                } else {
                    input.value = text;
                }

                // Dispatch events React/Vue listen to
                input.dispatchEvent(new Event('input', {bubbles: true}));
                input.dispatchEvent(new Event('change', {bubbles: true}));

                // Some frameworks need this
                var inputEvent = new InputEvent('input', {
                    bubbles: true,
                    cancelable: true,
                    inputType: 'insertText',
                    data: text
                });
                input.dispatchEvent(inputEvent);

                // Auto-resize textarea if it has auto-height
                input.style.height = 'auto';
                input.style.height = input.scrollHeight + 'px';

                return {ok: true, method: 'textarea'};
            }

            return {ok: false, error: 'UNSUPPORTED_INPUT_TYPE'};
        })();
        """
    }

    /// Build a script that clicks the send/submit button after injection
    static func buildSendButtonScript(providerId: String) -> String {
        """
        (function() {
            var sendSelectors = {
                'claude': ['button[aria-label="Send Message"]', 'button[type="submit"]'],
                'chatgpt': ['button[data-testid="send-button"]', 'button[aria-label="Send prompt"]'],
                'gemini': ['button[aria-label="Send message"]', 'button.send-button'],
                'deepseek': ['button[aria-label="Send"]', 'div.ds-icon-button'],
                'grok': ['button[aria-label="Submit"]', 'button[type="submit"]'],
                'copilot': ['button[aria-label="Submit"]'],
                'poe': ['button.ChatMessageSendButton_sendButton']
            };

            var genericSend = [
                'button[type="submit"]',
                'button[aria-label*="send" i]',
                'button[aria-label*="Send"]',
                'button[aria-label*="Submit"]'
            ];

            var sels = (sendSelectors['\(providerId)'] || []).concat(genericSend);

            for (var i = 0; i < sels.length; i++) {
                var btn = document.querySelector(sels[i]);
                if (btn && !btn.disabled && (btn.offsetParent !== null || btn.offsetHeight > 0)) {
                    // Small delay to let the input events propagate
                    setTimeout(function() { btn.click(); }, 200);
                    return {ok: true};
                }
            }
            return {ok: false, error: 'NO_SEND_BUTTON'};
        })();
        """
    }

    // MARK: - Helpers

    private static func escapeForJS(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}
