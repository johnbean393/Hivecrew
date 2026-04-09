//
//  GeminiLiveProvider+Delegate.swift
//  HivecrewVoice
//

import Foundation

extension GeminiLiveProvider: URLSessionWebSocketDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            if let cont = self.connectionContinuation {
                self.connectionContinuation = nil
                cont.resume()
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let detail = Self.closeReason(code: closeCode, data: reason)
        let error = GeminiError.connectionFailed(detail)
        Task { @MainActor in
            self.connectionState = .disconnected
            self.isReceiving = false
            self.webSocket = nil

            if let cont = self.connectionContinuation {
                self.connectionContinuation = nil
                cont.resume(throwing: error)
            }
            if let cont = self.setupContinuation {
                self.setupContinuation = nil
                cont.resume(throwing: error)
            }

            self.resumeSessionIfNeeded()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let detail = Self.describeURLSessionError(error, task: task)
        let surfaced = GeminiError.connectionFailed(detail)
        Task { @MainActor in
            self.isReceiving = false
            self.webSocket = nil

            if let cont = self.connectionContinuation {
                self.connectionContinuation = nil
                cont.resume(throwing: surfaced)
            }
            if let cont = self.setupContinuation {
                self.setupContinuation = nil
                cont.resume(throwing: surfaced)
            }

            if self.isManualDisconnect {
                self.connectionState = .disconnected
            } else {
                self.resumeSessionIfNeeded()
            }
        }
    }

    // MARK: - Helpers

    nonisolated private static func closeReason(
        code: URLSessionWebSocketTask.CloseCode,
        data: Data?
    ) -> String {
        let serverReason = data
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { Self.trimToLastSentence($0) }
        if let serverReason, !serverReason.isEmpty {
            return serverReason
        }
        switch code {
        case .normalClosure:      return "Connection closed"
        case .goingAway:          return "Server going away"
        case .protocolError:      return "Protocol error"
        case .unsupportedData:    return "Unsupported data"
        case .noStatusReceived:   return "No status received"
        case .abnormalClosure:    return "Connection lost unexpectedly"
        case .invalidFramePayloadData: return "Invalid payload"
        case .policyViolation:    return "Policy violation"
        case .messageTooBig:      return "Message too big"
        case .mandatoryExtensionMissing: return "Mandatory extension missing"
        case .internalServerError: return "Internal server error"
        case .tlsHandshakeFailure: return "TLS handshake failed"
        @unknown default:         return "Connection closed (code \(code.rawValue))"
        }
    }

    nonisolated private static func describeURLSessionError(
        _ error: Error,
        task: URLSessionTask
    ) -> String {
        // Check for HTTP status code from the WebSocket handshake
        if let httpResponse = task.response as? HTTPURLResponse,
           httpResponse.statusCode != 101 {
            switch httpResponse.statusCode {
            case 401: return "Invalid API key (401)"
            case 403: return "Access denied (403)"
            case 404: return "Model not found (404)"
            case 429: return "Rate limited — try again later (429)"
            case 500...599: return "Server error (\(httpResponse.statusCode))"
            default: return "HTTP \(httpResponse.statusCode)"
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return "No internet connection"
            case NSURLErrorTimedOut:
                return "Connection timed out"
            case NSURLErrorNetworkConnectionLost:
                return "Network connection lost"
            case NSURLErrorCannotFindHost:
                return "Cannot reach Gemini servers"
            case NSURLErrorSecureConnectionFailed:
                return "Secure connection failed"
            case NSURLErrorServerCertificateUntrusted:
                return "Server certificate untrusted"
            default:
                return error.localizedDescription
            }
        }

        return error.localizedDescription
    }

    /// The WebSocket close frame limits reason data to 125 bytes, so server
    /// messages often get truncated mid-word. Trim to the last complete sentence
    /// so the user sees clean text instead of a cut-off fragment.
    nonisolated private static func trimToLastSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") {
            return trimmed
        }
        if let range = trimmed.range(of: ".", options: .backwards) {
            return String(trimmed[...range.lowerBound])
        }
        return trimmed
    }
}
