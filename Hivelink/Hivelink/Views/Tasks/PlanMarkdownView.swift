//
//  PlanMarkdownView.swift
//  Hivelink
//
//  Renders plan markdown with Mermaid diagram support using WKWebView

import SwiftUI
import WebKit

struct PlanMarkdownView: UIViewRepresentable {
    let markdown: String

    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        loadContent(into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let newHash = "\(markdown.hashValue)-\(colorScheme)"
        guard newHash != context.coordinator.lastContentHash else { return }
        context.coordinator.lastContentHash = newHash
        loadContent(into: webView)
    }

    private func loadContent(into webView: WKWebView) {
        let html = Self.generateHTML(
            bodyHTML: Self.markdownToHTML(markdown),
            isDark: colorScheme == .dark
        )
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKNavigationDelegate {
        var lastContentHash: String?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}
    }

    // MARK: - Swift-side Markdown → HTML

    private static func markdownToHTML(_ md: String) -> String {
        var lines = md.components(separatedBy: "\n")
        var html: [String] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let cl = lines[i]
                    if cl.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(cl)
                    i += 1
                }
                let codeContent = codeLines.joined(separator: "\n")
                if lang.lowercased() == "mermaid" {
                    let escaped = escapeHTML(codeContent)
                    let id = "mermaid-\(abs(codeContent.hashValue))"
                    html.append("""
                    <div class="mermaid-container">\
                    <div class="mermaid" id="\(id)">\(escaped)</div>\
                    </div>
                    """)
                } else {
                    html.append("<pre><code>\(escapeHTML(codeContent))</code></pre>")
                }
                continue
            }

            // Horizontal rule
            if trimmed.range(of: #"^[-*_]{3,}$"#, options: .regularExpression) != nil {
                html.append("<hr>")
                i += 1
                continue
            }

            // Headings
            if let match = trimmed.range(of: #"^(#{1,6})\s+(.+)$"#, options: .regularExpression) {
                let content = String(trimmed[match])
                let level = content.prefix(while: { $0 == "#" }).count
                let text = String(content.drop(while: { $0 == "#" }).dropFirst())
                html.append("<h\(level)>\(inlineMarkdown(text))</h\(level)>")
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let ql = lines[i].trimmingCharacters(in: .whitespaces)
                    guard ql.hasPrefix(">") else { break }
                    let stripped = String(ql.dropFirst()).trimmingCharacters(in: .init(charactersIn: " "))
                    quoteLines.append(stripped)
                    i += 1
                }
                html.append("<blockquote>\(inlineMarkdown(quoteLines.joined(separator: "<br>")))</blockquote>")
                continue
            }

            // Unordered list / task list
            if trimmed.range(of: #"^[-*+]\s"#, options: .regularExpression) != nil {
                html.append("<ul>")
                while i < lines.count {
                    let li = lines[i].trimmingCharacters(in: .whitespaces)
                    guard li.range(of: #"^[-*+]\s"#, options: .regularExpression) != nil else { break }
                    let content = String(li.dropFirst(2))
                    if content.hasPrefix("[ ] ") {
                        let text = String(content.dropFirst(4))
                        html.append("<li class=\"task-list-item\"><input type=\"checkbox\" disabled> \(inlineMarkdown(text))</li>")
                    } else if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") {
                        let text = String(content.dropFirst(4))
                        html.append("<li class=\"task-list-item\"><input type=\"checkbox\" checked disabled> \(inlineMarkdown(text))</li>")
                    } else {
                        html.append("<li>\(inlineMarkdown(content))</li>")
                    }
                    i += 1
                }
                html.append("</ul>")
                continue
            }

            // Ordered list
            if trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                html.append("<ol>")
                while i < lines.count {
                    let li = lines[i].trimmingCharacters(in: .whitespaces)
                    guard li.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil else { break }
                    if let dotRange = li.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                        let content = String(li[dotRange.upperBound...])
                        html.append("<li>\(inlineMarkdown(content))</li>")
                    }
                    i += 1
                }
                html.append("</ol>")
                continue
            }

            // Empty line
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Paragraph (collect consecutive non-empty, non-special lines)
            var paraLines: [String] = []
            while i < lines.count {
                let pl = lines[i].trimmingCharacters(in: .whitespaces)
                if pl.isEmpty || pl.hasPrefix("#") || pl.hasPrefix("```") ||
                    pl.hasPrefix(">") || pl.range(of: #"^[-*+]\s"#, options: .regularExpression) != nil ||
                    pl.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil ||
                    pl.range(of: #"^[-*_]{3,}$"#, options: .regularExpression) != nil {
                    break
                }
                paraLines.append(pl)
                i += 1
            }
            if !paraLines.isEmpty {
                html.append("<p>\(inlineMarkdown(paraLines.joined(separator: " ")))</p>")
            }
        }

        return html.joined(separator: "\n")
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func inlineMarkdown(_ text: String) -> String {
        var s = escapeHTML(text)
        // Inline code (before bold/italic to avoid conflicts)
        s = s.replacingOccurrences(
            of: #"`([^`]+)`"#,
            with: "<code>$1</code>",
            options: .regularExpression
        )
        // Bold
        s = s.replacingOccurrences(
            of: #"\*\*(.+?)\*\*"#,
            with: "<strong>$1</strong>",
            options: .regularExpression
        )
        // Italic
        s = s.replacingOccurrences(
            of: #"\*(.+?)\*"#,
            with: "<em>$1</em>",
            options: .regularExpression
        )
        // Links
        s = s.replacingOccurrences(
            of: #"\[([^\]]+)\]\(([^)]+)\)"#,
            with: "<a href=\"$2\">$1</a>",
            options: .regularExpression
        )
        return s
    }

    // MARK: - HTML Generation

    private static func generateHTML(bodyHTML: String, isDark: Bool) -> String {
        let bg = isDark ? "#000000" : "#ffffff"
        let fg = isDark ? "#e0e0e0" : "#1c1c1e"
        let mutedFg = isDark ? "#8e8e93" : "#6e6e73"
        let codeBg = isDark ? "#1c1c1e" : "#f2f2f7"
        let borderColor = isDark ? "#38383a" : "#d1d1d6"
        let linkColor = isDark ? "#64d2ff" : "#007aff"
        let checkColor = isDark ? "#30d158" : "#34c759"
        let mermaidTheme = isDark ? "dark" : "default"

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body {
                background: \(bg);
                color: \(fg);
                font-family: -apple-system, system-ui, sans-serif;
                font-size: 15px;
                line-height: 1.5;
                -webkit-text-size-adjust: 100%;
            }
            #content { padding: 16px 16px 40px; }
            h1 { font-size: 22px; font-weight: 700; margin: 16px 0 8px; }
            h2 { font-size: 19px; font-weight: 600; margin: 20px 0 6px; }
            h3 { font-size: 17px; font-weight: 600; margin: 16px 0 4px; }
            h4, h5, h6 { font-size: 15px; font-weight: 600; margin: 12px 0 4px; }
            p { margin: 8px 0; }
            ul, ol { margin: 6px 0; padding-left: 24px; }
            li { margin: 3px 0; }
            li.task-list-item {
                list-style: none;
                margin-left: -24px;
                padding-left: 0;
            }
            li.task-list-item input[type="checkbox"] {
                -webkit-appearance: none;
                appearance: none;
                width: 18px; height: 18px;
                border: 2px solid \(borderColor);
                border-radius: 4px;
                vertical-align: middle;
                margin-right: 6px;
                position: relative;
                top: -1px;
            }
            li.task-list-item input[type="checkbox"]:checked {
                background: \(checkColor);
                border-color: \(checkColor);
            }
            li.task-list-item input[type="checkbox"]:checked::after {
                content: '\\2713';
                color: white;
                font-size: 13px;
                font-weight: 700;
                position: absolute;
                top: -1px; left: 2px;
            }
            a { color: \(linkColor); text-decoration: none; }
            code {
                font-family: 'SF Mono', ui-monospace, monospace;
                font-size: 13px;
                background: \(codeBg);
                padding: 2px 5px;
                border-radius: 4px;
            }
            pre {
                background: \(codeBg);
                border: 1px solid \(borderColor);
                border-radius: 8px;
                padding: 12px;
                overflow-x: auto;
                margin: 10px 0;
            }
            pre code { background: none; padding: 0; font-size: 13px; }
            blockquote {
                border-left: 3px solid \(borderColor);
                padding-left: 12px;
                color: \(mutedFg);
                margin: 8px 0;
            }
            hr { border: none; border-top: 1px solid \(borderColor); margin: 16px 0; }
            table {
                border-collapse: collapse;
                width: 100%;
                margin: 10px 0;
                font-size: 14px;
            }
            th, td {
                border: 1px solid \(borderColor);
                padding: 6px 10px;
                text-align: left;
            }
            th { font-weight: 600; background: \(codeBg); }
            strong { font-weight: 600; }
            .mermaid-container {
                margin: 12px 0;
                border: 1px solid \(borderColor);
                border-radius: 8px;
                overflow: hidden;
                padding: 12px;
                text-align: center;
            }
            .mermaid-container .mermaid-fallback {
                font-family: 'SF Mono', ui-monospace, monospace;
                font-size: 12px;
                color: \(mutedFg);
                white-space: pre-wrap;
                text-align: left;
            }
            .mermaid svg { max-width: 100%; height: auto; }
        </style>
        </head>
        <body>
        <div id="content">\(bodyHTML)</div>
        <script>
        (function() {
            var els = document.querySelectorAll('.mermaid');
            if (els.length === 0) return;

            var s = document.createElement('script');
            s.src = 'https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js';
            s.onload = function() {
                mermaid.initialize({
                    startOnLoad: false,
                    theme: '\(mermaidTheme)',
                    securityLevel: 'loose',
                    flowchart: { useMaxWidth: true, htmlLabels: true, curve: 'basis' },
                    sequence: { useMaxWidth: true },
                    gantt: { useMaxWidth: true }
                });
                els.forEach(function(el) {
                    var code = el.textContent;
                    var id = el.id + '-svg';
                    mermaid.render(id, code).then(function(result) {
                        el.innerHTML = result.svg;
                    }).catch(function(err) {
                        el.innerHTML = '<div class="mermaid-fallback">' +
                            el.textContent.replace(/</g,'&lt;') + '</div>';
                    });
                });
            };
            s.onerror = function() {
                els.forEach(function(el) {
                    el.innerHTML = '<div class="mermaid-fallback">' +
                        el.textContent.replace(/</g,'&lt;') + '</div>';
                });
            };
            document.head.appendChild(s);
        })();
        </script>
        </body>
        </html>
        """
    }
}
