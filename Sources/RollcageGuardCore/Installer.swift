import Foundation

// MARK: - Adding the hook to each agent's config

public struct AgentTarget: Equatable {
    public let id: String
    public let name: String
    /// The config file the hook goes into.
    public let configPath: String
    /// The agent's own folder; if it doesn't exist the agent isn't installed.
    public var homeDir: String { (configPath as NSString).deletingLastPathComponent }
    /// Printed after a successful install.
    public let note: String?
}

public enum Installer {
    public enum State: Equatable {
        case notFound
        case notInstalled
        case installed
        /// The Rollcage Mac app's own guard hook is there, which already does everything this one does.
        case managedByApp
    }

    public struct EditError: LocalizedError {
        public let errorDescription: String?
    }

    public static func targets(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [AgentTarget] {
        [
            AgentTarget(id: "claude", name: "Claude Code", configPath: "\(home)/.claude/settings.json", note: nil),
            AgentTarget(id: "codex", name: "Codex CLI", configPath: "\(home)/.codex/hooks.json",
                        note: "approve it once with /hooks in Codex"),
            AgentTarget(id: "cursor", name: "Cursor", configPath: "\(home)/.cursor/hooks.json", note: nil),
            AgentTarget(id: "gemini", name: "Gemini CLI", configPath: "\(home)/.gemini/settings.json", note: nil),
        ]
    }

    // MARK: Telling hooks apart

    static let marker = "rollcage-guard"
    /// Hooks the Rollcage app installs run its helper from Application Support (or the older Backstop name).
    static let appMarkers = ["/Application Support/Rollcage/bin/", "backstop-guard"]

    public static func isAppHook(_ command: String) -> Bool {
        appMarkers.contains { command.contains($0) }
    }

    public static func isOurHook(_ command: String) -> Bool {
        command.contains(marker) && !isAppHook(command)
    }

    /// Every hook command in an agent config, in both layouts: matcher groups (Claude Code, Codex, Gemini)
    /// and plain command lists (Cursor).
    static func hookCommands(in root: [String: Any]) -> [String] {
        guard let hooks = root["hooks"] as? [String: Any] else { return [] }
        var out: [String] = []
        for value in hooks.values {
            for entry in value as? [[String: Any]] ?? [] {
                if let c = entry["command"] as? String { out.append(c) }
                for inner in entry["hooks"] as? [[String: Any]] ?? [] {
                    if let c = inner["command"] as? String { out.append(c) }
                }
            }
        }
        return out
    }

    public static func state(of target: AgentTarget) -> State {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.homeDir) else { return .notFound }
        guard let data = fm.contents(atPath: target.configPath), let root = parse(data) else { return .notInstalled }
        let commands = hookCommands(in: root)
        if commands.contains(where: isAppHook) { return .managedByApp }
        return commands.contains(where: isOurHook) ? .installed : .notInstalled
    }

    // MARK: Editing the config

    public static func command(binary: String, agent: String, event: String? = nil) -> String {
        var c = "\"\(binary)\" --agent \(agent)"
        if let event { c += " --event \(event)" }
        return c
    }

    /// Adds the guard's hook for `agent` to a parsed config, replacing any earlier copy of it.
    public static func addHook(agent: String, binary: String, to root: inout [String: Any]) throws {
        removeHook(from: &root)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        func appendGroup(_ event: String, matcher: String, hook: [String: Any]) {
            var list = hooks[event] as? [[String: Any]] ?? []
            list.append(["matcher": matcher, "hooks": [hook]])
            hooks[event] = list
        }
        let cmd = command(binary: binary, agent: agent)
        switch agent {
        case "claude":
            appendGroup("PreToolUse", matcher: "*", hook: ["type": "command", "command": cmd, "timeout": 15])
        case "codex":
            appendGroup("PreToolUse", matcher: ".*",
                        hook: ["type": "command", "command": cmd, "timeout": 15, "statusMessage": "Rollcage guard"])
        case "cursor":
            if root["version"] == nil { root["version"] = 1 }
            for (event, arg) in [("beforeShellExecution", "shell"), ("beforeReadFile", "read"), ("beforeMCPExecution", "mcp")] {
                var list = hooks[event] as? [[String: Any]] ?? []
                list.append(["command": command(binary: binary, agent: agent, event: arg)])
                hooks[event] = list
            }
        case "gemini":
            appendGroup("BeforeTool", matcher: ".*",
                        hook: ["type": "command", "command": cmd, "name": "rollcage-guard", "timeout": 15000])
        default:
            throw EditError(errorDescription: "Unknown agent \(agent). Use one of: \(Hook.agents.joined(separator: ", ")).")
        }
        root["hooks"] = hooks
    }

    /// Removes this guard's hook entries and leaves everything else, including the Rollcage app's hooks, as it was.
    public static func removeHook(from root: inout [String: Any]) {
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let list = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = list.compactMap { entry in
                if let c = entry["command"] as? String, isOurHook(c) { return nil }   // Cursor style
                if var inner = entry["hooks"] as? [[String: Any]] {                  // matcher-group style
                    inner.removeAll { ($0["command"] as? String).map(isOurHook) == true }
                    if inner.isEmpty { return nil }
                    var e = entry
                    e["hooks"] = inner
                    return e
                }
                return entry
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
    }

    public static func install(_ target: AgentTarget, binary: String) throws {
        try edit(target) { root in try addHook(agent: target.id, binary: binary, to: &root) }
    }

    public static func uninstall(_ target: AgentTarget) throws {
        guard FileManager.default.fileExists(atPath: target.configPath) else { return }
        try edit(target) { root in removeHook(from: &root) }
    }

    /// Loads the agent's JSON config, lets `body` change it, backs up the original once, and writes it back.
    static func edit(_ target: AgentTarget, _ body: (inout [String: Any]) throws -> Void) throws {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: target.configPath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: url.path), !data.isEmpty {
            guard let obj = parse(data) else {
                throw EditError(errorDescription: "\(target.configPath) isn't plain JSON, so it was left alone. Add the hook by hand (see the README).")
            }
            root = obj
            let backup = url.appendingPathExtension("rollcage-backup")
            if !fm.fileExists(atPath: backup.path) { try? data.write(to: backup) }
        }
        try body(&root)
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: url, options: .atomic)
    }

    static func parse(_ data: Data) -> [String: Any]? {
        #if canImport(Darwin)
        let options: JSONSerialization.ReadingOptions = [.json5Allowed]
        #else
        let options: JSONSerialization.ReadingOptions = []
        #endif
        return (try? JSONSerialization.jsonObject(with: data, options: options)) as? [String: Any]
    }
}
