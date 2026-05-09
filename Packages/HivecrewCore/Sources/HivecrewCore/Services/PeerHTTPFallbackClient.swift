//
//  PeerHTTPFallbackClient.swift
//  HivecrewCore
//
//  Minimal HTTPS-over-Network.framework client for Cloudflare tunnel peers when
//  URLSession cannot resolve a hostname through the current system DNS path.
//

import Foundation
@preconcurrency import Network

enum PeerHTTPFallbackClient {
    enum FallbackError: Error {
        case unsupportedURL
        case noAddress
        case noBodyStreamSupport
        case connectionFailed
        case invalidResponse
    }

    static func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty else {
            throw FallbackError.unsupportedURL
        }
        guard request.httpBodyStream == nil else {
            throw FallbackError.noBodyStreamSupport
        }

        let addresses = await PeerDNSResolver.aRecords(forHost: host)
        guard !addresses.isEmpty else { throw FallbackError.noAddress }

        var lastError: Error?
        for address in addresses {
            do {
                return try await data(for: request, host: host, address: address)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? FallbackError.connectionFailed
    }

    private static func data(
        for request: URLRequest,
        host: String,
        address: String
    ) async throws -> (Data, HTTPURLResponse) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)

        let tcp = NWProtocolTCP.Options()
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let connection = NWConnection(host: NWEndpoint.Host(address), port: .https, using: parameters)

        return try await withTaskCancellationHandler {
            try await waitUntilReady(connection)
            try await send(httpRequest: request, host: host, on: connection)
            let responseData = try await receiveAll(from: connection)
            connection.cancel()
            return try parseResponse(responseData, url: request.url)
        } onCancel: {
            connection.cancel()
        }
    }

    private static func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let continuationBox = VoidContinuationBox(continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuationBox.resume(.success(()))
                case .failed(let error):
                    continuationBox.resume(.failure(error))
                case .cancelled:
                    continuationBox.resume(.failure(FallbackError.connectionFailed))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
    }

    private static func send(httpRequest request: URLRequest, host: String, on connection: NWConnection) async throws {
        let data = try makeHTTPRequestData(from: request, host: host)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let continuationBox = VoidContinuationBox(continuation)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuationBox.resume(.failure(error))
                } else {
                    continuationBox.resume(.success(()))
                }
            })
        }
    }

    private static func receiveAll(from connection: NWConnection) async throws -> Data {
        var buffer = Data()
        while true {
            let chunk = try await receiveChunk(from: connection)
            buffer.append(chunk.data)
            if chunk.isComplete { return buffer }
        }
    }

    private static func receiveChunk(from connection: NWConnection) async throws -> (data: Data, isComplete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (data ?? Data(), isComplete))
            }
        }
    }

    private static func makeHTTPRequestData(from request: URLRequest, host: String) throws -> Data {
        guard let url = request.url else { throw FallbackError.unsupportedURL }

        let method = request.httpMethod ?? "GET"
        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            target += "?\(query)"
        }

        let body = request.httpBody ?? Data()
        var lines = [
            "\(method) \(target) HTTP/1.1",
            "Host: \(host)",
            "Connection: close",
            "User-Agent: Hivecrew/1.0"
        ]

        let skippedHeaders = Set(["host", "connection", "content-length"])
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            guard !skippedHeaders.contains(name.lowercased()) else { continue }
            lines.append("\(name): \(value)")
        }

        if !body.isEmpty {
            lines.append("Content-Length: \(body.count)")
        }

        lines.append("")
        lines.append("")

        var data = Data(lines.joined(separator: "\r\n").utf8)
        data.append(body)
        return data
    }

    private static func parseResponse(_ data: Data, url: URL?) throws -> (Data, HTTPURLResponse) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw FallbackError.invalidResponse
        }

        let headerData = data[..<headerEnd.lowerBound]
        var body = Data(data[headerEnd.upperBound...])
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            throw FallbackError.invalidResponse
        }

        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = headerLines.first else { throw FallbackError.invalidResponse }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw FallbackError.invalidResponse
        }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separator])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        if headers.contains(where: { $0.key.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame && $0.value.lowercased().contains("chunked") }) {
            body = try decodeChunkedBody(body)
        }

        guard let url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
              ) else {
            throw FallbackError.invalidResponse
        }

        return (body, response)
    }

    private static func decodeChunkedBody(_ data: Data) throws -> Data {
        var cursor = data.startIndex
        var output = Data()

        while cursor < data.endIndex {
            guard let lineRange = data[cursor...].range(of: Data("\r\n".utf8)) else {
                throw FallbackError.invalidResponse
            }
            guard let line = String(data: data[cursor..<lineRange.lowerBound], encoding: .ascii),
                  let sizeText = line.split(separator: ";").first,
                  let size = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else {
                throw FallbackError.invalidResponse
            }

            cursor = lineRange.upperBound
            if size == 0 { return output }

            let chunkEnd = cursor + size
            guard chunkEnd <= data.endIndex else { throw FallbackError.invalidResponse }
            output.append(data[cursor..<chunkEnd])
            cursor = chunkEnd

            guard cursor + 2 <= data.endIndex,
                  data[cursor..<cursor + 2] == Data("\r\n".utf8) else {
                throw FallbackError.invalidResponse
            }
            cursor += 2
        }

        return output
    }
}

private final class VoidContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }
}
