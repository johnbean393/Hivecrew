//
//  WebRoutes.swift
//  HivecrewAPI
//
//  Routes for serving the web UI static files
//

import Foundation
import Hummingbird
import NIOCore
import HTTPTypes

/// Routes for serving the web UI
public final class WebRoutes: Sendable {
    
    public init() {}
    
    public func register(with router: Router<APIRequestContext>) {
        // Serve index.html at /web
        router.get("web") { _, _ in
            try Self.serveStaticFile(filename: "index.html")
        }
        
        // Serve CSS files
        router.get("web/css/{file}") { _, context in
            guard let file = context.parameters.get("file") else {
                throw APIError.notFound("File not found")
            }
            return try Self.serveStaticFile(filename: "css/\(file)")
        }
        
        // Serve JS files
        router.get("web/js/{file}") { _, context in
            guard let file = context.parameters.get("file") else {
                throw APIError.notFound("File not found")
            }
            return try Self.serveStaticFile(filename: "js/\(file)")
        }
    }
    
    // MARK: - Resource Location
    
    /// Find the WebUI directory, trying multiple bundle locations
    private static func findWebUIDirectory() -> URL? {
        // Try 1: Bundle.module (SPM resource bundle) - works when resources are at bundle root
        if let url = Bundle.module.url(forResource: "WebUI", withExtension: nil) {
            return url
        }
        
        // Try 2: Bundle.module resourcePath + WebUI (common SPM structure)
        if let resourcePath = Bundle.module.resourcePath {
            let webUIPath = URL(fileURLWithPath: resourcePath).appendingPathComponent("WebUI")
            if FileManager.default.fileExists(atPath: webUIPath.path) {
                return webUIPath
            }
        }
        
        // Try 3: Look for HivecrewAPI_HivecrewAPI.bundle in the main bundle's resources
        if let bundleURL = Bundle.main.url(forResource: "HivecrewAPI_HivecrewAPI", withExtension: "bundle") {
            // The bundle has Contents/Resources/WebUI structure
            let webUIPath = bundleURL.appendingPathComponent("Contents/Resources/WebUI")
            if FileManager.default.fileExists(atPath: webUIPath.path) {
                return webUIPath
            }
            
            // Also try via Bundle API
            if let resourceBundle = Bundle(url: bundleURL),
               let url = resourceBundle.url(forResource: "WebUI", withExtension: nil) {
                return url
            }
        }
        
        // Try 4: Look directly in the main bundle
        if let url = Bundle.main.url(forResource: "WebUI", withExtension: nil) {
            return url
        }
        
        // Try 5: Search in main bundle's resource directory
        if let resourcePath = Bundle.main.resourcePath {
            let resourceURL = URL(fileURLWithPath: resourcePath)
            
            // Check for nested bundle
            let nestedBundlePath = resourceURL
                .appendingPathComponent("HivecrewAPI_HivecrewAPI.bundle")
                .appendingPathComponent("Contents/Resources/WebUI")
            if FileManager.default.fileExists(atPath: nestedBundlePath.path) {
                return nestedBundlePath
            }
            
            // Check directly in resources
            let directPath = resourceURL.appendingPathComponent("WebUI")
            if FileManager.default.fileExists(atPath: directPath.path) {
                return directPath
            }
        }
        
        return nil
    }
    
    // MARK: - File Serving
    
    private static func serveStaticFile(filename: String) throws -> Response {
        // Sanitize path to prevent directory traversal
        let sanitizedPath = filename
            .replacingOccurrences(of: "..", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        // Find the WebUI directory
        guard let resourceURL = findWebUIDirectory() else {
            throw APIError.internalError("Web UI resources not found. The WebUI bundle may not be properly embedded.")
        }
        
        // Build the file path
        let fileURL = resourceURL.appendingPathComponent(sanitizedPath)
        
        // Check if file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // If not found and not a file with extension, try serving index.html (SPA routing)
            if !sanitizedPath.contains(".") {
                let indexURL = resourceURL.appendingPathComponent("index.html")
                if FileManager.default.fileExists(atPath: indexURL.path) {
                    return try createFileResponse(from: indexURL, filename: "index.html")
                }
            }
            throw APIError.notFound("File not found: \(sanitizedPath)")
        }
        
        return try createFileResponse(from: fileURL, filename: sanitizedPath)
    }
    
    private static func createFileResponse(from url: URL, filename: String) throws -> Response {
        let data = try Data(contentsOf: url)
        let mimeType = mimeType(for: filename)
        
        var headers = HTTPFields()
        headers[.contentType] = mimeType
        headers[.contentLength] = "\(data.count)"
        
        // Cache control based on file type
        if filename.hasSuffix(".html") || filename.hasSuffix(".htm") {
            // Don't cache HTML - always revalidate to get fresh content
            headers[.cacheControl] = "no-cache, must-revalidate"
        } else if filename.hasSuffix(".js") || filename.hasSuffix(".css") {
            // Cache JS/CSS with version query params for cache busting
            headers[.cacheControl] = "public, max-age=86400"
        }
        
        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }
    
    private static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        
        switch ext {
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "css":
            return "text/css; charset=utf-8"
        case "js":
            return "application/javascript; charset=utf-8"
        case "json":
            return "application/json; charset=utf-8"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "svg":
            return "image/svg+xml"
        case "ico":
            return "image/x-icon"
        case "woff":
            return "font/woff"
        case "woff2":
            return "font/woff2"
        case "ttf":
            return "font/ttf"
        default:
            return "application/octet-stream"
        }
    }
}
