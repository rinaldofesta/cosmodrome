import XCTest
@testable import Core

final class MCPServerTests: XCTestCase {

    func testToolDefinitionsExist() {
        let tools = MCPServer.toolDefinitions
        XCTAssertFalse(tools.isEmpty)

        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("list_projects"))
        XCTAssertTrue(names.contains("list_sessions"))
        XCTAssertTrue(names.contains("get_session_content"))
        XCTAssertTrue(names.contains("send_input"))
        XCTAssertTrue(names.contains("get_agent_states"))
        XCTAssertTrue(names.contains("focus_session"))
        XCTAssertTrue(names.contains("start_recording"))
        XCTAssertTrue(names.contains("stop_recording"))
    }

    func testToolDefinitionsHaveDescriptions() {
        for tool in MCPServer.toolDefinitions {
            XCTAssertNotNil(tool["name"] as? String)
            XCTAssertNotNil(tool["description"] as? String)
            XCTAssertNotNil(tool["inputSchema"] as? [String: Any])
        }
    }

    func testToolDefinitionsInputSchemas() {
        for tool in MCPServer.toolDefinitions {
            let schema = tool["inputSchema"] as? [String: Any]
            XCTAssertNotNil(schema)
            XCTAssertEqual(schema?["type"] as? String, "object")
        }
    }

    func testToolCount() {
        XCTAssertEqual(MCPServer.toolDefinitions.count, 8)
    }

    func testRequiredParameters() {
        let tools = MCPServer.toolDefinitions
        let sendInput = tools.first { $0["name"] as? String == "send_input" }!
        let schema = sendInput["inputSchema"] as! [String: Any]
        let required = schema["required"] as? [String]
        XCTAssertNotNil(required)
        XCTAssertTrue(required!.contains("session_id"))
        XCTAssertTrue(required!.contains("text"))
    }

    func testServerInitialization() {
        let server = MCPServer()
        XCTAssertNil(server.delegate)
    }
}
