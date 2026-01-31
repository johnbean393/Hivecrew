//
//  RichPlanView.swift
//  Hivecrew
//
//  Renders a plan with Markdown and inline Mermaid diagrams
//

import SwiftUI
import MarkdownView

/// A view that renders a plan with rich Markdown and embedded Mermaid diagrams
struct RichPlanView: View {
    /// The full plan markdown text
    let markdown: String
    
    /// Parsed content segments
    private var segments: [PlanSegment] {
        PlanSegmentParser.parse(markdown)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                segmentView(for: segment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    @ViewBuilder
    private func segmentView(for segment: PlanSegment) -> some View {
        switch segment {
        case .markdown(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownView(text)
                    .textSelection(.enabled)
            }
            
        case .mermaid(let code):
            MermaidDiagramView(code: code)
                .frame(minHeight: 150, maxHeight: 400)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
        }
    }
}

// MARK: - Plan Segment Types

/// Represents a segment of a plan - either markdown text or a mermaid diagram
enum PlanSegment {
    case markdown(String)
    case mermaid(String)
}

// MARK: - Plan Segment Parser

/// Parses plan markdown into segments of text and mermaid diagrams
enum PlanSegmentParser {
    /// Pattern to match mermaid code blocks
    private static let mermaidPattern = #"```mermaid\s*\n([\s\S]*?)```"#
    
    /// Parse the markdown into segments
    static func parse(_ markdown: String) -> [PlanSegment] {
        var segments: [PlanSegment] = []
        var currentIndex = markdown.startIndex
        
        guard let regex = try? NSRegularExpression(pattern: mermaidPattern, options: []) else {
            return [.markdown(markdown)]
        }
        
        let range = NSRange(markdown.startIndex..., in: markdown)
        let matches = regex.matches(in: markdown, options: [], range: range)
        
        for match in matches {
            // Get the full match range
            guard let fullMatchRange = Range(match.range, in: markdown),
                  let codeRange = Range(match.range(at: 1), in: markdown) else {
                continue
            }
            
            // Add any markdown text before this mermaid block
            if currentIndex < fullMatchRange.lowerBound {
                let textBefore = String(markdown[currentIndex..<fullMatchRange.lowerBound])
                if !textBefore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.markdown(textBefore))
                }
            }
            
            // Add the mermaid diagram
            let mermaidCode = String(markdown[codeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !mermaidCode.isEmpty {
                segments.append(.mermaid(mermaidCode))
            }
            
            currentIndex = fullMatchRange.upperBound
        }
        
        // Add any remaining markdown after the last mermaid block
        if currentIndex < markdown.endIndex {
            let remainingText = String(markdown[currentIndex...])
            if !remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.markdown(remainingText))
            }
        }
        
        // If no segments were created, treat the whole thing as markdown
        if segments.isEmpty && !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(.markdown(markdown))
        }
        
        return segments
    }
}

// MARK: - Previews

#Preview("Full Plan") {
    ScrollView {
        RichPlanView(markdown: """
            # Convert Sales Data to Summary Report

            Read the Excel sales data, calculate key metrics, and generate a formatted PDF report with charts.

            ```mermaid
            flowchart LR
                Excel[sales_data.xlsx] --> Parse[Parse & Validate]
                Parse --> Calculate[Calculate Metrics]
                Calculate --> Chart[Generate Charts]
                Chart --> PDF[Create PDF Report]
                PDF --> Output[Save to Outbox]
            ```

            ## Data Extraction

            Open the sales spreadsheet at `~/Desktop/inbox/sales_data.xlsx` using LibreOffice Calc. The file contains monthly sales figures across multiple regions.

            Key columns to extract:
            - Column A: Date
            - Column B: Region  
            - Column C: Revenue
            - Column D: Units Sold

            ## Analysis

            Calculate the following metrics:
            - Total revenue by region
            - Month-over-month growth percentage
            - Top performing region
            - Average units sold per month

            ## Tasks

            - [ ] Read sales_data.xlsx and validate data structure
            - [ ] Calculate total revenue by region
            - [ ] Calculate month-over-month growth rates
            - [x] Identify top performing region
            - [ ] Save report to ~/Desktop/outbox/sales_report.pdf
            """)
            .padding()
    }
    .frame(width: 600, height: 800)
}

#Preview("No Mermaid") {
    ScrollView {
        RichPlanView(markdown: """
            # Simple Task Plan

            This is a simple plan without any diagrams.

            ## Steps

            1. Do the first thing
            2. Do the second thing
            3. Complete the task

            ## Tasks

            - [ ] First step
            - [ ] Second step
            - [ ] Third step
            """)
            .padding()
    }
    .frame(width: 600, height: 400)
}

#Preview("Multiple Diagrams") {
    ScrollView {
        RichPlanView(markdown: """
            # Complex Workflow

            This plan has multiple diagrams.

            ## Input Processing

            ```mermaid
            flowchart TD
                A[Input] --> B[Validate]
                B --> C[Process]
            ```

            Some text between diagrams.

            ## Output Generation

            ```mermaid
            flowchart TD
                X[Transform] --> Y[Format]
                Y --> Z[Save]
            ```

            ## Tasks

            - [ ] Process input
            - [ ] Generate output
            """)
            .padding()
    }
    .frame(width: 600, height: 800)
}
