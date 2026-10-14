import Foundation

// MARK: - Reading a hook call and answering it
//
// Each agent sends its hook a JSON object on stdin and reads the answer from stdout.
// Claude Code, Codex and Gemini CLI send `tool_name` and `tool_input`; Cursor has one hook
// per kind of call (shell, file read, MCP) with its own fields.

public enum Hook {
    /// The agents the guard can answer. `cursor` also needs the hook event.
    public static let agents = ["claude", "codex", "cursor", "gemini"]

    static let pathKeys: Set<String> = ["file_path", "path", "absolute_path", "notebook_path", "paths", "glob", "include",
                                        "file", "filename", "target_file", "dir_path", "source", "destination",
                                        "old_path", "new_path", "target", "files", "uri"]

    /// Turns the JSON an agent sent into the paths, commands and URLs the engine checks.
    public static func toolCall(agent: String, event: String, json: [String: Any]) -> ToolCall {
        var call = ToolCall(agent: agent, toolName: "", cwd: json["cwd"] as? String)

        if agent == "cursor" {
            switch event {
            case "shell":
                call.toolName = "shell"
                if let c = json["command"] as? String { call.shellCommands = [c] }
            case "read":
                call.toolName = "read"
                if let p = json["file_path"] as? String { call.paths.append(p) }
                if let atts = json["attachments"] as? [[String: Any]] {
                    call.paths += atts.compactMap { $0["file_path"] as? String }
                }
            default:
                call.toolName = (json["tool_name"] as? String) ?? "mcp"
                var toolInput = json["tool_input"]
                if let s = toolInput as? String, let d = s.data(using: .utf8) { toolInput = try? JSONSerialization.jsonObject(with: d) }
                if let toolInput {
                    collectPaths(toolInput, key: nil, into: &call.paths)
                    collectURLs(toolInput, into: &call.urls)
                }
            }
            if let roots = json["workspace_roots"] as? [String] { call.cwd = call.cwd ?? roots.first }
            return call
        }

        let toolName = (json["tool_name"] as? String) ?? ""
        let toolInput = (json["tool_input"] as? [String: Any]) ?? [:]
        call.toolName = toolName
        let lower = toolName.lowercased()
        if lower == "apply_patch" {
            for key in ["command", "patch", "input"] {
                if let s = toolInput[key] as? String { call.paths += patchPaths(s) }
                if let arr = toolInput[key] as? [String] { call.paths += arr.flatMap(patchPaths) }
            }
        } else {
            let isShell = ["bash", "shell", "exec_command", "terminal", "run_command"].contains { lower.contains($0) }
            if isShell {
                if let c = toolInput["command"] as? String { call.shellCommands.append(c) }
                if let arr = toolInput["command"] as? [String] { call.shellCommands.append(arr.joined(separator: " ")) }
            }
            collectPaths(toolInput, key: nil, into: &call.paths)
            if !isShell { collectURLs(toolInput, into: &call.urls) }
        }
        return call
    }

    static func collectPaths(_ value: Any, key: String?, into out: inout [String]) {
        if let s = value as? String {
            if let key, pathKeys.contains(key) { out.append(s) }
        } else if let arr = value as? [Any] {
            for v in arr { collectPaths(v, key: key, into: &out) }
        } else if let dict = value as? [String: Any] {
            for (k, v) in dict { collectPaths(v, key: k, into: &out) }
        }
    }

    /// URLs handed to fetch-style tools (WebFetch, browser and HTTP MCP tools…).
    static func collectURLs(_ value: Any, into out: inout [String]) {
        if let s = value as? String {
            if s.count < 4096, s.range(of: #"^\s*[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil { out.append(s) }
        } else if let arr = value as? [Any] {
            for v in arr { collectURLs(v, into: &out) }
        } else if let dict = value as? [String: Any] {
            for (_, v) in dict { collectURLs(v, into: &out) }
        }
    }

    /// Files named in a Codex `apply_patch` body.
    static func patchPaths(_ patch: String) -> [String] {
        patch.split(separator: "\n").compactMap { line in
            for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "] where line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
            }
            return nil
        }
    }

    /// Only Claude Code and Cursor's shell hook can stop and ask the user; the others get a hard block.
    public static func canAsk(agent: String, event: String) -> Bool {
        agent == "claude" || (agent == "cursor" && event == "shell")
    }

    /// The JSON to print for a verdict, in the format each agent expects. Nil means print nothing (allow).
    public static func response(agent: String, event: String, verdict: GuardVerdict?) -> [String: Any]? {
        guard let verdict else {
            return agent == "cursor" ? ["permission": "allow"] : nil
        }
        let action = verdict.action
        let userMessage = action == .block
            ? "Rollcage blocked \(agent): \(verdict.subject)"
            : "Rollcage: \(verdict.subject) needs your approval"
        switch agent {
        case "cursor":
            var out: [String: Any] = ["permission": action == .block ? "deny" : "ask", "user_message": userMessage]
            if event != "read" { out["agent_message"] = verdict.reason }
            return out
        case "gemini":
            return ["decision": "deny", "reason": verdict.reason]
        default: // claude, codex
            return ["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": action == .block ? "deny" : "ask",
                "permissionDecisionReason": verdict.reason,
            ]]
        }
    }

    /// Decides one hook call: evaluates it, downgrades "ask" to "block" where the agent can't ask,
    /// and logs anything that isn't allowed.
    public static func handle(agent: String, event: String, json: [String: Any], config: GuardConfig,
                              log: Bool = true) -> [String: Any]? {
        let call = toolCall(agent: agent, event: event, json: json)
        guard var verdict = GuardEngine.evaluate(call, config: config) else {
            return response(agent: agent, event: event, verdict: nil)
        }
        if verdict.action == .ask && !canAsk(agent: agent, event: event) { verdict.action = .block }
        if log {
            let detail = verdict.kind == .network
                ? (call.shellCommands.first ?? call.urls.first ?? call.toolName)
                : (call.shellCommands.first ?? call.paths.first ?? call.toolName)
            GuardLog.append(GuardEvent(agent: agent, verdict: verdict, detail: detail, cwd: call.cwd))
        }
        return response(agent: agent, event: event, verdict: verdict)
    }
}
