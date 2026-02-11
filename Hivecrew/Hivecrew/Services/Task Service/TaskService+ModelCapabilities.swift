//
//  TaskService+ModelCapabilities.swift
//  Hivecrew
//
//  Runtime model capability resolution (vision support).
//

import AppKit
import Foundation
import HivecrewLLM

enum VisionCapabilitySource: String, Sendable {
    case metadata
    case heuristic
    case probe
    case fallback
}

struct VisionCapabilityResolution: Sendable {
    let supportsVision: Bool
    let source: VisionCapabilitySource
    let details: String
}

private enum VisionProbeOutcome: Sendable {
    case supported
    case failed(reason: String)
}

private actor VisionCapabilityCache {
    static let shared = VisionCapabilityCache()

    private var cache: [String: VisionCapabilityResolution] = [:]

    func get(providerId: String, modelId: String) -> VisionCapabilityResolution? {
        cache[cacheKey(providerId: providerId, modelId: modelId)]
    }

    func set(providerId: String, modelId: String, value: VisionCapabilityResolution) {
        cache[cacheKey(providerId: providerId, modelId: modelId)] = value
    }

    private func cacheKey(providerId: String, modelId: String) -> String {
        "\(providerId.lowercased())::\(modelId.lowercased())"
    }
}

extension TaskService {
    func resolveVisionCapability(
        providerId: String,
        modelId: String,
        using llmClient: (any LLMClientProtocol)? = nil
    ) async -> VisionCapabilityResolution {
        if let cached = await VisionCapabilityCache.shared.get(providerId: providerId, modelId: modelId) {
            return cached
        }

        let resolved = await resolveVisionCapabilityUncached(
            providerId: providerId,
            modelId: modelId,
            using: llmClient
        )
        await VisionCapabilityCache.shared.set(providerId: providerId, modelId: modelId, value: resolved)
        return resolved
    }

    private func resolveVisionCapabilityUncached(
        providerId: String,
        modelId: String,
        using llmClient: (any LLMClientProtocol)?
    ) async -> VisionCapabilityResolution {
        let client: any LLMClientProtocol
        if let llmClient {
            client = llmClient
        } else {
            do {
                client = try await createLLMClient(providerId: providerId, modelId: modelId)
            } catch {
                return VisionCapabilityResolution(
                    supportsVision: true,
                    source: .fallback,
                    details: "Could not create LLM client for capability detection (\(error.localizedDescription)); assuming vision-capable."
                )
            }
        }

        if let metadataResolution = await resolveVisionFromMetadata(modelId: modelId, using: client) {
            return metadataResolution
        }

        if let heuristicResolution = resolveVisionFromHeuristics(modelId: modelId) {
            return heuristicResolution
        }

        let probeOutcome = await runVisionProbe(using: client)
        switch probeOutcome {
        case .supported:
            return VisionCapabilityResolution(
                supportsVision: true,
                source: .probe,
                details: "Probe succeeded: model extracted expected text from image."
            )
        case .failed(let reason):
            return VisionCapabilityResolution(
                supportsVision: false,
                source: .probe,
                details: "Probe failed: \(reason)"
            )
        }
    }

    private func resolveVisionFromMetadata(
        modelId: String,
        using client: any LLMClientProtocol
    ) async -> VisionCapabilityResolution? {
        do {
            let models = try await client.listModelsDetailed()
            guard let model = matchModel(modelId, in: models) else {
                return nil
            }

            if let explicit = model.supportsVisionInput {
                let detail = explicit
                    ? "Provider metadata explicitly marks model as vision-capable."
                    : "Provider metadata explicitly marks model as non-vision."
                return VisionCapabilityResolution(
                    supportsVision: explicit,
                    source: .metadata,
                    details: detail
                )
            }

            if model.inputModalities != nil {
                let supportsVision = model.isVisionCapable
                let detail = supportsVision
                    ? "Input modalities include vision/image."
                    : "Input modalities provided with no vision/image modality."
                return VisionCapabilityResolution(
                    supportsVision: supportsVision,
                    source: .metadata,
                    details: detail
                )
            }
        } catch {
            return nil
        }

        return nil
    }

    private func resolveVisionFromHeuristics(modelId: String) -> VisionCapabilityResolution? {
        let id = modelId.lowercased()

        let nonVisionIndicators = [
            "embedding",
            "embed",
            "rerank",
            "moderation",
            "transcribe",
            "whisper",
            "tts",
            "speech",
            "audio"
        ]
        if nonVisionIndicators.contains(where: { id.contains($0) }) {
            return VisionCapabilityResolution(
                supportsVision: false,
                source: .heuristic,
                details: "Model identifier matches non-vision family heuristic."
            )
        }

        let visionIndicators = [
            "vision",
            "-vl",
            "_vl",
            "/vl",
            "llava",
            "qwen2-vl",
            "qwen-vl",
            "qvq",
            "pixtral",
            "gpt-4o",
            "gpt-4.1",
            "claude-3",
            "gemini"
        ]
        if visionIndicators.contains(where: { id.contains($0) }) {
            return VisionCapabilityResolution(
                supportsVision: true,
                source: .heuristic,
                details: "Model identifier matches vision-capable family heuristic."
            )
        }

        return nil
    }

    private func runVisionProbe(using client: any LLMClientProtocol) async -> VisionProbeOutcome {
        guard let imageBase64 = createVisionProbeImageBase64() else {
            return .failed(reason: "Unable to generate probe image.")
        }

        let messages: [LLMMessage] = [
            .system("You are an OCR checker. Respond with only the exact text shown in the image."),
            .user(
                text: "Extract the exact text from this image.",
                images: [.imageBase64(data: imageBase64, mimeType: "image/png")]
            )
        ]

        do {
            let response = try await client.chat(messages: messages, tools: nil)
            let responseText = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if responseText.contains("Hello, World.") {
                return .supported
            }
            return .failed(reason: "Probe response did not contain expected text. Response: \(responseText)")
        } catch let error as LLMError {
            return .failed(reason: error.localizedDescription)
        } catch let error as URLError {
            return .failed(reason: error.localizedDescription)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    private func createVisionProbeImageBase64() -> String? {
        let width = 640
        let height = 240
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else {
            return nil
        }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let imageSize = NSSize(width: width, height: height)
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: imageSize)).fill()

        let probeText = "Hello, World."
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 56, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        let textSize = probeText.size(withAttributes: attributes)
        let textRect = NSRect(
            x: max(24, (imageSize.width - textSize.width) / 2),
            y: (imageSize.height - textSize.height) / 2,
            width: min(imageSize.width - 48, textSize.width),
            height: textSize.height
        )
        probeText.draw(in: textRect, withAttributes: attributes)

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData.base64EncodedString()
    }

    private func matchModel(_ modelId: String, in models: [LLMProviderModel]) -> LLMProviderModel? {
        if let exact = models.first(where: { $0.id == modelId }) {
            return exact
        }

        if let caseInsensitive = models.first(where: { $0.id.caseInsensitiveCompare(modelId) == .orderedSame }) {
            return caseInsensitive
        }

        // Some providers return unscoped IDs while OpenRouter-style IDs include provider prefixes.
        let targetTail = modelId.split(separator: "/").last.map(String.init) ?? modelId
        if let byTail = models.first(where: { model in
            let modelTail = model.id.split(separator: "/").last.map(String.init) ?? model.id
            return modelTail.caseInsensitiveCompare(targetTail) == .orderedSame
        }) {
            return byTail
        }

        return nil
    }
}
