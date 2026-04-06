//
//  OpenAIRealtimeProvider+Delegate.swift
//  HivecrewVoice
//

import Foundation

extension OpenAIRealtimeProvider: URLSessionWebSocketDelegate {

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
        Task { @MainActor in
            self.connectionState = .disconnected
            self.isReceiving = false
            self.webSocket = nil

            if let cont = self.connectionContinuation {
                self.connectionContinuation = nil
                cont.resume(throwing: OpenAIRealtimeError.connectionFailed)
            }
            if let cont = self.setupContinuation {
                self.setupContinuation = nil
                cont.resume(throwing: OpenAIRealtimeError.connectionFailed)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor in
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

            if self.isManualDisconnect {
                self.connectionState = .disconnected
            } else {
                self.connectionState = .error(error.localizedDescription)
                self.onError?(error)
            }
        }
    }
}
