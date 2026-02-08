//
//  HivecrewAPIServer.swift
//  HivecrewAPI
//
//  Main API server with start/stop lifecycle
//

import Foundation
import Hummingbird
import NIOCore
import NIOPosix
import HTTPTypes
import Logging

/// Main Hivecrew REST API server
public actor HivecrewAPIServer {
    
    /// Current server configuration
    private let configuration: APIConfiguration
    
    /// Service provider for handling requests
    private let serviceProvider: APIServiceProvider
    
    /// File storage for uploads and downloads
    private let fileStorage: TaskFileStorage
    
    /// Device session manager for pairing-based authentication
    private let deviceSessionManager: DeviceSessionManager?
    
    /// Running server instance
    private var application: (any ApplicationProtocol)?
    
    /// Logger
    private let logger: Logger
    
    /// Server start time for uptime calculation
    private var startTime: Date?
    
    /// Whether the server is currently running
    public var isRunning: Bool {
        application != nil
    }
    
    public init(
        configuration: APIConfiguration,
        serviceProvider: APIServiceProvider,
        fileStorage: TaskFileStorage? = nil,
        deviceSessionManager: DeviceSessionManager? = nil
    ) {
        self.configuration = configuration
        self.serviceProvider = serviceProvider
        self.fileStorage = fileStorage ?? TaskFileStorage()
        self.deviceSessionManager = deviceSessionManager
        
        var logger = Logger(label: "com.pattonium.api")
        logger.logLevel = .info
        self.logger = logger
    }
    
    /// Start the API server
    public func start() async throws {
        guard !isRunning else {
            logger.warning("API server is already running")
            return
        }
        
        // Ensure file storage directories exist
        try await fileStorage.ensureDirectoriesExist()
        
        // Create router
        let router = buildRouter()
        
        // Create and configure the application
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(configuration.host, port: configuration.port),
                serverName: "HivecrewAPI"
            ),
            logger: logger
        )
        
        self.application = app
        self.startTime = Date()
        
        logger.info("Starting Hivecrew API server on \(configuration.host):\(configuration.port)")
        
        // Run the server
        try await app.run()
    }
    
    /// Stop the API server
    public func stop() async {
        guard isRunning else {
            logger.warning("API server is not running")
            return
        }
        
        logger.info("Stopping Hivecrew API server")
        
        // The application will stop when cancelled
        application = nil
        startTime = nil
    }
    
    /// Get server uptime in seconds
    public var uptime: Int {
        guard let start = startTime else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }
    
    // MARK: - Router Configuration
    
    private func buildRouter() -> Router<APIRequestContext> {
        let router = Router(context: APIRequestContext.self)
        
        // Add error handling middleware
        router.middlewares.add(ErrorMiddleware())
        
        // Add CORS middleware for cross-origin requests
        router.middlewares.add(CORSMiddleware())
        
        // Add authentication middleware for API routes
        // Pairing and auth check endpoints are excluded from auth
        router.middlewares.add(AuthMiddleware<APIRequestContext>(
            apiKey: configuration.apiKey,
            pathPrefix: "/api/",
            deviceSessionManager: deviceSessionManager,
            unauthenticatedPrefixes: [
                "/api/v1/auth/pair/",
                "/api/v1/auth/check"
            ]
        ))
        
        // Create API v1 group
        let apiV1 = router.group("api/v1")
        
        // Register device auth routes
        if let deviceSessionManager = deviceSessionManager {
            DeviceAuthRoutes(
                deviceSessionManager: deviceSessionManager,
                sessionMaxAgeDays: configuration.sessionMaxAgeDays
            ).register(with: apiV1)
        }
        
        // Register routes
        TaskRoutes(
            serviceProvider: serviceProvider,
            fileStorage: fileStorage,
            maxFileSize: configuration.maxFileSize,
            maxTotalUploadSize: configuration.maxTotalUploadSize
        ).register(with: apiV1)
        
        ScheduleRoutes(
            serviceProvider: serviceProvider,
            fileStorage: fileStorage,
            maxFileSize: configuration.maxFileSize,
            maxTotalUploadSize: configuration.maxTotalUploadSize
        ).register(with: apiV1)
        
        ProviderRoutes(serviceProvider: serviceProvider).register(with: apiV1)
        TemplateRoutes(serviceProvider: serviceProvider).register(with: apiV1)
        SkillRoutes(serviceProvider: serviceProvider).register(with: apiV1)
        SystemRoutes(serviceProvider: serviceProvider).register(with: apiV1)
        EventRoutes(serviceProvider: serviceProvider).register(with: apiV1)
        
        // Health check endpoint (no auth required)
        router.get("health") { _, _ in
            return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "OK")))
        }
        
        // Register web UI routes (no auth required)
        WebRoutes().register(with: router)
        
        return router
    }
}

// MARK: - Error Handling Middleware

/// Middleware to convert errors to JSON responses
struct ErrorMiddleware: RouterMiddleware {
    typealias Context = APIRequestContext
    
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as APIError {
            return try createErrorResponse(error)
        } catch let error as DecodingError {
            let message = "Invalid request body: \(error.localizedDescription)"
            return try createErrorResponse(APIError.badRequest(message))
        } catch {
            let message = "Internal server error: \(error.localizedDescription)"
            return try createErrorResponse(APIError.internalError(message))
        }
    }
    
    private func createErrorResponse(_ error: APIError) throws -> Response {
        let encoder = JSONEncoder()
        let data = try encoder.encode(error.response)
        
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        
        return Response(
            status: error.status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }
}

// MARK: - CORS Middleware

/// Middleware to handle CORS headers
struct CORSMiddleware: RouterMiddleware {
    typealias Context = APIRequestContext
    
    private static let accessControlAllowCredentials = HTTPField.Name("Access-Control-Allow-Credentials")!
    private static let originHeaderName = HTTPField.Name("Origin")!
    
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        // Determine origin for credentials support
        let origin = request.headers[Self.originHeaderName] ?? "*"
        let allowOrigin = origin.isEmpty ? "*" : origin
        
        // Handle preflight requests
        if request.method == .options {
            var headers = HTTPFields()
            headers[.accessControlAllowOrigin] = allowOrigin
            headers[.accessControlAllowMethods] = "GET, POST, PATCH, DELETE, OPTIONS"
            headers[.accessControlAllowHeaders] = "Authorization, Content-Type"
            headers[Self.accessControlAllowCredentials] = "true"
            headers[.accessControlMaxAge] = "86400"
            return Response(status: .noContent, headers: headers)
        }
        
        var response = try await next(request, context)
        response.headers[.accessControlAllowOrigin] = allowOrigin
        response.headers[Self.accessControlAllowCredentials] = "true"
        return response
    }
}
