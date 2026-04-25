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
}
