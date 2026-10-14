import XCTest
@testable import RollcageGuardCore

/// The leak guard runs git in a real repository, so these tests make throwaway ones.
/// Fake keys are assembled at run time so this file never contains anything that looks like a credential.
final class GitLeakTests: XCTestCase {
    var repo = ""
    let config = GuardConfig()

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("rg-repo-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "feature")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: repo)
    }

    @discardableResult
    func git(_ args: String...) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    func write(_ name: String, _ text: String) throws {
        try text.write(toFile: repo + "/" + name, atomically: true, encoding: .utf8)
    }

    func verdict(_ command: String) -> GuardVerdict? {
        GuardEngine.evaluate(ToolCall(agent: "test", toolName: "Bash", shellCommands: [command], cwd: repo), config: config)
    }

    func testStagedKeyBlocksCommit() throws {
        let key = "AKIA" + "Q7ZK3M9XWB2TR4NP"
        try write("config.js", "export const awsKey = '\(key)'\n")
        try git("add", "config.js")
        let v = verdict("git commit -m 'add config'")
        XCTAssertEqual(v?.action, .block)
        XCTAssertEqual(v?.kind, .leak)
        XCTAssertFalse(v?.reason.contains(key) ?? true, "the key itself must never be repeated back")
    }

    func testAddAllThenCommitCatchesUntrackedEnvFile() throws {
        try write("README.md", "hello\n")
        try git("add", "README.md")
        try git("commit", "-q", "-m", "init")
        try write(".env", "DATABASE_URL=postgres://localhost/dev\n")
        XCTAssertEqual(verdict("git add -A && git commit -m wip")?.action, .block)
    }

    func testCleanCommitIsAllowed() throws {
        try write("index.js", "console.log('hi')\n")
        try git("add", "index.js")
        XCTAssertNil(verdict("git commit -m 'hello'"))
    }

    func testPlaceholderKeysAreNotLeaks() throws {
        try write("README.md", "Set OPENAI_API_KEY=sk-your-key-here and AWS key " + "AKIA" + "IOSFODNN7EXAMPLE\n")
        try git("add", "README.md")
        XCTAssertNil(verdict("git commit -m docs"))
    }

    func testPushToProtectedBranchAsks() throws {
        XCTAssertEqual(verdict("git push origin main")?.action, .ask)
        XCTAssertEqual(verdict("git push origin HEAD:production")?.action, .ask)
        XCTAssertNil(verdict("git push origin feature"))
    }
}
