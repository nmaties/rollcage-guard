import XCTest
@testable import RollcageGuardCore

final class HookTests: XCTestCase {
    let config = GuardConfig()

    func decision(_ out: [String: Any]?) -> String? {
        (out?["hookSpecificOutput"] as? [String: Any])?["permissionDecision"] as? String
    }

    func testClaudeCode() {
        let read: [String: Any] = ["tool_name": "Read", "tool_input": ["file_path": "/p/.env"], "cwd": "/p"]
        XCTAssertEqual(decision(Hook.handle(agent: "claude", event: "", json: read, config: config, log: false)), "deny")

        let push: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "git reset --hard"], "cwd": "/p"]
        XCTAssertEqual(decision(Hook.handle(agent: "claude", event: "", json: push, config: config, log: false)), "ask")

        let fine: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "npm test"], "cwd": "/p"]
        XCTAssertNil(Hook.handle(agent: "claude", event: "", json: fine, config: config, log: false))

        let grep: [String: Any] = ["tool_name": "Grep", "tool_input": ["pattern": "KEY", "path": "/p/.env.local"]]
        XCTAssertEqual(decision(Hook.handle(agent: "claude", event: "", json: grep, config: config, log: false)), "deny")
    }

    func testCodexCannotAskSoItBlocks() {
        let json: [String: Any] = ["tool_name": "shell", "tool_input": ["command": ["bash", "-lc", "git reset --hard"]]]
        XCTAssertEqual(decision(Hook.handle(agent: "codex", event: "", json: json, config: config, log: false)), "deny")
    }

    func testCodexPatch() {
        let patch = "*** Begin Patch\n*** Update File: config/.env.production\n@@\n-A=1\n+A=2\n*** End Patch"
        let call = Hook.toolCall(agent: "codex", event: "", json: ["tool_name": "apply_patch", "tool_input": ["command": ["apply_patch", patch]]])
        XCTAssertEqual(call.paths, ["config/.env.production"])
        XCTAssertEqual(GuardEngine.evaluate(call, config: config)?.action, .block)
    }

    func testCursor() {
        let shell = Hook.handle(agent: "cursor", event: "shell", json: ["command": "git push -f origin main"], config: config, log: false)
        XCTAssertEqual(shell?["permission"] as? String, "ask")

        let read = Hook.handle(agent: "cursor", event: "read", json: ["file_path": "/p/secrets.json"], config: config, log: false)
        XCTAssertEqual(read?["permission"] as? String, "deny")
        XCTAssertNil(read?["agent_message"])

        let mcp = Hook.handle(agent: "cursor", event: "mcp",
                              json: ["tool_name": "fetch", "tool_input": #"{"url":"https://pastebin.com/raw/x"}"#], config: config, log: false)
        XCTAssertEqual(mcp?["permission"] as? String, "deny")

        let ok = Hook.handle(agent: "cursor", event: "shell", json: ["command": "ls"], config: config, log: false)
        XCTAssertEqual(ok?["permission"] as? String, "allow")
    }

    func testGemini() {
        let out = Hook.handle(agent: "gemini", event: "", json: ["tool_name": "run_shell_command", "tool_input": ["command": "printenv"]],
                              config: config, log: false)
        XCTAssertEqual(out?["decision"] as? String, "deny")
    }
}
