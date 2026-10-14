import Foundation

// MARK: - Leak and protected-branch checks for git commit / git push
//
// Before an agent commits or pushes, look at what would actually leave the machine:
// the staged changes (or everything tracked, for `commit -a` or `git add … && git commit`)
// and the commits a push would send. Block when they hold a key or a secret file, and
// ask before a push to a protected branch. Anything that goes wrong here allows the command.

extension GuardEngine {
    /// One `git` invocation inside a shell command, with the folder it runs in.
    struct GitStep {
        var dir: String
        var subcommand: String
        var args: [String]
    }

    public static func checkGit(_ command: String, cwd: String, config: GuardConfig) -> GuardVerdict? {
        guard config.leakGuardEnabled || config.protectedBranchesEnabled else { return nil }
        let steps = gitSteps(in: command, cwd: cwd)
        guard steps.contains(where: { $0.subcommand == "commit" || $0.subcommand == "push" }) else { return nil }

        var ask: GuardVerdict?
        var addedBefore: [String: [String]] = [:]     // dir -> paths given to `git add` earlier in the command
        for step in steps {
            switch step.subcommand {
            case "add":
                addedBefore[step.dir, default: []] += step.args.filter { !$0.hasPrefix("-") || $0 == "-A" || $0 == "--all" }
            case "commit":
                if config.leakGuardEnabled, let v = leakInCommit(step, staging: addedBefore[step.dir], config: config) { return v }
            case "push":
                // A commit earlier in the same command was checked above; this covers the ones already made.
                if config.leakGuardEnabled, let v = leakInPush(step, config: config) { return v }
                if config.protectedBranchesEnabled, ask == nil { ask = protectedPush(step, config: config) }
            default:
                break
            }
        }
        return ask
    }

    // MARK: Parsing

    /// The git commands in `command`, following `cd dir &&` and `git -C dir`.
    static func gitSteps(in command: String, cwd: String) -> [GitStep] {
        var dir = cwd
        var steps: [GitStep] = []
        for words in segments(of: command) {
            let clean = words.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
            guard let program = clean.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            if program == "cd" {
                if clean.count > 1 { dir = resolve(clean[1], from: dir) }
                continue
            }
            guard program == "git" else { continue }
            var i = 1
            var here = dir
            // Global options come before the subcommand.
            while i < clean.count, clean[i].hasPrefix("-") {
                let opt = clean[i]
                if opt == "-C", i + 1 < clean.count {
                    here = resolve(clean[i + 1], from: here); i += 2
                } else if opt == "-c" || opt == "--git-dir" || opt == "--work-tree" || opt == "--namespace" {
                    i += 2
                } else {
                    i += 1
                }
            }
            guard i < clean.count else { continue }
            steps.append(GitStep(dir: here, subcommand: clean[i], args: Array(clean[(i + 1)...])))
        }
        return steps
    }

    static func resolve(_ path: String, from base: String) -> String {
        var p = path
        if p == "~" || p.hasPrefix("~/") {
            p = FileManager.default.homeDirectoryForCurrentUser.path + p.dropFirst()
        } else if p.hasPrefix("$HOME") {
            p = FileManager.default.homeDirectoryForCurrentUser.path + p.dropFirst(5)
        }
        let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : URL(fileURLWithPath: base).appendingPathComponent(p)
        return url.standardizedFileURL.path
    }

    // MARK: Commit

    static func leakInCommit(_ step: GitStep, staging: [String]?, config: GuardConfig) -> GuardVerdict? {
        if step.args.contains("--dry-run") { return nil }
        let all = step.args.contains { $0 == "-a" || $0 == "--all" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("a")) }
        var files: [String] = []
        var diff = ""
        let hasHead = !gitLines(["rev-parse", "--verify", "-q", "HEAD"], in: step.dir).isEmpty
        if (staging == nil && !all) || !hasHead {
            // What is staged right now is what gets committed.
            files = gitLines(["diff", "--cached", "--name-only", "--diff-filter=ACMR"], in: step.dir)
            diff = git(["diff", "--cached", "--no-color", "--no-ext-diff", "-U0", "--diff-filter=ACMR"], in: step.dir) ?? ""
        }
        if staging != nil || all, hasHead {
            // `git add … && git commit` or `commit -a`: the staging hasn't happened yet, so look at
            // every tracked change, plus the new files `git add` is about to pick up.
            files = gitLines(["diff", "HEAD", "--name-only", "--diff-filter=ACMR"], in: step.dir)
            diff = git(["diff", "HEAD", "--no-color", "--no-ext-diff", "-U0", "--diff-filter=ACMR"], in: step.dir) ?? ""
        }
        if let staging, !staging.isEmpty {
            let everything = staging.contains { ["-A", "--all", ".", "*", ":/"].contains($0) }
            for path in gitLines(["ls-files", "--others", "--exclude-standard"], in: step.dir)
            where everything || staging.contains(where: { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) {
                files.append(path)
                diff += newFileAsDiff(path, in: step.dir)
            }
        }
        return leakVerdict(files: files, diff: diff, action: "commit", config: config)
    }

    // MARK: Push

    static func leakInPush(_ step: GitStep, config: GuardConfig) -> GuardVerdict? {
        if step.args.contains("--dry-run") || step.args.contains("-n") || step.args.contains("--delete") || step.args.contains("-d") {
            return nil
        }
        // Commits this push would send: those on the pushed branches that no remote has yet.
        let refspecs = positionalArgs(step.args).dropFirst()     // the first is the remote
        var sources = refspecs.compactMap { spec -> String? in
            let s = spec.hasPrefix("+") ? String(spec.dropFirst()) : spec
            let src = s.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? s
            return src.isEmpty ? nil : src
        }
        if step.args.contains("--all") || step.args.contains("--mirror") { sources = ["--branches"] }
        if refspecs.isEmpty { sources = ["HEAD"] }
        guard !sources.isEmpty else { return nil }
        let range = sources + ["--not", "--remotes"]
        let files = gitLines(["log", "--format=", "--name-only", "--diff-filter=ACMR", "-n", "200"] + range, in: step.dir)
        let diff = git(["log", "--format=", "--no-color", "--no-ext-diff", "-p", "-U0", "--diff-filter=ACMR", "-n", "200"] + range,
                       in: step.dir) ?? ""
        return leakVerdict(files: files, diff: diff, action: "push", config: config)
    }

    static func protectedPush(_ step: GitStep, config: GuardConfig) -> GuardVerdict? {
        let args = step.args
        if args.contains("--dry-run") || args.contains("-n") { return nil }
        let protected = Set(config.protectedBranches.map { $0.lowercased() })
        guard !protected.isEmpty else { return nil }

        var targets: [String] = []
        if args.contains("--all") || args.contains("--mirror") {
            targets = gitLines(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: step.dir)
        } else {
            let refspecs = positionalArgs(args).dropFirst()     // the first is the remote
            if refspecs.isEmpty {
                // Plain `git push` sends the current branch.
                if let current = gitLines(["rev-parse", "--abbrev-ref", "HEAD"], in: step.dir).first { targets.append(current) }
            } else {
                for spec in refspecs {
                    var dst = spec.hasPrefix("+") ? String(spec.dropFirst()) : spec
                    if let colon = dst.lastIndex(of: ":") { dst = String(dst[dst.index(after: colon)...]) }
                    if dst == "HEAD" || dst.isEmpty {
                        dst = gitLines(["rev-parse", "--abbrev-ref", "HEAD"], in: step.dir).first ?? dst
                    }
                    if dst.hasPrefix("refs/heads/") { dst = String(dst.dropFirst("refs/heads/".count)) }
                    targets.append(dst)
                }
            }
        }
        guard let hit = targets.first(where: { protected.contains($0.lowercased()) }) else { return nil }
        return GuardVerdict(action: .ask, kind: .command, subject: "git push to \(hit)",
                            reason: "Rollcage: pushing to \(hit) needs the user's approval. " +
                            "If they'd rather review first, push to a new branch and open a pull request.")
    }

    /// `git push` arguments that aren't options: the remote, then the refspecs.
    static func positionalArgs(_ args: [String]) -> [String] {
        var positional: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if ["-o", "--push-option", "--repo", "--receive-pack", "--exec"].contains(a) { i += 2; continue }
            if !a.hasPrefix("-") { positional.append(a) }
            i += 1
        }
        return positional
    }

    // MARK: Verdict

    static func leakVerdict(files: [String], diff: String, action: String, config: GuardConfig) -> GuardVerdict? {
        // Secret files themselves, such as .env or a private key.
        if let file = files.first(where: { secretMatch($0, config: config) != nil }) {
            return GuardVerdict(action: .block, kind: .leak, subject: "\((file as NSString).lastPathComponent) in \(action)",
                                reason: "Rollcage blocked this \(action): it would send \(file), which holds secrets, to the repository. " +
                                "Unstage it (git restore --staged \(file)), add it to .gitignore, and try again." +
                                (action == "push" ? " It's in a commit already, so remove it from that commit first." : ""))
        }
        // Keys inside the changes. Only added lines count.
        var currentFile = ""
        var added: [String: String] = [:]
        var order: [String] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++ ") {
                currentFile = line.hasPrefix("+++ b/") ? String(line.dropFirst(6)) : String(line.dropFirst(4))
                continue
            }
            guard line.hasPrefix("+"), line.count < 20_000 else { continue }
            if added[currentFile] == nil { order.append(currentFile) }
            added[currentFile, default: ""] += line.dropFirst() + "\n"
        }
        for file in order {
            guard let text = added[file], let kind = SecretRule.certainKinds(in: text).first else { continue }
            return GuardVerdict(action: .block, kind: .leak, subject: "\(kind) in \(action)",
                                reason: "Rollcage blocked this \(action): \(file) contains what looks like a real \(kind). " +
                                "Don't print it. Remove it from the file and read it from an environment variable or a secrets manager instead" +
                                (action == "push" ? ", then remove it from the commit that added it (amend or rewrite that commit)" : "") +
                                ". Tell the user, because a key that reached a commit should be rotated.")
        }
        return nil
    }

    // MARK: Running git

    /// A new, untracked file shown the way `git diff` shows an added file.
    static func newFileAsDiff(_ path: String, in dir: String) -> String {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(path)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 1_000_000,
              let data = try? Data(contentsOf: url), !data.prefix(4096).contains(0) else { return "" }
        let body = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .map { "+" + $0 }.joined(separator: "\n")
        return "+++ b/\(path)\n\(body)\n"
    }

    static func gitLines(_ args: [String], in dir: String) -> [String] {
        (git(args, in: dir) ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Output of `git args` in `dir`, or nil if git fails or takes too long.
    static func git(_ args: [String], in dir: String, timeout: TimeInterval = 4, maxBytes: Int = 6_000_000) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-c", "core.quotepath=off"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"     // never take the index lock the agent's own git is about to need
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env["LC_ALL"] = "C"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        let collected = Collected()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = out.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                collected.append(chunk, limit: maxBytes)   // keep draining past the limit so git never blocks
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: collected.data, as: UTF8.self)
    }

    public final class Collected: @unchecked Sendable {
        public init() {}
        private let lock = NSLock()
        public private(set) var data = Data()
        public func append(_ chunk: Data, limit: Int) {
            lock.lock(); defer { lock.unlock() }
            if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
        }
    }
}
