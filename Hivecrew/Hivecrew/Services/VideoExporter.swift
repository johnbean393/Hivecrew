//
//  VideoExporter.swift
//  Hivecrew
//
//  Exports a sequence of images to a video file using AVFoundation
//

import AVFoundation
import AppKit

/// Utility for exporting images to video
enum VideoExporter {
    
    enum ExportError: LocalizedError {
        case noImages
        case failedToLoadImage(String)
        case failedToGetImageDimensions
        case failedToCreatePixelBuffer
        case failedToCreateWriter(Error)
        case writerFailed(Error)
        case cancelled
        
        var errorDescription: String? {
            switch self {
            case .noImages:
                return "No images provided for video export"
            case .failedToLoadImage(let path):
                return "Failed to load image: \(path)"
            case .failedToGetImageDimensions:
                return "Failed to determine image dimensions"
            case .failedToCreatePixelBuffer:
                return "Failed to create pixel buffer for video frame"
            case .failedToCreateWriter(let error):
                return "Failed to create video writer: \(error.localizedDescription)"
            case .writerFailed(let error):
                return "Video writing failed: \(error.localizedDescription)"
            case .cancelled:
                return "Video export was cancelled"
            }
        }
    }
    
    /// Export a sequence of images to a video file
    /// - Parameters:
    ///   - imagePaths: Array of file paths to images (in order)
    ///   - outputURL: Destination URL for the video file
    ///   - fps: Frames per second (default: 6)
    ///   - progress: Optional progress callback (0.0 to 1.0)
    /// - Throws: ExportError if export fails
    static func exportVideo(
        from imagePaths: [String],
        to outputURL: URL,
        fps: Int = 6,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard !imagePaths.isEmpty else {
            throw ExportError.noImages
        }
        
        // Load first image to get dimensions
        guard let firstImage = NSImage(contentsOfFile: imagePaths[0]) else {
            throw ExportError.failedToLoadImage(imagePaths[0])
        }
        
        guard let firstRep = firstImage.representations.first else {
            throw ExportError.failedToGetImageDimensions
        }
        
        let width = firstRep.pixelsWide
        let height = firstRep.pixelsHigh
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: outputURL)
        
        // Create asset writer
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw ExportError.failedToCreateWriter(error)
        }
        
        // Configure video settings
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 4, // Quality setting
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        
        // Create pixel buffer adaptor
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )
        
        writer.add(writerInput)
        
        // Start writing
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error ?? NSError(domain: "VideoExporter", code: -1))
        }
        
        writer.startSession(atSourceTime: .zero)
        
        // Frame duration based on FPS
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        
        // Write frames
        for (index, imagePath) in imagePaths.enumerated() {
            // Check if writer is still valid
            guard writer.status == .writing else {
                throw ExportError.writerFailed(writer.error ?? NSError(domain: "VideoExporter", code: -1))
            }
            
            // Wait for input to be ready
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
            
            // Load image
            guard let image = NSImage(contentsOfFile: imagePath) else {
                throw ExportError.failedToLoadImage(imagePath)
            }
            
            // Create pixel buffer from image
            guard let pixelBuffer = createPixelBuffer(from: image, width: width, height: height) else {
                throw ExportError.failedToCreatePixelBuffer
            }
            
            // Calculate presentation time
            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(index))
            
            // Append pixel buffer
            if !adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
                throw ExportError.writerFailed(writer.error ?? NSError(domain: "VideoExporter", code: -1))
            }
            
            // Report progress
            let progressValue = Double(index + 1) / Double(imagePaths.count)
            progress?(progressValue)
        }
        
        // Finish writing
        writerInput.markAsFinished()
        
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        
        // Check final status
        if writer.status == .failed {
            throw ExportError.writerFailed(writer.error ?? NSError(domain: "VideoExporter", code: -1))
        }
    }
    
    /// Create a CVPixelBuffer from an NSImage, scaled to the specified dimensions
    private static func createPixelBuffer(from image: NSImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }
        
        // Draw image scaled to fit
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(rect)
        
        // Get CGImage from NSImage
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        // Calculate aspect-fit rect
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let targetWidth = CGFloat(width)
        let targetHeight = CGFloat(height)
        
        let widthRatio = targetWidth / imageWidth
        let heightRatio = targetHeight / imageHeight
        let scale = min(widthRatio, heightRatio)
        
        let scaledWidth = imageWidth * scale
        let scaledHeight = imageHeight * scale
        let x = (targetWidth - scaledWidth) / 2
        let y = (targetHeight - scaledHeight) / 2
        
        let drawRect = CGRect(x: x, y: y, width: scaledWidth, height: scaledHeight)
        context.draw(cgImage, in: drawRect)
        
        return buffer
    }
}
