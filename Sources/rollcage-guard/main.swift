// rollcage-guard: a pre-tool-use hook that keeps AI coding agents away from secrets and destructive commands.
//
// Any internal error allows the call, so a broken guard never bricks an agent.

import Foundation
import RollcageGuardCore

let version = "1.0.0"

let usage = """
rollcage-guard \(version): blocks AI coding agents from reading secrets, leaking keys and running destructive commands.

Usage:
  rollcage-guard install [AGENT...] [--bin PATH]   Add the hook to Claude Code, Codex, Cursor and Gemini CLI
                                                   (every agent found, or only the ones named)
  rollcage-guard uninstall [AGENT...]              Remove the hook (from every agent, or the ones named)
  rollcage-guard status                            Which agents are guarded, and where the rules and log are
  rollcage-guard explain "COMMAND" [--cwd DIR]     What the guard would do with a shell command
  rollcage-guard log [-n COUNT]                    Recent blocks and approvals asked (default 20)
  rollcage-guard config [--init]                   Where the rules are; --init writes the defaults there to edit
  rollcage-guard --agent AGENT [--event EVENT]     Hook mode: reads the agent's JSON on stdin (what the hooks run)
  rollcage-guard --version

Agents: claude, codex, cursor, gemini

Snapshots and one-click undo when an agent breaks something anyway: https://rollcage.app
"""

let home = FileManager.default.homeDirectoryForCurrentUser.path

func tilde(_ path: String) -> String {
    path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
}

var args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

// MARK: - Hook mode

if args.contains("--agent") {
    let agent = option("--agent") ?? "claude"
    let event = option("--event") ?? ""
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
    if let out = Hook.handle(agent: agent, event: event, json: json, config: GuardConfig.load()),
       let data = try? JSONSerialization.data(withJSONObject: out),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    exit(0)
}

// MARK: - Commands

/// The path hooks should run: this binary, unless --bin says otherwise.
func binaryPath() -> String {
    if let custom = option("--bin") {
        return URL(fileURLWithPath: custom).standardizedFileURL.path
    }
    let path = Bundle.main.executableURL?.resolvingSymlinksInPath().path
        ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    // Homebrew keeps each version in its own Cellar folder; the hooks should run the link that survives upgrades.
    if let r = path.range(of: #"/Cellar/rollcage-guard/[^/]+/bin/rollcage-guard$"#, options: .regularExpression) {
        let stable = String(path[..<r.lowerBound]) + "/bin/rollcage-guard"
        if FileManager.default.isExecutableFile(atPath: stable) { return stable }
    }
    return path
}

func selectedTargets(_ names: [String]) -> [AgentTarget] {
    let all = Installer.targets()
    guard !names.isEmpty, !names.contains("all") else { return all }
    return names.map { name in
        guard let t = all.first(where: { $0.id == name.lowercased() }) else {
            fail("Unknown agent \(name). Use one of: \(Hook.agents.joined(separator: ", ")).")
        }
        return t
    }
}

func install() {
    let binary = binaryPath()
    let named = args.dropFirst()
    let targets = selectedTargets(Array(named))
    if binary.contains("/.build/") {
        print("Note: hooks will run \(tilde(binary)), inside a build folder. If you clean or move it, the hooks break.")
        print("      Copy the binary somewhere permanent (e.g. /usr/local/bin) and run install from there.\n")
    }
    var added = 0
    for t in targets {
        switch Installer.state(of: t) {
        case .notFound:
            if !named.isEmpty { print("\(pad(t.name, 13)) not found (no \(tilde(t.homeDir)))") }
            continue
        case .managedByApp:
            print("\(pad(t.name, 13)) skipped: the Rollcage app's guard is already installed there")
            continue
        case .installed, .notInstalled:
            break
        }
        do {
            try Installer.install(t, binary: binary)
            added += 1
            print("\(pad(t.name, 13)) hook added to \(tilde(t.configPath))" + (t.note.map { " (\($0))" } ?? ""))
        } catch {
            print("\(pad(t.name, 13)) \(error.localizedDescription)")
        }
    }
    if added == 0 {
        print(named.isEmpty ? "No agents found. Install Claude Code, Codex, Cursor or Gemini CLI first." : "Nothing installed.")
        exit(1)
    }
    print("\nRestart running agents so they load the hook. Try it: rollcage-guard explain \"cat .env\"")
}

func uninstall() {
    for t in selectedTargets(Array(args.dropFirst())) where Installer.state(of: t) == .installed {
        do {
            try Installer.uninstall(t)
            print("\(pad(t.name, 13)) hook removed from \(tilde(t.configPath))")
        } catch {
            print("\(pad(t.name, 13)) \(error.localizedDescription)")
        }
    }
}

func status() {
    print("rollcage-guard \(version) at \(tilde(binaryPath()))\n")
    for t in Installer.targets() {
        let label: String
        switch Installer.state(of: t) {
        case .notFound: label = "not found"
        case .notInstalled: label = "not guarded"
        case .installed: label = "guarded"
        case .managedByApp: label = "guarded by the Rollcage app"
        }
        print("  \(pad(t.name, 13)) \(pad(label, 28)) \(tilde(t.configPath))")
    }
    let config = GuardPaths.configFile.path
    let hasConfig = FileManager.default.fileExists(atPath: config)
    print("\nRules: \(tilde(config))" + (hasConfig ? "" : " (not written yet, so the defaults apply; `rollcage-guard config --init` writes them)"))
    let (events, _) = GuardLog.read(from: 0)
    print("Log:   \(tilde(GuardPaths.logFile.path)) (\(events.count) entries)")
    if !GuardConfig.load().enabled { print("\nThe guard is switched off: \"enabled\" is false in the rules file.") }
}

func explain() {
    let cwd = option("--cwd") ?? FileManager.default.currentDirectoryPath
    guard args.count >= 2 else { fail("Usage: rollcage-guard explain \"COMMAND\" [--cwd DIR]") }
    let command = args.dropFirst().joined(separator: " ")
    var config = GuardConfig.load()
    config.enabled = true
    let call = ToolCall(agent: "test", toolName: "Bash", shellCommands: [command], cwd: cwd)
    if let v = GuardEngine.evaluate(call, config: config) {
        print("\(v.action.rawValue): \(v.subject)\n\(v.reason)")
    } else {
        print("allow")
    }
}

func showLog() {
    let count = Int(option("-n") ?? "20") ?? 20
    let (events, _) = GuardLog.read(from: 0)
    guard !events.isEmpty else { print("Nothing blocked yet."); return }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    for e in events.suffix(count) {
        let place = e.cwd.map { "  (\(tilde($0)))" } ?? ""
        print("\(f.string(from: e.date))  \(pad(e.agent, 7))\(pad(e.action.rawValue, 6))\(e.subject): \(e.detail)\(place)")
    }
}

func config() {
    let url = GuardPaths.configFile
    if args.contains("--init") {
        if FileManager.default.fileExists(atPath: url.path) {
            print("\(tilde(url.path)) already exists. Delete it first to start again from the defaults.")
            return
        }
        GuardConfig.load().save()
        print("Wrote the default rules to \(tilde(url.path)). Edit it; the hook reads it on every call.")
    } else {
        print(tilde(url.path) + (FileManager.default.fileExists(atPath: url.path) ? "" : " (not written yet, so the defaults apply)"))
    }
}

switch args.first {
case "install": install()
case "uninstall": uninstall()
case "status": status()
case "explain", "--explain": explain()
case "log": showLog()
case "config": config()
case "--version", "-v", "version": print("rollcage-guard \(version)")
case "--help", "-h", "help", nil: print(usage)
default: fail("Unknown command \(args.first!).\n\n\(usage)")
}
