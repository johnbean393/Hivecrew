//
//  ImageGenerationService.swift
//  Hivecrew
//
//  Service for generating images using OpenRouter or Gemini APIs
//

import Foundation

// MARK: - Types

/// Supported image generation providers
enum ImageGenerationProvider: String, Codable, Sendable {
    case openRouter = "openRouter"
    case gemini = "gemini"
}

/// Configuration for image generation
struct ImageGenerationConfiguration: Sendable {
    let provider: ImageGenerationProvider
    let model: String
    let apiKey: String
    let baseURL: URL?
    let aspectRatio: String?
    
    init(
        provider: ImageGenerationProvider,
        model: String,
        apiKey: String,
        baseURL: URL? = nil,
        aspectRatio: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.aspectRatio = aspectRatio
    }
}

/// Result from image generation
struct ImageGenerationResult: Sendable {
    let imagePath: String
    let description: String?
}

/// Errors from image generation
enum ImageGenerationError: Error, LocalizedError {
    case notConfigured
    case invalidResponse
    case noImageInResponse
    case failedToSaveImage
    case apiError(String)
    case networkError(Error)
    case failedToReadReferenceImage(String)
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Image generation is not configured"
        case .invalidResponse:
            return "Invalid response from image generation API"
        case .noImageInResponse:
            return "No image found in API response"
        case .failedToSaveImage:
            return "Failed to save generated image"
        case .apiError(let message):
            return "API error: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .failedToReadReferenceImage(let path):
            return "Failed to read reference image: \(path)"
        }
    }
}

// MARK: - Service

/// Service for generating images using AI APIs
final class ImageGenerationService: Sendable {
    
    /// Output directory for generated images
    let outputDirectory: URL
    
    /// Initialize with output directory
    /// - Parameter outputDirectory: The directory where generated images will be saved
    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }
    
    /// Generate an image from a prompt
    /// - Parameters:
    ///   - prompt: The text prompt describing the image to generate
    ///   - referenceImages: Optional array of (base64Data, mimeType) tuples for reference images
    ///   - config: The configuration for the image generation request
    /// - Returns: The result containing the path to the saved image
    func generateImage(
        prompt: String,
        referenceImages: [(data: String, mimeType: String)]?,
        config: ImageGenerationConfiguration
    ) async throws -> ImageGenerationResult {
        // Ensure output directory exists
        try ensureOutputDirectoryExists()
        
        // Generate based on provider
        let base64Image: String
        let description: String?
        
        switch config.provider {
        case .openRouter:
            (base64Image, description) = try await generateWithOpenRouter(
                prompt: prompt,
                referenceImages: referenceImages,
                config: config
            )
        case .gemini:
            (base64Image, description) = try await generateWithGemini(
                prompt: prompt,
                referenceImages: referenceImages,
                config: config
            )
        }
        
        // Save the image
        let imagePath = try saveImage(base64Data: base64Image)
        
        return ImageGenerationResult(imagePath: imagePath, description: description)
    }
    
    // MARK: - OpenRouter Implementation
    
    private func generateWithOpenRouter(
        prompt: String,
        referenceImages: [(data: String, mimeType: String)]?,
        config: ImageGenerationConfiguration
    ) async throws -> (base64: String, description: String?) {
        let baseURL = config.baseURL ?? URL(string: "https://openrouter.ai/api/v1")!
        let endpoint = baseURL.appendingPathComponent("chat/completions")
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        
        // Build message content
        var contentParts: [[String: Any]] = [
            ["type": "text", "text": prompt]
        ]
        
        // Add reference images if provided
        if let referenceImages = referenceImages {
            for (data, mimeType) in referenceImages {
                contentParts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(mimeType);base64,\(data)"]
                ])
            }
        }
        
        // Build request body
        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "user", "content": contentParts]
            ],
            "modalities": ["image", "text"]
        ]
        
        // Add aspect ratio configuration if specified
        if let aspectRatio = config.aspectRatio {
            body["image_config"] = ["aspect_ratio": aspectRatio]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageGenerationError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ImageGenerationError.apiError("HTTP \(httpResponse.statusCode): \(errorBody)")
        }
        
        // Parse response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw ImageGenerationError.invalidResponse
        }
        
        // Extract text description if present
        let textDescription = message["content"] as? String
        
        // Extract image from response
        guard let images = message["images"] as? [[String: Any]],
              let firstImage = images.first,
              let imageUrl = firstImage["image_url"] as? [String: Any],
              let dataUrl = imageUrl["url"] as? String else {
            throw ImageGenerationError.noImageInResponse
        }
        
        // Parse base64 from data URL
        let base64Data = extractBase64FromDataURL(dataUrl)
        
        return (base64Data, textDescription)
    }
    
    // MARK: - Gemini Implementation
    
    private func generateWithGemini(
        prompt: String,
        referenceImages: [(data: String, mimeType: String)]?,
        config: ImageGenerationConfiguration
    ) async throws -> (base64: String, description: String?) {
        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(config.model):generateContent")!
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        
        // Build parts array
        var parts: [[String: Any]] = [
            ["text": prompt]
        ]
        
        // Add reference images if provided
        if let referenceImages = referenceImages {
            for (data, mimeType) in referenceImages {
                parts.append([
                    "inline_data": [
                        "mime_type": mimeType,
                        "data": data
                    ]
                ])
            }
        }
        
        // Build request body
        var body: [String: Any] = [
            "contents": [
                ["parts": parts]
            ],
            "generationConfig": [
                "responseModalities": ["TEXT", "IMAGE"]
            ]
        ]
        
        // Add image config if aspect ratio specified
        if let aspectRatio = config.aspectRatio {
            var generationConfig = body["generationConfig"] as? [String: Any] ?? [:]
            generationConfig["imageConfig"] = ["aspectRatio": aspectRatio]
            body["generationConfig"] = generationConfig
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageGenerationError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ImageGenerationError.apiError("HTTP \(httpResponse.statusCode): \(errorBody)")
        }
        
        // Parse response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw ImageGenerationError.invalidResponse
        }
        
        // Find image and text parts
        var imageBase64: String?
        var textDescription: String?
        
        for part in parts {
            if let text = part["text"] as? String {
                textDescription = text
            }
            if let inlineData = part["inlineData"] as? [String: Any],
               let data = inlineData["data"] as? String {
                imageBase64 = data
            }
            // Also check for inline_data (snake_case)
            if let inlineData = part["inline_data"] as? [String: Any],
               let data = inlineData["data"] as? String {
                imageBase64 = data
            }
        }
        
        guard let base64 = imageBase64 else {
            throw ImageGenerationError.noImageInResponse
        }
        
        return (base64, textDescription)
    }
    
    // MARK: - Helpers
    
    private func ensureOutputDirectoryExists() throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: outputDirectory.path) {
            try fileManager.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }
    
    private func saveImage(base64Data: String) throws -> String {
        guard let imageData = Data(base64Encoded: base64Data) else {
            throw ImageGenerationError.failedToSaveImage
        }
        
        // Generate unique filename with timestamp (JPEG format)
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "generated_\(timestamp).jpg"
        let fileURL = outputDirectory.appendingPathComponent(filename)
        
        guard FileManager.default.createFile(atPath: fileURL.path, contents: imageData) else {
            throw ImageGenerationError.failedToSaveImage
        }
        
        // Return the path as it appears inside the VM (for the agent)
        return "/Volumes/Shared/inbox/images/\(filename)"
    }
    
    private func extractBase64FromDataURL(_ dataURL: String) -> String {
        // Data URL format: data:image/png;base64,<data>
        if let range = dataURL.range(of: "base64,") {
            return String(dataURL[range.upperBound...])
        }
        // If no prefix, assume it's already just base64
        return dataURL
    }
}
