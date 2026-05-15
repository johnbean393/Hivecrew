//
//  ImageGenerationService.swift
//  Hivecrew
//
//  Service for generating images using OpenRouter, Gemini, or ChatGPT OAuth
//

import Foundation
import HivecrewLLM

// MARK: - Types

/// Supported image generation providers
enum ImageGenerationProvider: String, Codable, Sendable {
    case openRouter = "openRouter"
    case gemini = "gemini"
    case chatGPTOAuth = "chatGPTOAuth"
}

struct ImageGenerationRequestOptions: Sendable, Equatable {
    let referenceImagePaths: [String]?
    let aspectRatio: String?

    static func fromToolArgs(_ args: [String: Any]) -> Self {
        Self(
            referenceImagePaths: (args["referenceImagePaths"] as? [String]) ?? (args["reference_image_paths"] as? [String]),
            aspectRatio: (args["aspectRatio"] as? String) ?? (args["aspect_ratio"] as? String)
        )
    }
}

func codexOAuthImageSize(for aspectRatio: String?) -> String? {
    switch aspectRatio?.trimmingCharacters(in: .whitespacesAndNewlines) {
    case nil, "":
        return nil
    case "1:1":
        return "1024x1024"
    case "2:3":
        return "1024x1536"
    case "3:2":
        return "1536x1024"
    case "3:4":
        return "768x1024"
    case "4:3":
        return "1024x768"
    case "4:5":
        return "1024x1280"
    case "5:4":
        return "1280x1024"
    case "9:16":
        return "720x1280"
    case "16:9":
        return "1280x720"
    case "21:9":
        return "1680x720"
    case let custom?:
        return custom
    }
}

/// Configuration for image generation
struct ImageGenerationConfiguration: Sendable {
    let provider: ImageGenerationProvider
    let model: String
    let apiKey: String?
    let baseURL: URL?
    let oauthProviderId: String?
    let options: ImageGenerationRequestOptions
    
    init(
        provider: ImageGenerationProvider,
        model: String,
        apiKey: String? = nil,
        baseURL: URL? = nil,
        oauthProviderId: String? = nil,
        options: ImageGenerationRequestOptions = .init(referenceImagePaths: nil, aspectRatio: nil)
    ) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.oauthProviderId = oauthProviderId
        self.options = options
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
    case authenticationFailed(String)
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
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
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
    private let defaultCodexOAuthInstructions = """
    You are an image-generation assistant.
    Use the image_generation tool to synthesize the final raster image directly.
    Do not write, render, screenshot, or simulate HTML, CSS, SVG, JavaScript, webpages, browser windows, slide editors, PowerPoint, PDFs, or any other document/code renderer as an intermediate step.
    Do not produce code screenshots or rendered markup unless the user explicitly asked for a screenshot of code or a browser.
    Return only the generated image result.
    """
    private let requestTimeout: TimeInterval = 300
    
    /// Output directory for generated images
    let outputDirectory: URL

    /// Directory path reported back to agents for generated image files.
    private let returnedPathDirectory: String
    
    /// Initialize with output directory
    /// - Parameter outputDirectory: The directory where generated images will be saved
    init(outputDirectory: URL, returnedPathDirectory: String? = nil) {
        self.outputDirectory = outputDirectory
        self.returnedPathDirectory = returnedPathDirectory ?? outputDirectory.path
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
        case .chatGPTOAuth:
            (base64Image, description) = try await generateWithChatGPTOAuth(
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
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw ImageGenerationError.authenticationFailed("OpenRouter API key is missing")
        }

        let baseURL = config.baseURL ?? defaultLLMProviderBaseURL
        let endpoint = baseURL.appendingPathComponent("chat/completions")
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout
        
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
        if let aspectRatio = config.options.aspectRatio {
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
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw ImageGenerationError.authenticationFailed("Google AI Studio API key is missing")
        }

        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(config.model):generateContent")!
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout
        
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
        if let aspectRatio = config.options.aspectRatio {
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

    private func generateWithChatGPTOAuth(
        prompt: String,
        referenceImages: [(data: String, mimeType: String)]?,
        config: ImageGenerationConfiguration,
        forceRefresh: Bool = false
    ) async throws -> (base64: String, description: String?) {
        guard let providerId = config.oauthProviderId, !providerId.isEmpty else {
            throw ImageGenerationError.authenticationFailed("ChatGPT OAuth provider is missing")
        }

        let accessToken: String
        do {
            accessToken = try await resolveChatGPTOAuthAccessToken(
                providerId: providerId,
                timeoutInterval: requestTimeout,
                forceRefresh: forceRefresh
            )
        } catch let error as LLMError {
            throw ImageGenerationError.authenticationFailed(error.localizedDescription)
        } catch {
            throw ImageGenerationError.authenticationFailed(error.localizedDescription)
        }

        var request = URLRequest(url: buildCodexOAuthURL(pathComponent: "responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = requestTimeout
        applyCodexProxyTokenHeader(to: &request)

        let body = buildCodexOAuthImageGenerationRequestBody(
            prompt: prompt,
            referenceImages: referenceImages,
            model: config.model,
            options: config.options
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = requestTimeout
        sessionConfiguration.timeoutIntervalForResource = requestTimeout
        sessionConfiguration.waitsForConnectivity = false
        let session = URLSession(configuration: sessionConfiguration)

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageGenerationError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = try await readErrorBody(from: bytes)
            if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403), !forceRefresh {
                return try await generateWithChatGPTOAuth(
                    prompt: prompt,
                    referenceImages: referenceImages,
                    config: config,
                    forceRefresh: true
                )
            }
            throw ImageGenerationError.apiError("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        return try await parseCodexOAuthImageGenerationStream(bytes)
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
        
        // Detect image format from data
        let fileExtension = detectImageFormat(data: imageData)
        
        // Generate unique filename with timestamp
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "generated_\(timestamp).\(fileExtension)"
        let fileURL = outputDirectory.appendingPathComponent(filename)
        
        guard FileManager.default.createFile(atPath: fileURL.path, contents: imageData) else {
            throw ImageGenerationError.failedToSaveImage
        }
        
        return "\(returnedPathDirectory)/\(filename)"
    }
    
    /// Detect image format from magic bytes
    private func detectImageFormat(data: Data) -> String {
        guard data.count >= 8 else {
            return "png" // Default to PNG
        }
        
        let bytes = [UInt8](data.prefix(8))
        
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "png"
        }
        
        // JPEG: FF D8 FF
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return "jpg"
        }
        
        // WebP: RIFF....WEBP
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
            return "webp"
        }
        
        // Default to PNG
        return "png"
    }
    
    private func extractBase64FromDataURL(_ dataURL: String) -> String {
        // Data URL format: data:image/png;base64,<data>
        if let range = dataURL.range(of: "base64,") {
            return String(dataURL[range.upperBound...])
        }
        // If no prefix, assume it's already just base64
        return dataURL
    }

    private func buildCodexOAuthImageGenerationRequestBody(
        prompt: String,
        referenceImages: [(data: String, mimeType: String)]?,
        model: String,
        options: ImageGenerationRequestOptions
    ) -> [String: Any] {
        var content: [[String: Any]] = [
            ["type": "input_text", "text": prompt]
        ]

        if let referenceImages {
            for image in referenceImages {
                content.append([
                    "type": "input_image",
                    "image_url": "data:\(image.mimeType);base64,\(image.data)"
                ])
            }
        }

        var imageGenerationTool: [String: Any] = [
            "type": "image_generation"
        ]
        if let size = codexOAuthImageSize(for: options.aspectRatio) {
            imageGenerationTool["size"] = size
        }

        return [
            "model": model,
            "store": false,
            "stream": true,
            "instructions": defaultCodexOAuthInstructions,
            "input": [[
                "type": "message",
                "role": "user",
                "content": content
            ]],
            "tools": [imageGenerationTool],
            "tool_choice": [
                "type": "image_generation"
            ]
        ]
    }

    private func parseCodexOAuthImageGenerationStream(
        _ bytes: URLSession.AsyncBytes
    ) async throws -> (base64: String, description: String?) {
        var lineBuffer = Data()
        var imageBase64: String?
        var revisedPrompt: String?
        var textDescription: String?

        func processPayload(_ payload: String) throws {
            guard let eventData = payload.data(using: .utf8),
                  let event = try JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
                return
            }

            if let error = event["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Unknown error"
                throw ImageGenerationError.apiError(message)
            }

            switch event["type"] as? String {
            case "response.failed":
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? "Response failed"
                throw ImageGenerationError.apiError(message)
            case "response.output_text.done":
                if let text = event["text"] as? String, !text.isEmpty {
                    textDescription = text
                }
            case "response.content_part.done":
                guard let part = event["part"] as? [String: Any] else {
                    return
                }
                let partType = part["type"] as? String
                if (partType == "output_text" || partType == "text"),
                   let text = part["text"] as? String,
                   !text.isEmpty {
                    textDescription = text
                }
            case "response.output_item.done":
                guard let item = event["item"] as? [String: Any] else {
                    return
                }
                if let extracted = extractImageGenerationResult(from: item) {
                    imageBase64 = extracted.base64
                    revisedPrompt = extracted.revisedPrompt ?? revisedPrompt
                }
            case "response.completed":
                guard let response = event["response"] as? [String: Any] else {
                    return
                }
                if let output = response["output"] as? [[String: Any]] {
                    for item in output {
                        if let extracted = extractImageGenerationResult(from: item) {
                            imageBase64 = extracted.base64
                            revisedPrompt = extracted.revisedPrompt ?? revisedPrompt
                        }

                        guard item["type"] as? String == "message",
                              let content = item["content"] as? [[String: Any]] else {
                            continue
                        }

                        for contentItem in content {
                            let contentType = contentItem["type"] as? String
                            if (contentType == "output_text" || contentType == "text"),
                               let text = contentItem["text"] as? String,
                               !text.isEmpty {
                                textDescription = text
                            }
                        }
                    }
                }
            default:
                return
            }
        }

        for try await byte in bytes {
            if byte == 0x0A {
                guard let line = String(data: lineBuffer, encoding: .utf8) else {
                    lineBuffer.removeAll()
                    continue
                }
                lineBuffer.removeAll()

                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.hasPrefix("data:") else {
                    continue
                }

                let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]" else {
                    break
                }

                try processPayload(String(payload))
            } else {
                lineBuffer.append(byte)
            }
        }

        if !lineBuffer.isEmpty,
           let line = String(data: lineBuffer, encoding: .utf8) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("data:") {
                let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload != "[DONE]" {
                    try processPayload(String(payload))
                }
            }
        }

        guard let imageBase64, !imageBase64.isEmpty else {
            throw ImageGenerationError.noImageInResponse
        }

        return (imageBase64, revisedPrompt ?? textDescription)
    }

    private func extractImageGenerationResult(
        from item: [String: Any]
    ) -> (base64: String, revisedPrompt: String?)? {
        guard item["type"] as? String == "image_generation_call",
              let result = item["result"] as? String,
              !result.isEmpty else {
            return nil
        }

        return (result, item["revised_prompt"] as? String)
    }

    private func readErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var errorData = Data()
        for try await byte in bytes {
            errorData.append(byte)
        }
        return String(data: errorData, encoding: .utf8) ?? "No response body"
    }
}
