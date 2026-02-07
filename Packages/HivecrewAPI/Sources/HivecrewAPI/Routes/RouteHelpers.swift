//
//  RouteHelpers.swift
//  HivecrewAPI
//
//  Shared utilities for route handlers: JSON response building,
//  query string parsing, and multipart form data parsing.
//

import Foundation
import Hummingbird
import NIOCore
import HTTPTypes

// MARK: - JSON Response Builder

/// Creates a JSON-encoded `Response` with ISO 8601 date formatting.
///
/// Used by all route handlers to ensure consistent encoding across endpoints.
func createJSONResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    
    return Response(
        status: status,
        headers: headers,
        body: .init(byteBuffer: ByteBuffer(data: data))
    )
}

// MARK: - Query String Parsing

/// Parses URL query parameters into a dictionary.
///
/// Handles percent-encoded keys and values. For duplicate keys the last value wins.
func parseQueryItems(from urlString: String) -> [String: String] {
    var items: [String: String] = [:]
    
    guard let queryStart = urlString.firstIndex(of: "?") else {
        return items
    }
    
    let queryString = String(urlString[urlString.index(after: queryStart)...])
    let pairs = queryString.split(separator: "&")
    
    for pair in pairs {
        let keyValue = pair.split(separator: "=", maxSplits: 1)
        if keyValue.count == 2 {
            let key = String(keyValue[0]).removingPercentEncoding ?? String(keyValue[0])
            let value = String(keyValue[1]).removingPercentEncoding ?? String(keyValue[1])
            items[key] = value
        }
    }
    
    return items
}

// MARK: - Multipart Form Data Parsing

/// A single part extracted from a multipart/form-data request body.
struct MultipartPart {
    let name: String?
    let filename: String?
    let data: Data
}

/// Extracts the multipart boundary string from a Content-Type header value.
///
/// - Throws: `APIError.badRequest` if the header is missing or malformed.
func extractMultipartBoundary(from request: Request) throws -> String {
    guard let contentTypeHeader = request.headers[.contentType] else {
        throw APIError.badRequest("Missing Content-Type header")
    }
    
    let contentType = String(contentTypeHeader)
    guard let boundaryRange = contentType.range(of: "boundary=") else {
        throw APIError.badRequest("Missing boundary in Content-Type")
    }
    
    var boundary = String(contentType[boundaryRange.upperBound...])
    // Remove quotes if present
    if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
        boundary = String(boundary.dropFirst().dropLast())
    }
    
    return boundary
}

/// Parses raw multipart/form-data bytes into an array of `MultipartPart` values.
func parseMultipartData(data: Data, boundary: String) -> [MultipartPart] {
    var parts: [MultipartPart] = []
    let boundaryData = "--\(boundary)".data(using: .utf8)!
    let endBoundaryData = "--\(boundary)--".data(using: .utf8)!
    let crlfData = "\r\n".data(using: .utf8)!
    let doubleCrlfData = "\r\n\r\n".data(using: .utf8)!
    
    var currentIndex = data.startIndex
    
    while currentIndex < data.endIndex {
        // Find next boundary
        guard let boundaryRange = data.range(of: boundaryData, in: currentIndex..<data.endIndex) else {
            break
        }
        
        // Move past boundary and CRLF
        var partStart = boundaryRange.upperBound
        if data[partStart..<min(partStart + 2, data.endIndex)] == crlfData {
            partStart = data.index(partStart, offsetBy: 2)
        }
        
        // Check for end boundary
        if data[boundaryRange.lowerBound..<min(data.index(boundaryRange.lowerBound, offsetBy: endBoundaryData.count), data.endIndex)] == endBoundaryData {
            break
        }
        
        // Find headers/body separator
        guard let headerEndRange = data.range(of: doubleCrlfData, in: partStart..<data.endIndex) else {
            currentIndex = boundaryRange.upperBound
            continue
        }
        
        // Parse headers
        let headersData = data[partStart..<headerEndRange.lowerBound]
        let headersString = String(data: headersData, encoding: .utf8) ?? ""
        
        var name: String?
        var filename: String?
        
        for line in headersString.split(separator: "\r\n") {
            let lineStr = String(line)
            if lineStr.lowercased().hasPrefix("content-disposition:") {
                // Parse Content-Disposition header
                if let nameMatch = lineStr.range(of: "name=\"") {
                    let start = nameMatch.upperBound
                    if let end = lineStr[start...].firstIndex(of: "\"") {
                        name = String(lineStr[start..<end])
                    }
                }
                if let filenameMatch = lineStr.range(of: "filename=\"") {
                    let start = filenameMatch.upperBound
                    if let end = lineStr[start...].firstIndex(of: "\"") {
                        filename = String(lineStr[start..<end])
                    }
                }
            }
        }
        
        // Find part end (next boundary)
        let bodyStart = headerEndRange.upperBound
        var bodyEnd = data.endIndex
        
        if let nextBoundaryRange = data.range(of: boundaryData, in: bodyStart..<data.endIndex) {
            // Remove trailing CRLF before boundary
            bodyEnd = nextBoundaryRange.lowerBound
            if bodyEnd > bodyStart && data[data.index(bodyEnd, offsetBy: -2)..<bodyEnd] == crlfData {
                bodyEnd = data.index(bodyEnd, offsetBy: -2)
            }
        }
        
        let partData = data[bodyStart..<bodyEnd]
        parts.append(MultipartPart(name: name, filename: filename, data: Data(partData)))
        
        currentIndex = bodyEnd
    }
    
    return parts
}

// MARK: - JSON Decoding

/// Shared ISO 8601 JSON decoder for request bodies.
func makeISO8601Decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}
