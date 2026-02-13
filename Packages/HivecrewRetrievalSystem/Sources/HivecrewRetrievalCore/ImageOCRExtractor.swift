import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageOCRExtractor: FileContentExtractor {
    let name = "image_ocr"

    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp", "bmp"]

    func canHandle(fileURL: URL, contentType: UTType?) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        if Self.extensions.contains(ext) {
            return true
        }
        return contentType?.conforms(to: .image) == true
    }

    func extract(fileURL: URL, contentType _: UTType?, policy: IndexingPolicy) throws -> ExtractedContent? {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let pixels = max(0, width) * max(0, height)

        var metadata = fileMetadata(fileURL: fileURL)
        metadata["width"] = "\(width)"
        metadata["height"] = "\(height)"

        var warnings: [String] = []
        let ocrMaxDimension = min(policy.maxImageDimensionForOCR, 2_048)
        let shouldRunOCR = width > 0
            && height > 0
            && pixels <= policy.maxImagePixelCountForOCR

        if !shouldRunOCR {
            warnings.append("image_ocr_skipped_size_limit")
            return ExtractedContent(
                text: "",
                title: fileURL.lastPathComponent,
                metadata: metadata,
                warnings: warnings,
                wasOCRUsed: false
            )
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: ocrMaxDimension,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return ExtractedContent(
                text: "",
                title: fileURL.lastPathComponent,
                metadata: metadata,
                warnings: ["image_decode_failed"],
                wasOCRUsed: false
            )
        }
        let text = OCR.extractText(from: cgImage, recognitionLanguages: ["en-US"]) ?? ""
        if text.isEmpty {
            warnings.append("image_ocr_empty")
        }
        return ExtractedContent(
            text: text,
            title: fileURL.lastPathComponent,
            metadata: metadata,
            warnings: warnings,
            wasOCRUsed: true
        )
    }
}
