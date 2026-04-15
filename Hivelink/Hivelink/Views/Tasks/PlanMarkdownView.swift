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
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = Self.generateHTML(markdown: markdown, isDark: colorScheme == .dark)
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}
    }

    private static func generateHTML(markdown: String, isDark: Bool) -> String {
        let escaped = markdown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

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
                font: -apple-system-body;
                font-family: -apple-system, system-ui, sans-serif;
                font-size: 15px;
                line-height: 1.5;
                padding: 0;
                -webkit-text-size-adjust: 100%;
            }
            #content {
                padding: 0 4px 40px 4px;
            }
            h1 { font-size: 22px; font-weight: 700; margin: 16px 0 8px; }
            h2 { font-size: 19px; font-weight: 600; margin: 20px 0 6px; }
            h3 { font-size: 17px; font-weight: 600; margin: 16px 0 4px; }
            p { margin: 8px 0; }
            ul, ol { margin: 6px 0; padding-left: 24px; }
            li { margin: 3px 0; }
            li.task-list-item {
                list-style: none;
                margin-left: -24px;
                padding-left: 0;
            }
            li.task-list-item input[type="checkbox"] {
                appearance: none;
                -webkit-appearance: none;
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
                content: '✓';
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
            pre code {
                background: none;
                padding: 0;
                font-size: 13px;
            }
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
            .mermaid svg { max-width: 100%; height: auto; }
        </style>
        </head>
        <body>
        <div id="content"></div>
        <script src="https://cdn.jsdelivr.net/npm/marked@12/marked.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
        <script>
            mermaid.initialize({
                startOnLoad: false,
                theme: '\(mermaidTheme)',
                securityLevel: 'loose',
                flowchart: { useMaxWidth: true, htmlLabels: true, curve: 'basis' },
                sequence: { useMaxWidth: true },
                gantt: { useMaxWidth: true }
            });

            const renderer = new marked.Renderer();

            // Wrap mermaid code blocks so we can render them after marked runs
            renderer.code = function({ text, lang }) {
                if (lang === 'mermaid') {
                    const id = 'mermaid-' + Math.random().toString(36).substr(2, 9);
                    return '<div class="mermaid-container"><div class="mermaid" id="' + id + '">' +
                           text.replace(/</g, '&lt;').replace(/>/g, '&gt;') +
                           '</div></div>';
                }
                return '<pre><code>' + text.replace(/</g, '&lt;').replace(/>/g, '&gt;') + '</code></pre>';
            };

            marked.setOptions({ renderer: renderer, gfm: true, breaks: false });

            const md = `\(escaped)`;
            document.getElementById('content').innerHTML = marked.parse(md);

            // Render all mermaid diagrams
            document.querySelectorAll('.mermaid').forEach(async (el) => {
                try {
                    const { svg } = await mermaid.render(el.id + '-svg', el.textContent);
                    el.innerHTML = svg;
                } catch (e) {
                    el.innerHTML = '<span style="color:#ff6b6b;">Diagram error: ' + e.message + '</span>';
                }
            });
        </script>
        </body>
        </html>
        """
    }
}
