//
//  ScreenshotTool.swift
//  HivecrewGuestAgent
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import HivecrewAgentProtocol

/// Tool for capturing screenshots of the entire screen
final class ScreenshotTool: @unchecked Sendable {
    private let logger = AgentLogger.shared
    
    /// Capture a screenshot and return it as base64-encoded JPEG
    func execute() async throws -> [String: Any] {
        logger.log("Capturing screenshot...")
        
        let image = try await captureScreen()
        
        let width = image.width
        let height = image.height
        
        // Convert to JPEG data (smaller and faster than PNG)
        guard let jpegData = createJPEGData(from: image) else {
            throw AgentError(
                code: AgentError.toolExecutionFailed,
                message: "Failed to encode screenshot as JPEG"
            )
        }
        
        // Base64 encode
        let base64String = jpegData.base64EncodedString()
        
        logger.log("Screenshot captured: \(width)x\(height), \(jpegData.count) bytes")
        
        return [
            "imageBase64": base64String,
            "width": width,
            "height": height
        ]
    }
    
    /// Synchronous version that blocks until complete
    func executeSync() throws -> [String: Any] {
        let semaphore = DispatchSemaphore(value: 0)
        
        // Use a class to safely share state across threads
        final class ResultBox: @unchecked Sendable {
            var result: [String: Any]?
            var error: (any Error)?
        }
        let box = ResultBox()
        
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                do {
                    box.result = try await self.execute()
                } catch {
                    box.error = error
                }
                semaphore.signal()
            }
        }
        
        let waitResult = semaphore.wait(timeout: .now() + 10.0)
        
        if waitResult == .timedOut {
            throw AgentError(
                code: AgentError.toolExecutionFailed,
                message: "Screenshot capture timed out"
            )
        }
        
        if let error = box.error {
            throw error
        }
        
        guard let finalResult = box.result else {
            throw AgentError(
                code: AgentError.toolExecutionFailed,
                message: "Screenshot capture failed"
            )
        }
        
        return finalResult
    }
    
    /// Capture the screen using ScreenCaptureKit
    private func captureScreen() async throws -> CGImage {
        // Get the main display
        let content = try await SCShareableContent.current
        
        guard let display = content.displays.first else {
            throw AgentError(
                code: AgentError.toolExecutionFailed,
                message: "No displays found"
            )
        }
        
        // Configure the capture
        let filter = SCContentFilter(display: display, excludingWindows: [])
        
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        
        // Capture a single frame
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        
        return image
    }
    
    private func createJPEGData(from image: CGImage, quality: CGFloat = 0.85) -> Data? {
        let mutableData = NSMutableData()
        
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        
        return mutableData as Data
    }
}
