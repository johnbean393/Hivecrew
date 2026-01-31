//
//  MermaidDiagramView.swift
//  Hivecrew
//
//  Renders Mermaid diagrams using WebKit
//

import SwiftUI
import WebKit

/// A view that renders Mermaid diagram code using WKWebView
struct MermaidDiagramView: NSViewRepresentable {
    /// The Mermaid diagram code to render
    let code: String
    
    /// Optional fixed height for the diagram
    var fixedHeight: CGFloat?
    
    @Environment(\.colorScheme) private var colorScheme
    
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        
        // Allow the web view to resize based on content
        webView.enclosingScrollView?.hasVerticalScroller = false
        webView.enclosingScrollView?.hasHorizontalScroller = false
        
        return webView
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        let html = generateHTML(code: code, isDark: colorScheme == .dark)
        webView.loadHTMLString(html, baseURL: nil)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    /// Generate the HTML page that renders the Mermaid diagram
    private func generateHTML(code: String, isDark: Bool) -> String {
        let escapedCode = code
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        
        let theme = isDark ? "dark" : "default"
        let backgroundColor = isDark ? "#1e1e1e" : "#ffffff"
        let textColor = isDark ? "#ffffff" : "#000000"
        let controlBg = isDark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.05)"
        let controlHoverBg = isDark ? "rgba(255,255,255,0.2)" : "rgba(0,0,0,0.1)"
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                }
                html, body {
                    background-color: \(backgroundColor);
                    color: \(textColor);
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    overflow: hidden;
                    height: 100%;
                }
                #wrapper {
                    position: relative;
                    width: 100%;
                    height: 100%;
                    overflow: hidden;
                }
                #container {
                    width: 100%;
                    height: 100%;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    cursor: grab;
                }
                #container:active {
                    cursor: grabbing;
                }
                #diagram {
                    transform-origin: center center;
                    transition: transform 0.1s ease-out;
                }
                #diagram svg {
                    max-width: none;
                    height: auto;
                }
                .controls {
                    position: absolute;
                    bottom: 8px;
                    right: 8px;
                    display: flex;
                    gap: 4px;
                    z-index: 100;
                }
                .controls button {
                    width: 28px;
                    height: 28px;
                    border: none;
                    border-radius: 4px;
                    background: \(controlBg);
                    color: \(textColor);
                    font-size: 14px;
                    cursor: pointer;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                }
                .controls button:hover {
                    background: \(controlHoverBg);
                }
                .error {
                    color: #ff6b6b;
                    padding: 16px;
                    font-size: 14px;
                    background: rgba(255, 107, 107, 0.1);
                    border-radius: 8px;
                    margin: 16px;
                }
                .loading {
                    color: #888;
                    font-size: 14px;
                }
            </style>
        </head>
        <body>
            <div id="wrapper">
                <div id="container">
                    <div id="diagram" class="loading">Loading diagram...</div>
                </div>
                <div class="controls">
                    <button onclick="zoomIn()" title="Zoom In">+</button>
                    <button onclick="zoomOut()" title="Zoom Out">−</button>
                    <button onclick="resetView()" title="Reset View">⟲</button>
                </div>
            </div>
            <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
            <script>
                mermaid.initialize({
                    startOnLoad: false,
                    theme: '\(theme)',
                    securityLevel: 'loose',
                    flowchart: {
                        useMaxWidth: false,
                        htmlLabels: true,
                        curve: 'basis'
                    },
                    sequence: {
                        useMaxWidth: false
                    },
                    gantt: {
                        useMaxWidth: false
                    }
                });
                
                let scale = 1;
                let initialScale = 1;
                let translateX = 0;
                let translateY = 0;
                let isDragging = false;
                let startX, startY;
                
                function updateTransform() {
                    const diagram = document.getElementById('diagram');
                    diagram.style.transform = `translate(${translateX}px, ${translateY}px) scale(${scale})`;
                }
                
                function fitToView() {
                    const container = document.getElementById('container');
                    const diagram = document.getElementById('diagram');
                    const svg = diagram.querySelector('svg');
                    
                    if (!svg) return;
                    
                    const containerRect = container.getBoundingClientRect();
                    const svgRect = svg.getBoundingClientRect();
                    
                    // Get the natural size of the SVG
                    const svgWidth = svg.viewBox?.baseVal?.width || svgRect.width;
                    const svgHeight = svg.viewBox?.baseVal?.height || svgRect.height;
                    
                    if (svgWidth === 0 || svgHeight === 0) return;
                    
                    // Calculate scale to fit with padding
                    const padding = 32;
                    const availableWidth = containerRect.width - padding;
                    const availableHeight = containerRect.height - padding;
                    
                    const scaleX = availableWidth / svgWidth;
                    const scaleY = availableHeight / svgHeight;
                    
                    // Use the smaller scale to ensure it fits both dimensions
                    // Cap at 1.0 so we don't zoom in on small diagrams
                    initialScale = Math.min(scaleX, scaleY, 1.0);
                    scale = initialScale;
                    translateX = 0;
                    translateY = 0;
                    
                    updateTransform();
                }
                
                function zoomIn() {
                    scale = Math.min(scale * 1.2, 4);
                    updateTransform();
                }
                
                function zoomOut() {
                    scale = Math.max(scale / 1.2, 0.25);
                    updateTransform();
                }
                
                function resetView() {
                    scale = initialScale;
                    translateX = 0;
                    translateY = 0;
                    updateTransform();
                }
                
                // Mouse wheel zoom
                document.getElementById('container').addEventListener('wheel', (e) => {
                    e.preventDefault();
                    const delta = e.deltaY > 0 ? 0.9 : 1.1;
                    scale = Math.max(0.25, Math.min(4, scale * delta));
                    updateTransform();
                });
                
                // Pan with mouse drag
                const container = document.getElementById('container');
                container.addEventListener('mousedown', (e) => {
                    isDragging = true;
                    startX = e.clientX - translateX;
                    startY = e.clientY - translateY;
                });
                
                document.addEventListener('mousemove', (e) => {
                    if (!isDragging) return;
                    translateX = e.clientX - startX;
                    translateY = e.clientY - startY;
                    updateTransform();
                });
                
                document.addEventListener('mouseup', () => {
                    isDragging = false;
                });
                
                async function renderDiagram() {
                    const container = document.getElementById('diagram');
                    const code = `\(escapedCode)`;
                    
                    try {
                        container.classList.remove('loading');
                        const { svg } = await mermaid.render('mermaid-svg', code);
                        container.innerHTML = svg;
                        
                        // Wait for next frame to ensure SVG is laid out, then fit to view
                        requestAnimationFrame(() => {
                            requestAnimationFrame(() => {
                                fitToView();
                            });
                        });
                    } catch (error) {
                        container.innerHTML = '<div class="error">Failed to render diagram: ' + error.message + '</div>';
                        console.error('Mermaid error:', error);
                    }
                }
                
                renderDiagram();
            </script>
        </body>
        </html>
        """
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Diagram has finished loading
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("Mermaid WebView navigation failed: \(error)")
        }
    }
}

// MARK: - Preview

#Preview("Flowchart") {
    MermaidDiagramView(code: """
        flowchart LR
            Input[Read Files] --> Process[Transform Data]
            Process --> Validate{Valid?}
            Validate -->|Yes| Output[Save Results]
            Validate -->|No| Error[Handle Error]
            Error --> Process
        """)
        .frame(height: 200)
        .padding()
}

#Preview("Sequence Diagram") {
    MermaidDiagramView(code: """
        sequenceDiagram
            participant User
            participant Agent
            participant VM
            User->>Agent: Submit Task
            Agent->>VM: Execute Actions
            VM-->>Agent: Results
            Agent-->>User: Completion
        """)
        .frame(height: 300)
        .padding()
}

#Preview("Dark Mode") {
    MermaidDiagramView(code: """
        flowchart TD
            A[Start] --> B[Process]
            B --> C[End]
        """)
        .frame(height: 200)
        .padding()
        .preferredColorScheme(.dark)
}
