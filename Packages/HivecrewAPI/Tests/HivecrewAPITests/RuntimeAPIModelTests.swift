import Testing
import Foundation
@testable import HivecrewAPIModels

struct RuntimeAPIModelTests {

    // MARK: - CreateTaskRequest

    @Test func createTaskRequestDecodesWithoutRuntimeTarget() throws {
        let json = """
        {
            "description": "test task",
            "providerName": "OpenAI",
            "modelId": "gpt-5"
        }
        """
        let data = json.data(using: .utf8)!
        let request = try JSONDecoder().decode(CreateTaskRequest.self, from: data)
        #expect(request.runtimeTarget == nil)
        #expect(request.description == "test task")
    }

    @Test func createTaskRequestDecodesWithRuntimeTarget() throws {
        let json = """
        {
            "description": "test task",
            "providerName": "OpenAI",
            "modelId": "gpt-5",
            "runtimeTarget": "fast"
        }
        """
        let data = json.data(using: .utf8)!
        let request = try JSONDecoder().decode(CreateTaskRequest.self, from: data)
        #expect(request.runtimeTarget == .fast)
    }

    @Test func createTaskRequestRoundTripsAllRuntimeTargets() throws {
        for target in [APIRuntimeTarget.automatic, .fast, .app, .isolatedVM] {
            let request = CreateTaskRequest(
                description: "test",
                providerName: "P",
                modelId: "m",
                runtimeTarget: target
            )
            let data = try JSONEncoder().encode(request)
            let decoded = try JSONDecoder().decode(CreateTaskRequest.self, from: data)
            #expect(decoded.runtimeTarget == target)
        }
    }

    // MARK: - APITask

    @Test func apiTaskEncodesRuntimeFields() throws {
        let task = APITask(
            id: "1",
            title: "Test",
            description: "desc",
            status: .running,
            providerName: "OpenAI",
            modelId: "gpt-5",
            createdAt: Date(),
            runtimeTarget: .isolatedVM,
            assignedRuntimeKind: .isolatedVM,
            setupRequirement: APITaskSetupRequirement(
                runtimeKind: .app,
                reason: "appPermissionsMissing",
                userFacingMessage: "Grant Accessibility"
            ),
            migrationEvents: [
                APIRuntimeMigrationEvent(
                    id: "evt-1",
                    taskId: "1",
                    sourceRuntime: .fast,
                    destinationRuntime: .isolatedVM,
                    reason: "needs GUI",
                    createdAt: Date()
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(task)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(APITask.self, from: data)

        #expect(decoded.runtimeTarget == .isolatedVM)
        #expect(decoded.assignedRuntimeKind == .isolatedVM)
        #expect(decoded.setupRequirement?.runtimeKind == .app)
        #expect(decoded.migrationEvents?.count == 1)
        #expect(decoded.migrationEvents?.first?.sourceRuntime == .fast)
    }

    @Test func apiTaskDecodesWithNilRuntimeFields() throws {
        let task = APITask(
            id: "2",
            title: "Test",
            description: "desc",
            status: .queued,
            providerName: "P",
            modelId: "m",
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(task)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(APITask.self, from: data)

        #expect(decoded.runtimeTarget == nil)
        #expect(decoded.assignedRuntimeKind == nil)
        #expect(decoded.setupRequirement == nil)
        #expect(decoded.migrationEvents == nil)
    }

    // MARK: - APITaskSummary

    @Test func apiTaskSummaryEncodesRuntimeFields() throws {
        let summary = APITaskSummary(
            id: "1",
            title: "Test",
            status: .running,
            providerName: "P",
            modelId: "m",
            createdAt: Date(),
            runtimeTarget: .fast,
            assignedRuntimeKind: .fast
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(summary)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(APITaskSummary.self, from: data)

        #expect(decoded.runtimeTarget == .fast)
        #expect(decoded.assignedRuntimeKind == .fast)
    }

    // MARK: - Batch request

    @Test func batchRequestDecodesWithRuntimeTarget() throws {
        let json = """
        {
            "description": "test batch",
            "targets": [{"providerId": "p1", "modelId": "m1", "copyCount": 1}],
            "runtimeTarget": "isolatedVM"
        }
        """
        let data = json.data(using: .utf8)!
        let request = try JSONDecoder().decode(CreateTaskBatchRequest.self, from: data)
        #expect(request.runtimeTarget == .isolatedVM)
    }

    // MARK: - PeerAnnouncement backward compatibility

    @Test func peerAnnouncementDecodesWithoutRuntimes() throws {
        let json = """
        {
            "tunnelId": "t1",
            "subdomain": "mac-1",
            "tunnelUrl": "https://mac-1.example.com",
            "availableSlots": 3,
            "runningTasks": 1,
            "queuedTasks": 0
        }
        """
        let data = json.data(using: .utf8)!
        let announcement = try JSONDecoder().decode(PeerAnnouncement.self, from: data)
        #expect(announcement.runtimes == nil)
        #expect(announcement.availableSlots == 3)
    }

    @Test func peerAnnouncementDecodesWithRuntimes() throws {
        let json = """
        {
            "tunnelId": "t1",
            "subdomain": "mac-1",
            "tunnelUrl": "https://mac-1.example.com",
            "availableSlots": 3,
            "runningTasks": 1,
            "queuedTasks": 0,
            "runtimes": [
                {
                    "runtimeKind": "fast",
                    "supported": true,
                    "availableSlots": 2,
                    "runningTasks": 1,
                    "queuedTasks": 0,
                    "setupStatus": "ready"
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let announcement = try JSONDecoder().decode(PeerAnnouncement.self, from: data)
        #expect(announcement.runtimes?.count == 1)
        #expect(announcement.runtimes?.first?.runtimeKind == .fast)
        #expect(announcement.runtimes?.first?.setupStatus == .ready)
    }

    // MARK: - APIClusterPeer backward compatibility

    @Test func apiClusterPeerDecodesWithoutRuntimes() throws {
        let json = """
        {
            "tunnelId": "t1",
            "subdomain": "mac-1",
            "status": "online",
            "availableSlots": 3,
            "runningTasks": 1,
            "lastSeen": "2025-01-01T00:00:00Z"
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let peer = try decoder.decode(APIClusterPeer.self, from: data)
        #expect(peer.runtimes == nil)
    }

    @Test func apiClusterPeerDecodesWithRuntimes() throws {
        let json = """
        {
            "tunnelId": "t1",
            "subdomain": "mac-1",
            "status": "online",
            "availableSlots": 3,
            "runningTasks": 1,
            "lastSeen": "2025-01-01T00:00:00Z",
            "runtimes": [
                {
                    "runtimeKind": "app",
                    "supported": true,
                    "availableSlots": 1,
                    "runningTasks": 0,
                    "queuedTasks": 0,
                    "setupStatus": "permissionsMissing"
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let peer = try decoder.decode(APIClusterPeer.self, from: data)
        #expect(peer.runtimes?.count == 1)
        #expect(peer.runtimes?.first?.setupStatus == .permissionsMissing)
    }

    // MARK: - APIClusterStatus backward compatibility

    @Test func apiClusterStatusDecodesWithoutLocalRuntimes() throws {
        let json = """
        {
            "role": "standalone",
            "totalCapacity": 5,
            "totalRunning": 1,
            "totalQueued": 0,
            "localCapacity": 5,
            "localRunning": 1,
            "peers": []
        }
        """
        let data = json.data(using: .utf8)!
        let status = try JSONDecoder().decode(APIClusterStatus.self, from: data)
        #expect(status.localRuntimes == nil)
        #expect(status.localAvailableSlots == 5)
    }

    @Test func apiClusterStatusDecodesWithLocalRuntimes() throws {
        let json = """
        {
            "role": "standalone",
            "totalCapacity": 5,
            "totalRunning": 1,
            "totalQueued": 0,
            "localCapacity": 5,
            "localAvailableSlots": 4,
            "localRunning": 1,
            "localQueued": 0,
            "localRuntimes": [
                {
                    "runtimeKind": "isolatedVM",
                    "supported": true,
                    "availableSlots": 2,
                    "runningTasks": 1,
                    "queuedTasks": 0,
                    "setupStatus": "ready"
                }
            ],
            "peers": []
        }
        """
        let data = json.data(using: .utf8)!
        let status = try JSONDecoder().decode(APIClusterStatus.self, from: data)
        #expect(status.localRuntimes?.count == 1)
        #expect(status.localRuntimes?.first?.runtimeKind == .isolatedVM)
    }

    // MARK: - APISystemStatus backward compatibility

    @Test func apiSystemStatusDecodesWithoutRuntimes() throws {
        let json = """
        {
            "status": "ok",
            "version": "1.0",
            "uptime": 3600,
            "agents": {"running": 1, "paused": 0, "queued": 2, "maxConcurrent": 5},
            "vms": {"active": 1, "pending": 0, "available": 3},
            "resources": {}
        }
        """
        let data = json.data(using: .utf8)!
        let status = try JSONDecoder().decode(APISystemStatus.self, from: data)
        #expect(status.runtimes == nil)
    }

    @Test func apiSystemStatusDecodesWithRuntimes() throws {
        let json = """
        {
            "status": "ok",
            "version": "1.0",
            "uptime": 3600,
            "agents": {"running": 1, "paused": 0, "queued": 2, "maxConcurrent": 5},
            "vms": {"active": 1, "pending": 0, "available": 3},
            "resources": {},
            "runtimes": [
                {
                    "kind": "fast",
                    "supported": true,
                    "running": 1,
                    "queued": 0,
                    "available": 4,
                    "maxConcurrent": 5,
                    "setupStatus": "ready"
                },
                {
                    "kind": "app",
                    "supported": false,
                    "running": 0,
                    "queued": 0,
                    "available": 0,
                    "maxConcurrent": 1,
                    "setupStatus": "backendMissing"
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let status = try JSONDecoder().decode(APISystemStatus.self, from: data)
        #expect(status.runtimes?.count == 2)
        #expect(status.runtimes?.first?.kind == .fast)
        #expect(status.runtimes?.last?.setupStatus == .backendMissing)
    }

    // MARK: - ClusterExecuteNowRequest backward compatibility

    @Test func clusterExecuteNowRequestDecodesWithoutRuntimeTarget() throws {
        let json = """
        {
            "canonicalTaskId": "t1",
            "ownerTunnelId": "tunnel-1",
            "ownerLeaseId": "lease-1",
            "executionAttempt": 1,
            "description": "Do something",
            "providerName": "OpenAI",
            "modelId": "gpt-5",
            "attachedFilePaths": [],
            "planFirst": false,
            "mentionedSkillNames": [],
            "referencedTaskIds": [],
            "contextSuggestionIds": [],
            "contextModeOverrides": {},
            "contextInlineBlocks": [],
            "contextAttachmentPaths": [],
            "referenceContextBlocks": [],
            "referenceFiles": []
        }
        """
        let data = json.data(using: .utf8)!
        let request = try JSONDecoder().decode(ClusterExecuteNowRequest.self, from: data)
        #expect(request.runtimeTarget == nil)
    }

    @Test func clusterExecuteNowRequestDecodesWithRuntimeTarget() throws {
        let json = """
        {
            "canonicalTaskId": "t1",
            "ownerTunnelId": "tunnel-1",
            "ownerLeaseId": "lease-1",
            "executionAttempt": 1,
            "description": "Do something",
            "providerName": "OpenAI",
            "modelId": "gpt-5",
            "attachedFilePaths": [],
            "planFirst": false,
            "mentionedSkillNames": [],
            "referencedTaskIds": [],
            "contextSuggestionIds": [],
            "contextModeOverrides": {},
            "contextInlineBlocks": [],
            "contextAttachmentPaths": [],
            "referenceContextBlocks": [],
            "referenceFiles": [],
            "runtimeTarget": "app"
        }
        """
        let data = json.data(using: .utf8)!
        let request = try JSONDecoder().decode(ClusterExecuteNowRequest.self, from: data)
        #expect(request.runtimeTarget == .app)
    }

    // MARK: - PeerRuntimeSummary round-trip

    @Test func peerRuntimeSummaryRoundTrips() throws {
        let summary = PeerRuntimeSummary(
            runtimeKind: .isolatedVM,
            supported: true,
            availableSlots: 3,
            runningTasks: 1,
            queuedTasks: 2,
            setupStatus: .ready
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(PeerRuntimeSummary.self, from: data)
        #expect(decoded == summary)
    }

    // MARK: - APIRuntimeCounts round-trip

    @Test func apiRuntimeCountsRoundTrips() throws {
        let counts = APIRuntimeCounts(
            kind: .app,
            supported: true,
            running: 1,
            queued: 0,
            available: 2,
            maxConcurrent: 3,
            setupStatus: .permissionsMissing
        )
        let data = try JSONEncoder().encode(counts)
        let decoded = try JSONDecoder().decode(APIRuntimeCounts.self, from: data)
        #expect(decoded.kind == .app)
        #expect(decoded.setupStatus == .permissionsMissing)
        #expect(decoded.maxConcurrent == 3)
    }
}
