//
//  ScreenshotTool.swift
//  HivecrewGuestAgent
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation
import ScreenCaptureKit
import CoreGraphics
import ApplicationServices
import ImageIO
import HivecrewAgentProtocol

/// Tool for capturing screenshots of the entire screen
final class ScreenshotTool: @unchecked Sendable {
    private let logger = AgentLogger.shared
    private let inputTool = InputTool()
    private let captureTimeout: TimeInterval = 5.0
    private let promptRecoveryTimeout: TimeInterval = 5.0
    
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
        
        let waitResult = semaphore.wait(timeout: .now() + captureTimeout)
        
        if waitResult == .timedOut {
            logger.warning("Screenshot capture timed out after \(captureTimeout)s")

            if dismissScreenCapturePromptIfNeeded() {
                logger.log("Retrying screenshot after dismissing screen capture prompt")

                let recoveryWaitResult = semaphore.wait(timeout: .now() + promptRecoveryTimeout)
                if recoveryWaitResult != .timedOut {
                    if let error = box.error {
                        throw error
                    }

                    if let finalResult = box.result {
                        return finalResult
                    }
                }

                throw AgentError(
                    code: AgentError.toolExecutionFailed,
                    message: "Screenshot capture timed out after dismissing a screen capture prompt"
                )
            }

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

    private func dismissScreenCapturePromptIfNeeded() -> Bool {
        guard isLikelyScreenCapturePromptPresent() else {
            logger.log("No matching screen capture prompt found after timeout")
            return false
        }

        do {
            logger.log("Detected screen capture prompt, sending Return key")
            try inputTool.keyboardKey(key: "return", modifiers: [])
            Thread.sleep(forTimeInterval: 1.0)
            return true
        } catch {
            logger.warning("Failed to send Return key for screen capture prompt: \(error.localizedDescription)")
            return false
        }
    }

    private func isLikelyScreenCapturePromptPresent() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        guard let focusedApplication = copyElementAttribute(
            from: systemWide,
            attribute: kAXFocusedApplicationAttribute
        ) else {
            return false
        }

        let promptIndicators = [
            "requesting to bypass the system private window picker",
            "access your screen and audio",
            "record your screen and system audio",
        ]

        return elementContainsPromptText(
            focusedApplication,
            depth: 0,
            promptIndicators: promptIndicators
        )
    }

    private func elementContainsPromptText(
        _ element: AXUIElement,
        depth: Int,
        promptIndicators: [String]
    ) -> Bool {
        guard depth <= 5 else { return false }

        let directStrings = [
            copyStringAttribute(from: element, attribute: kAXTitleAttribute),
            copyStringAttribute(from: element, attribute: kAXDescriptionAttribute),
            copyStringAttribute(from: element, attribute: kAXValueAttribute),
            copyStringAttribute(from: element, attribute: kAXRoleDescriptionAttribute),
        ]
        .compactMap { $0?.lowercased() }

        if directStrings.contains(where: { value in
            promptIndicators.contains(where: value.contains)
        }) {
            return true
        }

        let childAttributes = [
            kAXFocusedWindowAttribute,
            kAXWindowsAttribute,
            kAXTopLevelUIElementAttribute,
            kAXChildrenAttribute,
            kAXVisibleChildrenAttribute,
        ]

        for attribute in childAttributes {
            if let childElements = copyElementArrayAttribute(from: element, attribute: attribute) {
                for child in childElements.prefix(25) {
                    if elementContainsPromptText(child, depth: depth + 1, promptIndicators: promptIndicators) {
                        return true
                    }
                }
            } else if let child = copyElementAttribute(from: element, attribute: attribute) {
                if elementContainsPromptText(child, depth: depth + 1, promptIndicators: promptIndicators) {
                    return true
                }
            }
        }

        return false
    }

    private func copyStringAttribute(from element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func copyElementAttribute(from element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func copyElementArrayAttribute(from element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? [AXUIElement]
    }
}
