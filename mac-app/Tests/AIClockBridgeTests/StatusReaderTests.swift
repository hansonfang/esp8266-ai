import Foundation
import XCTest
@testable import AIClockBridge

final class StatusReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiclock-status-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func iso(_ offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset))
    }

    private func writeRollout(id: String, sessionID: String, source: Any = "vscode",
                              events: [[String: Any]]) throws {
        let meta: [String: Any] = [
            "timestamp": iso(-60), "type": "session_meta",
            "payload": ["id": id, "session_id": sessionID, "source": source],
        ]
        let objects = [meta] + events
        let lines = try objects.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        try lines.joined(separator: "\n").appending("\n").write(
            to: root.appendingPathComponent("rollout-\(id).jsonl"), atomically: true,
            encoding: .utf8)
    }

    private func lifecycle(_ type: String, at offset: TimeInterval,
                           message: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["type": type]
        if let message { payload["last_agent_message"] = message }
        return ["timestamp": iso(offset), "type": "event_msg", "payload": payload]
    }

    private func snapshot() -> CodexStatus {
        StatusService(claudeDir: root.appendingPathComponent("claude").path,
                      codexDir: root.path).snapshot().codex
    }

    func testSubagentCompletionDoesNotStopParentOrSibling() throws {
        let session = "parent"
        try writeRollout(id: session, sessionID: session,
                         events: [lifecycle("task_started", at: -20)])
        let childSource: (String) -> Any = { name in
            ["subagent": ["thread_spawn": ["parent_thread_id": session,
                                             "agent_path": "/root/\(name)"]]]
        }
        try writeRollout(id: "child-done", sessionID: session, source: childSource("done"),
                         events: [lifecycle("task_started", at: -18),
                                  lifecycle("task_complete", at: -10)])
        try writeRollout(id: "child-running", sessionID: session, source: childSource("running"),
                         events: [lifecycle("task_started", at: -8)])
        try writeRollout(id: "guardian", sessionID: session,
                         source: ["subagent": ["other": "guardian"]],
                         events: [lifecycle("task_started", at: -5)])

        let status = snapshot()
        XCTAssertEqual(status.status, "working")
        XCTAssertEqual(status.activeTasks, 2)
        XCTAssertFalse(status.needsInput)
    }

    func testAnsweredInputCallReturnsToWorking() throws {
        let callID = "question-1"
        let call: [String: Any] = [
            "timestamp": iso(-10), "type": "response_item",
            "payload": ["type": "function_call", "name": "request_user_input",
                        "call_id": callID],
        ]
        let output: [String: Any] = [
            "timestamp": iso(-5), "type": "response_item",
            "payload": ["type": "function_call_output", "call_id": callID, "output": "ok"],
        ]
        try writeRollout(id: "main", sessionID: "main", events: [call, output])

        let status = snapshot()
        XCTAssertEqual(status.status, "working")
        XCTAssertEqual(status.activeTasks, 1)
        XCTAssertFalse(status.needsInput)
    }

    func testGenuineQuestionRemainsActionableWhileAnotherExecutionRuns() throws {
        try writeRollout(id: "waiting", sessionID: "waiting",
                         events: [lifecycle("task_complete", at: -15,
                                            message: "请选择下一步？")])
        try writeRollout(id: "running", sessionID: "running",
                         events: [lifecycle("task_started", at: -5)])

        let status = snapshot()
        XCTAssertEqual(status.status, "waiting")
        XCTAssertEqual(status.activeTasks, 1)
        XCTAssertTrue(status.needsInput)
    }

    func testQuestionWithoutRunnableWorkWaits() throws {
        try writeRollout(id: "waiting", sessionID: "waiting",
                         events: [lifecycle("task_complete", at: -5,
                                            message: "请确认是否继续？")])

        let status = snapshot()
        XCTAssertEqual(status.status, "waiting")
        XCTAssertEqual(status.activeTasks, 0)
        XCTAssertTrue(status.needsInput)
    }
}
