import XCTest
@testable import RollcageGuardCore

final class InstallerTests: XCTestCase {
    let bin = "/usr/local/bin/rollcage-guard"
    let appHook = "\"/Users/me/Library/Application Support/Rollcage/bin/rollcage-guard\" --agent claude"

    func testClaudeKeepsTheUsersOwnHooks() throws {
        var root: [String: Any] = [
            "model": "opus",
            "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "my-linter"]]]]],
        ]
        try Installer.addHook(agent: "claude", binary: bin, to: &root)
        try Installer.addHook(agent: "claude", binary: bin, to: &root)   // reinstalling doesn't duplicate
        let commands = Installer.hookCommands(in: root)
        XCTAssertEqual(commands.sorted(), ["\"\(bin)\" --agent claude", "my-linter"])
        XCTAssertEqual(root["model"] as? String, "opus")

        Installer.removeHook(from: &root)
        XCTAssertEqual(Installer.hookCommands(in: root), ["my-linter"])
    }

    func testRemovingLeavesTheAppsHookAlone() {
        var root: [String: Any] = ["hooks": ["PreToolUse": [
            ["matcher": "*", "hooks": [["type": "command", "command": appHook]]],
            ["matcher": "*", "hooks": [["type": "command", "command": "\"\(bin)\" --agent claude"]]],
        ]]]
        Installer.removeHook(from: &root)
        XCTAssertEqual(Installer.hookCommands(in: root), [appHook])
        XCTAssertTrue(Installer.isAppHook(appHook))
        XCTAssertFalse(Installer.isOurHook(appHook))
    }

    func testCursorLayout() throws {
        var root: [String: Any] = [:]
        try Installer.addHook(agent: "cursor", binary: bin, to: &root)
        XCTAssertEqual(root["version"] as? Int, 1)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["beforeShellExecution"] as? [[String: Any]])?.first?["command"] as? String,
                       "\"\(bin)\" --agent cursor --event shell")
        XCTAssertNotNil(hooks["beforeReadFile"])
        XCTAssertNotNil(hooks["beforeMCPExecution"])
        Installer.removeHook(from: &root)
        XCTAssertNil(root["hooks"])
    }

    func testInstallAndStateOnDisk() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rg-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let targets = Installer.targets(home: home)
        let claude = try XCTUnwrap(targets.first { $0.id == "claude" })
        XCTAssertEqual(Installer.state(of: claude), .notFound)

        try FileManager.default.createDirectory(atPath: claude.homeDir, withIntermediateDirectories: true)
        try #"{"theme": "dark"}"#.write(toFile: claude.configPath, atomically: true, encoding: .utf8)
        XCTAssertEqual(Installer.state(of: claude), .notInstalled)

        try Installer.install(claude, binary: bin)
        XCTAssertEqual(Installer.state(of: claude), .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: claude.configPath + ".rollcage-backup"))
        let saved = try XCTUnwrap(Installer.parse(XCTUnwrap(FileManager.default.contents(atPath: claude.configPath))))
        XCTAssertEqual(saved["theme"] as? String, "dark")

        try Installer.uninstall(claude)
        XCTAssertEqual(Installer.state(of: claude), .notInstalled)
    }
}
