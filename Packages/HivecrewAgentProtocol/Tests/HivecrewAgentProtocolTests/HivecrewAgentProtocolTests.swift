//
//  HivecrewAgentProtocolTests.swift
//  HivecrewAgentProtocol
//
//  Created by Hivecrew on 1/11/26.
//

import Testing
@testable import HivecrewAgentProtocol

@Test func testAgentRequestEncoding() throws {
    let request = AgentRequest(id: "test-1", method: "screenshot", params: nil)
    let encoder = JSONEncoder()
    let data = try encoder.encode(request)
    let json = String(data: data, encoding: .utf8)!
    
    #expect(json.contains("\"jsonrpc\":\"2.0\""))
    #expect(json.contains("\"method\":\"screenshot\""))
    #expect(json.contains("\"id\":\"test-1\""))
}

@Test func testAgentResponseEncoding() throws {
    let response = AgentResponse.success(id: "test-1", result: ["status": "ok"])
    let encoder = JSONEncoder()
    let data = try encoder.encode(response)
    let json = String(data: data, encoding: .utf8)!
    
    #expect(json.contains("\"jsonrpc\":\"2.0\""))
    #expect(json.contains("\"id\":\"test-1\""))
}

@Test func testAnyCodableRoundtrip() throws {
    let original: [String: Any] = [
        "string": "hello",
        "int": 42,
        "double": 3.14,
        "bool": true,
        "array": [1, 2, 3],
        "nested": ["key": "value"]
    ]
    
    let anyCodable = AnyCodable(original)
    let encoder = JSONEncoder()
    let data = try encoder.encode(anyCodable)
    
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(AnyCodable.self, from: data)
    
    #expect(decoded.dictValue != nil)
}
