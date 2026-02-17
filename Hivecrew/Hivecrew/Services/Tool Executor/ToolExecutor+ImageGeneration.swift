//
//  ToolExecutor+ImageGeneration.swift
//  Hivecrew
//
//  Image generation tool handler for ToolExecutor
//

import Foundation
import SwiftData
import HivecrewShared

// MARK: - Image Generation Tool Handler

extension ToolExecutor {
    
    /// Execute image generation tool
    func executeGenerateImage(args: [String: Any]) async throws -> InternalToolResult {
        let prompt = args["prompt"] as? String ?? ""
        let referenceImagePaths = (args["referenceImagePaths"] as? [String]) ?? (args["reference_image_paths"] as? [String])
        let aspectRatio = (args["aspectRatio"] as? String) ?? (args["aspect_ratio"] as? String)
        
        // Get configuration
        guard let config = try await getImageGenerationConfig(aspectRatio: aspectRatio) else {
            return .text("Error: Image generation is not configured. Enable it in Settings > Tasks.")
        }
        
        // Determine output directory - use VM's shared inbox/images folder
        let outputDirectory = AppPaths.vmInboxDirectory(id: vmId).appendingPathComponent("images", isDirectory: true)
        
        // Load reference images if provided
        // First image is kept at full quality, subsequent images are downscaled to reduce payload size
        var referenceImages: [(data: String, mimeType: String)]?
        if let paths = referenceImagePaths, !paths.isEmpty {
            referenceImages = []
            for (index, path) in paths.enumerated() {
                if let imageData = try? await loadReferenceImage(path: path) {
                    let normalizedImageData = (
                        data: imageData.data,
                        mimeType: ImageDownscaler.normalizeImageMimeType(imageData.mimeType)
                    )
                    
                    if index == 0 {
                        // First image: keep at full quality for PNG/JPEG/JPG, convert others to JPEG
                        if ImageDownscaler.directlySupportedEditInputMimeTypes.contains(normalizedImageData.mimeType) {
                            referenceImages?.append(normalizedImageData)
                        } else if let converted = ImageDownscaler.convertToJPEG(
                            base64Data: normalizedImageData.data,
                            mimeType: normalizedImageData.mimeType
                        ) {
                            referenceImages?.append(converted)
                        } else {
                            referenceImages?.append(normalizedImageData)
                        }
                    } else {
                        // Subsequent images: downscale to ~4x smaller (512px max dimension)
                        // downscale() also converts to JPEG
                        if let downscaled = ImageDownscaler.downscale(
                            base64Data: normalizedImageData.data,
                            mimeType: normalizedImageData.mimeType,
                            to: .small
                        ) {
                            referenceImages?.append(downscaled)
                        } else {
                            referenceImages?.append(normalizedImageData)
                        }
                    }
                }
            }
        }
        
        // Generate image
        let service = ImageGenerationService(outputDirectory: outputDirectory)
        let result = try await service.generateImage(
            prompt: prompt,
            referenceImages: referenceImages,
            config: config
        )
        
        // Build response
        var response = "Image generated and saved to: \(result.imagePath)"
        if let description = result.description {
            response += "\n\nModel description: \(description)"
        }
        
        return .text(response)
    }
    
    // MARK: - Configuration
    
    private func getImageGenerationConfig(aspectRatio: String?) async throws -> ImageGenerationConfiguration? {
        // Need model context to fetch providers and auto-configure defaults
        guard let modelContext = self.modelContext else {
            return nil
        }
        
        ImageGenerationAvailability.autoConfigureIfNeeded(modelContext: modelContext)
        
        // Check if enabled
        guard UserDefaults.standard.bool(forKey: "imageGenerationEnabled") else {
            return nil
        }
        
        let providerString = UserDefaults.standard.string(forKey: "imageGenerationProvider") ?? "openRouter"
        let provider = ImageGenerationProvider(rawValue: providerString) ?? .openRouter
        
        let configuredModel = (UserDefaults.standard.string(forKey: "imageGenerationModel") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuredModel.isEmpty
            ? ImageGenerationAvailability.defaultModel(for: provider)
            : configuredModel
        
        if configuredModel.isEmpty {
            UserDefaults.standard.set(model, forKey: "imageGenerationModel")
        }
        
        // Get credentials using the shared helper
        guard let (apiKey, baseURL) = ImageGenerationAvailability.getCredentials(modelContext: modelContext) else {
            return nil
        }
        
        return ImageGenerationConfiguration(
            provider: provider,
            model: model,
            apiKey: apiKey,
            baseURL: provider == .openRouter ? baseURL : nil,
            aspectRatio: aspectRatio
        )
    }
    
    // MARK: - Reference Images
    
    private func loadReferenceImage(path: String) async throws -> (data: String, mimeType: String)? {
        // Try to read the file via the guest agent connection
        let result = try await connection.readFile(path: path)
        
        switch result {
        case .image(let base64, let mimeType, _, _):
            return (base64, mimeType)
        case .text:
            // Not an image file
            return nil
        }
    }
}
