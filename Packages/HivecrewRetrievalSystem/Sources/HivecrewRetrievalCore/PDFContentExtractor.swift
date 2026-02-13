import Foundation
import PDFKit
import UniformTypeIdentifiers

struct PDFContentExtractor: FileContentExtractor {
    let name = "pdf"

    func canHandle(fileURL: URL, contentType: UTType?) -> Bool {
        fileURL.pathExtension.lowercased() == "pdf" || contentType?.conforms(to: .pdf) == true
    }

    func extract(fileURL: URL, contentType _: UTType?, policy: IndexingPolicy) throws -> ExtractedContent? {
        guard let document = PDFDocument(url: fileURL) else {
            return nil
        }

        var chunks: [String] = []
        var warnings: [String] = []
        var usedOCR = false
        let softDeadline = Date().addingTimeInterval(max(0.5, policy.maxExtractionSecondsPerFile * 0.7))
        var remainingOCRBudget = min(policy.maxPDFPagesToOCR, 8)

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                chunks.append(text)
                continue
            }
            guard remainingOCRBudget > 0 else {
                warnings.append("ocr_page_budget_reached")
                continue
            }
            guard Date() < softDeadline else {
                warnings.append("pdf_ocr_time_budget_reached")
                break
            }
            remainingOCRBudget -= 1
            usedOCR = true
            if let ocrText = Self.performOCR(on: page, policy: policy), !ocrText.isEmpty {
                chunks.append(ocrText)
            } else {
                warnings.append("pdf_page_ocr_empty")
            }
        }

        var metadata = fileMetadata(fileURL: fileURL)
        metadata["pageCount"] = "\(document.pageCount)"
        if let attrs = document.documentAttributes {
            if let title = attrs[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty {
                metadata["pdfTitle"] = title
            }
            if let author = attrs[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty {
                metadata["pdfAuthor"] = author
            }
            if let subject = attrs[PDFDocumentAttribute.subjectAttribute] as? String, !subject.isEmpty {
                metadata["pdfSubject"] = subject
            }
        }

        let body = chunks.joined(separator: "\n\n")
        return ExtractedContent(
            text: body,
            title: metadata["pdfTitle"] ?? fileURL.lastPathComponent,
            metadata: metadata,
            warnings: warnings,
            wasOCRUsed: usedOCR
        )
    }

    private static func performOCR(on page: PDFPage, policy: IndexingPolicy) -> String? {
        let size = CGSize(
            width: min(policy.maxImageDimensionForOCR, 2_048),
            height: min(policy.maxImageDimensionForOCR, 2_048)
        )
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)
        guard let cgImage = thumbnail.hcCGImage else {
            return nil
        }
        return OCR.extractText(
            from: cgImage,
            recognitionLanguages: ["en-US"]
        )
    }
}
