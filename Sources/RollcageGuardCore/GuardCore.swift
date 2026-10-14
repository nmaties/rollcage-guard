import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Locations

public enum GuardPaths {
    /// Where the rules and the log live. On macOS it's the same folder the Rollcage app uses,
    /// so the app picks up your rules and shows past blocks if you install it later.
    public static var supportDir: URL {
        if let custom = ProcessInfo.processInfo.environment["ROLLCAGE_GUARD_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Rollcage", isDirectory: true)
        #else
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? ""
        let base = xdg.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
            : URL(fileURLWithPath: xdg, isDirectory: true)
        return base.appendingPathComponent("rollcage", isDirectory: true)
        #endif
    }

    public static var configFile: URL { supportDir.appendingPathComponent("guard.json") }
    public static var logFile: URL { supportDir.appendingPathComponent("guard-log.jsonl") }
}

// MARK: - Configuration

public enum GuardAction: String, Codable, CaseIterable {
    case block, ask
}

public struct CommandRule: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var detail: String
    public var pattern: String
    public var action: GuardAction
    public var enabled: Bool

    public init(id: String, name: String, detail: String, pattern: String, action: GuardAction, enabled: Bool = true) {
        self.id = id; self.name = name; self.detail = detail
        self.pattern = pattern; self.action = action; self.enabled = enabled
    }

    public static let defaults: [CommandRule] = [
        CommandRule(id: "rm-broad", name: "Recursive delete of /, ~, .., . or *",
                    detail: "rm -rf ~   rm -rf .   rm -rf *",
                    pattern: #"\brm\b(?=[^;&|\n]*\s-[a-zA-Z]*[rR])[^;&|\n]*\s(?:/|~|~/|\$HOME/?|\.\./?|\.|\./|\*|\./\*|/\*|~/\*)(?=\s|$|[;&|])"#,
                    action: .block),
        CommandRule(id: "git-reset-hard", name: "git reset --hard",
                    detail: "Throws away all uncommitted changes",
                    pattern: #"\bgit\b[^;&|\n]*\breset\b[^;&|\n]*--hard\b"#, action: .ask),
        CommandRule(id: "git-clean", name: "git clean -f",
                    detail: "Deletes every untracked file (new work, .env, local configs)",
                    pattern: #"\bgit\b[^;&|\n]*\bclean\b[^;&|\n]*\s-[a-zA-Z]*f"#, action: .block),
        CommandRule(id: "git-discard", name: "Discard uncommitted work",
                    detail: "git checkout .   git restore .   git stash drop/clear",
                    pattern: #"\bgit\b[^;&|\n]*\b(?:checkout\s+(?:--\s+)?\.|restore\s+(?:-\S+\s+)*\.|stash\s+(?:drop|clear))(?=\s|$|[;&|])"#,
                    action: .ask),
        CommandRule(id: "git-force-push", name: "Force push",
                    detail: "git push --force / -f / +branch",
                    pattern: #"\bgit\b[^;&|\n]*\bpush\b[^;&|\n]*(?:\s--force(?!-with-lease)\b|\s-f\b|\s\+\S+)"#,
                    action: .ask),
        CommandRule(id: "db-destroy", name: "Drop or wipe a database",
                    detail: "DROP DATABASE/TABLE, TRUNCATE, prisma migrate reset, rails db:drop, migrate:fresh…",
                    pattern: #"\bdrop\s+(?:database|schema|table)\b|\btruncate\s+table\b|\bdropdb\b|\bprisma\s+(?:migrate\s+reset|db\s+push\b[^;&|\n]*--force-reset)|\b(?:rails|rake)\s+db:(?:drop|reset|purge)\b|\bartisan\s+(?:migrate:fresh|migrate:reset|db:wipe)\b|\bmanage\.py\s+flush\b"#,
                    action: .block),
        CommandRule(id: "pipe-to-shell", name: "Pipe a download into a shell",
                    detail: "curl … | sh",
                    pattern: #"\b(?:curl|wget)\b[^;&\n]*\|\s*(?:sudo\s+)?(?:ba|z|da|fi)?sh\b"#, action: .ask),
        CommandRule(id: "disk", name: "Erase disks",
                    detail: "mkfs, diskutil erase…, dd of=/dev/…",
                    pattern: #"\bmkfs(?:\.\w+)?\b|\bdiskutil\s+(?:erase\w*|partitionDisk|zeroDisk|secureErase)\b|\bdd\b[^;&|\n]*\bof=/dev/"#,
                    action: .block),
        CommandRule(id: "chmod-broad", name: "Recursive chmod/chown on / or ~",
                    detail: "chmod -R 777 ~",
                    pattern: #"\b(?:chmod|chown)\s+-R\b[^;&|\n]*\s(?:/|~|~/|\$HOME/?)(?=\s|$|[;&|])"#, action: .block),
        CommandRule(id: "sudo", name: "sudo",
                    detail: "Anything run as root",
                    pattern: #"(?:^|[;&|(]\s*)sudo\b"#, action: .ask),
        CommandRule(id: "deploy", name: "Deploy, publish or destroy infrastructure",
                    detail: "terraform destroy, kubectl delete, npm publish, vercel --prod…",
                    pattern: #"\bterraform\s+(?:destroy\b|apply\b[^;&|\n]*-auto-approve)|\bkubectl\s+delete\b|\bnpm\s+publish\b|\bvercel\b[^;&|\n]*--prod\b|\bfirebase\s+deploy\b|\bfly\s+deploy\b"#,
                    action: .ask),
        CommandRule(id: "cloud-delete", name: "Delete cloud resources",
                    detail: "aws … delete-*, gcloud … delete, az … delete, fly destroy, heroku apps:destroy, supabase db reset, gh repo delete…",
                    pattern: #"\baws\s+[a-z0-9-]+\s+(?:delete|terminate|remove|deregister|purge)-[a-z0-9-]+|\baws\s+s3\s+(?:rb|rm)\b|\bgcloud\b[^;&|\n]*\s(?:delete|reset)\b|\bgsutil\b[^;&|\n]*\s(?:rm|rb)\b|\baz\s[^;&|\n]*\s(?:delete|purge)\b|\b(?:fly|flyctl)\s+(?:apps\s+destroy|destroy|volumes?\s+(?:destroy|delete)|machines?\s+(?:destroy|remove)|postgres\s+(?:destroy|delete))\b|\bheroku\s+(?:apps:destroy|pg:reset|addons:destroy)\b|\brailway\s+(?:down|delete|volume\s+delete)\b|\bvercel\s+(?:remove|rm|projects?\s+(?:rm|remove))\b|\bnetlify\s+sites:delete\b|\bsupabase\s+(?:db\s+reset|projects\s+delete|branches\s+delete)\b|\bneonctl\s+(?:projects|branches|databases|roles)\s+delete\b|\bdoctl\b[^;&|\n]*\s(?:delete|rm)\b|\bpscale\s+(?:database|branch|db)\s+delete\b|\bfirebase\s+(?:firestore:delete|database:remove|projects:delete|functions:delete|hosting:disable)\b|\bgh\s+(?:repo|release)\s+delete\b|\bhelm\s+(?:uninstall|delete)\b|\bwrangler\s+(?:delete|d1\s+delete|r2\s+bucket\s+delete|kv:namespace\s+delete|kv\s+namespace\s+delete)\b"#,
                    action: .ask),
        CommandRule(id: "api-delete", name: "DELETE request to a remote API",
                    detail: "curl -X DELETE https://…, GraphQL mutations that delete or destroy",
                    pattern: #"\b(?:curl|wget|xh|https?)\b(?=[^;&|\n]*(?:-X\s*|--request[=\s]+|--method[=\s]+)['"]?DELETE\b)(?![^;&|\n]*://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])[:/\s'"])[^;&|\n]*://|\b(?:xh|https?)\s+(?:-\S+\s+)*DELETE\s+(?!(?:https?://)?(?:localhost|127\.0\.0\.1|:\d))\S|\b(?:curl|wget|xh|https?)\b[^;&|\n]*graphql[^;&|\n]*?\b\w*(?:delete|destroy|drop|wipe|purge)\w*\s*\("#,
                    action: .ask),
        CommandRule(id: "remote-db", name: "Connect to a remote database",
                    detail: "psql, mysql, mongosh, prisma… with a database URL or host that isn't on this machine",
                    pattern: #"\b(?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|rediss?|sqlserver|cockroachdb)://(?:[^\s'"/@]+@)?(?![^\s'"/:@]*\.(?:local|internal|localhost|test|lan)(?:[:/\s'"?]|$))[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(?=[:/\s'"?]|$)|\b(?:psql|pg_restore|mysql|mariadb|mongosh|mongo|redis-cli)\b[^;&|\n]*\s(?:-h|--host)[=\s]*['"]?(?!(?:localhost|127\.0\.0\.1|0\.0\.0\.0)\b)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b"#,
                    action: .ask),
    ]
}

public struct GuardConfig: Codable, Equatable {
    /// Master switch.
    public var enabled = true
    public var secretsEnabled = true
    public var secretFilePatterns: [String] = GuardConfig.defaultSecretPatterns
    public var secretAllowPatterns: [String] = GuardConfig.defaultAllowPatterns
    public var blockEnvDumps = true
    public var blockInlineEnvCode = true
    public var commandsEnabled = true
    public var commandRules: [CommandRule] = CommandRule.defaults
    /// Network guard: check the hosts agents try to reach in tool calls.
    public var networkEnabled = true
    /// When on, anything that isn't on `allowedDomains` needs the user's approval.
    public var networkAllowlistOnly = false
    public var blockedDomains: [String] = GuardConfig.defaultBlockedDomains
    public var allowedDomains: [String] = GuardConfig.defaultAllowedDomains
    /// Leak guard: check what an agent is about to commit or push for keys and secret files.
    public var leakGuardEnabled = true
    /// Ask before an agent pushes to one of `protectedBranches`.
    public var protectedBranchesEnabled = true
    public var protectedBranches: [String] = ["main", "master", "production", "prod", "release"]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GuardConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        secretsEnabled = try c.decodeIfPresent(Bool.self, forKey: .secretsEnabled) ?? d.secretsEnabled
        secretFilePatterns = try c.decodeIfPresent([String].self, forKey: .secretFilePatterns) ?? d.secretFilePatterns
        secretAllowPatterns = try c.decodeIfPresent([String].self, forKey: .secretAllowPatterns) ?? d.secretAllowPatterns
        blockEnvDumps = try c.decodeIfPresent(Bool.self, forKey: .blockEnvDumps) ?? d.blockEnvDumps
        blockInlineEnvCode = try c.decodeIfPresent(Bool.self, forKey: .blockInlineEnvCode) ?? d.blockInlineEnvCode
        commandsEnabled = try c.decodeIfPresent(Bool.self, forKey: .commandsEnabled) ?? d.commandsEnabled
        var rules = try c.decodeIfPresent([CommandRule].self, forKey: .commandRules) ?? d.commandRules
        // Pick up rules added in newer versions.
        for rule in CommandRule.defaults where !rules.contains(where: { $0.id == rule.id }) { rules.append(rule) }
        commandRules = rules
        networkEnabled = try c.decodeIfPresent(Bool.self, forKey: .networkEnabled) ?? d.networkEnabled
        networkAllowlistOnly = try c.decodeIfPresent(Bool.self, forKey: .networkAllowlistOnly) ?? d.networkAllowlistOnly
        blockedDomains = try c.decodeIfPresent([String].self, forKey: .blockedDomains) ?? d.blockedDomains
        allowedDomains = try c.decodeIfPresent([String].self, forKey: .allowedDomains) ?? d.allowedDomains
        leakGuardEnabled = try c.decodeIfPresent(Bool.self, forKey: .leakGuardEnabled) ?? d.leakGuardEnabled
        protectedBranchesEnabled = try c.decodeIfPresent(Bool.self, forKey: .protectedBranchesEnabled) ?? d.protectedBranchesEnabled
        protectedBranches = try c.decodeIfPresent([String].self, forKey: .protectedBranches) ?? d.protectedBranches
    }

    /// Places that exist to receive pasted or tunnelled data: the usual way secrets and code leave a machine.
    public static let defaultBlockedDomains: [String] = [
        "pastebin.com", "paste.ee", "hastebin.com", "dpaste.com", "ix.io", "termbin.com", "0x0.st",
        "transfer.sh", "file.io", "bashupload.com", "webhook.site", "requestbin.com", "pipedream.net",
        "requestcatcher.com", "ngrok.io", "ngrok-free.app", "ngrok.app", "trycloudflare.com", "localtunnel.me",
        "serveo.net", "interact.sh", "oast.fun", "oast.pro", "burpcollaborator.net", "canarytokens.com",
    ]

    /// Starting point for "allowed domains only": the model providers, code hosts and package registries.
    public static let defaultAllowedDomains: [String] = [
        "anthropic.com", "claude.ai", "claude.com", "openai.com", "chatgpt.com", "googleapis.com", "google.com",
        "cursor.sh", "cursor.com", "github.com", "githubusercontent.com", "gitlab.com", "bitbucket.org",
        "npmjs.org", "npmjs.com", "yarnpkg.com", "pypi.org", "pythonhosted.org", "crates.io", "rubygems.org",
        "golang.org", "go.dev", "pkg.go.dev", "packagist.org", "maven.org", "nuget.org", "brew.sh",
        "docker.io", "docker.com", "ghcr.io", "nodejs.org", "python.org", "rust-lang.org", "swift.org",
        "apple.com", "mozilla.org", "stackoverflow.com", "wikipedia.org", "vercel.com", "stripe.com",
    ]

    /// Secret files across languages and frameworks. Patterns without "/" match the file name
    /// (case-insensitive globs); patterns with "/" match anywhere in the path.
    public static let defaultSecretPatterns: [String] = [
        // dotenv family (Node, Python, Ruby, PHP, Go, Rust, Deno, Bun, Docker…)
        ".env", ".env.*", "*.env", ".envrc", ".dev.vars", ".flaskenv",
        // package-manager & tool credentials
        ".npmrc", ".yarnrc.yml", ".pypirc", ".netrc", ".pgpass", ".my.cnf", ".git-credentials",
        ".gem/credentials", "/.composer/auth.json", "auth.json", "/.cargo/credentials", "/.cargo/credentials.toml",
        "/.m2/settings.xml", "/.nuget/NuGet.Config", "/.gradle/gradle.properties",
        // keys & certificates
        "*.pem", "*.key", "*.p12", "*.pfx", "*.jks", "*.keystore", "*.p8", "*.mobileprovision",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "*.ppk", "*.asc", "*.gpg",
        // framework secret stores
        "master.key", "credentials.yml.enc", "secrets.yml", "secrets.yaml", "secrets.json", "secrets.toml",
        "secret.json", "secrets.*.json", "appsettings.*.local.json", "local.settings.json", "wp-config.php",
        ".htpasswd", "credentials", "credentials.json", "client_secret*.json", "service-account*.json",
        "*serviceaccount*.json", "*-firebase-adminsdk-*.json", "*.tfvars", "*.tfstate", "*.tfstate.backup",
        "terraform.tfvars.json", "kubeconfig", ".vault-token",
        // home-directory credential folders
        "/.ssh/", "/.aws/", "/.gnupg/", "/.kube/config", "/.docker/config.json", "/.config/gh/hosts.yml",
        "/.config/gcloud/", "/.azure/", "/.password-store/", "/Library/Keychains/", "/.config/op/",
    ]

    public static let defaultAllowPatterns: [String] = [
        ".env.example", ".env.sample", ".env.template", ".env.dist", ".env.schema", ".env.defaults",
        "*.example", "*.sample", "*.template", "*.pub", "*.dist",
    ]

    public static func load() -> GuardConfig {
        guard let data = try? Data(contentsOf: GuardPaths.configFile),
              let config = try? JSONDecoder().decode(GuardConfig.self, from: data) else { return GuardConfig() }
        return config
    }

    public func save() {
        try? FileManager.default.createDirectory(at: GuardPaths.supportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: GuardPaths.configFile, options: .atomic) }
    }
}

// MARK: - Verdicts & log

public enum GuardKind: String, Codable {
    case secretFile = "secret-file"
    case envDump = "env-dump"
    case envCode = "env-code"
    case keychain
    case command
    case network
    /// A key or secret file in what an agent is about to commit or push.
    case leak
}

public struct GuardVerdict: Equatable {
    public var action: GuardAction
    public var kind: GuardKind
    /// Short human label, e.g. ".env" or "git reset --hard".
    public var subject: String
    /// Message shown to the agent.
    public var reason: String
}

public struct GuardEvent: Codable, Identifiable, Hashable {
    public var id: String
    public var date: Date
    public var agent: String
    public var action: GuardAction
    public var kind: GuardKind
    public var subject: String
    public var detail: String
    public var cwd: String?

    public init(agent: String, verdict: GuardVerdict, detail: String, cwd: String?) {
        id = UUID().uuidString
        date = Date()
        self.agent = agent
        action = verdict.action
        kind = verdict.kind
        subject = verdict.subject
        // Commands can carry keys and database passwords: never write those to the log.
        self.detail = String(SecretRule.masked(detail).prefix(400))
        self.cwd = cwd
    }
}

public enum GuardLog {
    public static func append(_ event: GuardEvent) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var line = try? enc.encode(event) else { return }
        line.append(0x0A)
        let url = GuardPaths.logFile
        try? FileManager.default.createDirectory(at: GuardPaths.supportDir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// Reads events appended after `offset`; returns them with the new offset.
    public static func read(from offset: UInt64) -> ([GuardEvent], UInt64) {
        guard let h = try? FileHandle(forReadingFrom: GuardPaths.logFile) else { return ([], 0) }
        defer { try? h.close() }
        let end = h.seekToEndOfFile()
        let start = offset > end ? 0 : offset   // file was truncated
        h.seek(toFileOffset: start)
        let data = h.readDataToEndOfFile()
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let events = data.split(separator: 0x0A).compactMap { try? dec.decode(GuardEvent.self, from: Data($0)) }
        return (events, end)
    }
}

// MARK: - Engine

public struct ToolCall {
    public var agent: String
    public var toolName: String
    public var shellCommands: [String]
    public var paths: [String]
    /// URLs passed to tools that fetch from the network.
    public var urls: [String]
    public var cwd: String?

    public init(agent: String, toolName: String, shellCommands: [String] = [], paths: [String] = [],
                urls: [String] = [], cwd: String? = nil) {
        self.agent = agent; self.toolName = toolName
        self.shellCommands = shellCommands; self.paths = paths; self.urls = urls; self.cwd = cwd
    }
}

public enum GuardEngine {
    public static func evaluate(_ call: ToolCall, config: GuardConfig) -> GuardVerdict? {
        guard config.enabled else { return nil }
        var best: GuardVerdict?
        func consider(_ v: GuardVerdict?) {
            guard let v else { return }
            if best == nil || (best!.action == .ask && v.action == .block) { best = v }
        }
        for p in call.paths { consider(checkPath(p, config: config)) }
        for c in call.shellCommands { consider(checkShell(c, config: config)) }
        // Commits and pushes are checked against the repository itself, so they need to know where it is.
        if best?.action != .block, let cwd = call.cwd {
            for c in call.shellCommands { consider(checkGit(c, cwd: cwd, config: config)) }
        }
        if config.networkEnabled {
            for u in call.urls { consider(host(fromURL: u).flatMap { checkHost($0, config: config) }) }
        }
        return best
    }

    // MARK: Files

    public static func checkPath(_ path: String, config: GuardConfig) -> GuardVerdict? {
        guard config.secretsEnabled, let name = secretMatch(path, config: config) else { return nil }
        return GuardVerdict(action: .block, kind: .secretFile, subject: name,
                            reason: secretReason(name))
    }

    static func secretReason(_ name: String) -> String {
        "Rollcage blocked access to \(name): it contains secrets the user hasn't shared with coding agents. " +
        "Don't try to read it another way. If you need a value, ask the user, or use .env.example for variable names."
    }

    /// Returns the file name that made `raw` a secret path, or nil.
    public static func secretMatch(_ raw: String, config: GuardConfig) -> String? {
        let path = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n'\"`"))
        guard !path.isEmpty, path.count < 1024 else { return nil }
        let base = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
        guard !base.isEmpty else { return nil }
        if config.secretAllowPatterns.contains(where: { glob($0, base) }) { return nil }

        let wrapped = "/" + path + "/"
        for pattern in config.secretFilePatterns {
            if pattern.contains("/") {
                if wrapped.range(of: pattern, options: .caseInsensitive) != nil { return base }
            } else if glob(pattern, base) {
                return base
            }
        }
        // The token itself is a glob, e.g. `cat .env*` or `source *.pem`.
        if base.contains(where: { "*?[".contains($0) }) {
            let literal = base.filter { !"*?[]".contains($0) }
            if literal.count >= 3 {
                for sample in [".env", ".env.local", ".env.production", "id_rsa", "secrets.json", "server.pem", "server.key", "credentials.json"]
                where glob(base, sample) && !config.secretAllowPatterns.contains(where: { glob($0, sample) }) {
                    return base
                }
            }
        }
        return nil
    }

    static func glob(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, caseFold) == 0
    }

    #if canImport(Darwin)
    private static let caseFold = FNM_CASEFOLD
    #else
    private static let caseFold: Int32 = 1 << 4   // glibc's FNM_CASEFOLD, a GNU extension Swift may not import
    #endif

    // MARK: Shell

    private static let separators = CharacterSet(charactersIn: " \t\n;|&<>()'\"`=,{}[]$")

    public static func checkShell(_ command: String, config: GuardConfig) -> GuardVerdict? {
        var verdict: GuardVerdict?
        if config.secretsEnabled {
            verdict = checkShellSecrets(command, config: config)
        }
        if verdict == nil, config.networkEnabled {
            verdict = checkShellNetwork(command, config: config)
        }
        // A blocked rule beats an "ask" from the network guard; otherwise the first finding stands.
        if verdict?.action != .block, config.commandsEnabled, let rule = checkCommandRules(command, config: config) {
            if verdict == nil || rule.action == .block { verdict = rule }
        }
        return verdict
    }

    // MARK: Network

    /// True when `host` is one of `domains` or a subdomain of one.
    public static func hostMatches(_ host: String, _ domains: [String]) -> Bool {
        let h = host.lowercased()
        return domains.contains { raw in
            let d = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .*"))
            return !d.isEmpty && (h == d || h.hasSuffix("." + d))
        }
    }

    /// This machine and private networks are never the guard's business.
    public static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".internal")
            || h == "::1" || h == "0.0.0.0" || !h.contains(".") && !h.contains(":") { return true }
        return matches(#"^(?:127\.|10\.|192\.168\.|169\.254\.|172\.(?:1[6-9]|2\d|3[01])\.)"#, h)
            || h.hasPrefix("fe80:") || h.hasPrefix("fd") && h.contains(":")
    }

    /// Host part of a URL, without user, port or brackets.
    public static func host(fromURL raw: String) -> String? {
        guard let m = firstCapture(#"^[A-Za-z][A-Za-z0-9+.-]*://(?:[^/@\s]*@)?(\[[0-9A-Fa-f:.]+\]|[^/:?#\s'"`\\]+)"#,
                                   raw.trimmingCharacters(in: .whitespaces), where: { _ in true }) else { return nil }
        return m.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }

    public static func checkHost(_ host: String, config: GuardConfig) -> GuardVerdict? {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !h.isEmpty, !isLocalHost(h) else { return nil }
        if hostMatches(h, config.blockedDomains) {
            return GuardVerdict(action: .block, kind: .network, subject: h,
                                reason: "Rollcage blocked a connection to \(h): the user doesn't let coding agents contact this site. " +
                                "Don't try to reach it another way or send the data somewhere else.")
        }
        if config.networkAllowlistOnly, !hostMatches(h, config.allowedDomains) {
            return GuardVerdict(action: .ask, kind: .network, subject: h,
                                reason: "Rollcage: \(h) isn't on the user's list of sites agents may contact. The user must approve it.")
        }
        return nil
    }

    private static let networkPrograms: Set<String> = [
        "curl", "wget", "http", "https", "xh", "nc", "ncat", "netcat", "socat", "telnet", "ssh", "scp", "sftp", "rsync",
        "ftp", "lftp", "aria2c", "openssl", "git", "open", "lynx", "w3m", "python", "python3", "node", "bun", "deno",
        "ruby", "php", "perl", "npx", "bunx", "uvx", "pipx", "osascript",
    ]
    private static let hostFirstPrograms: Set<String> = ["nc", "ncat", "netcat", "telnet", "ssh", "scp", "sftp", "ftp", "lftp"]

    /// Hosts a shell command would contact, as far as they can be read off the command line.
    static func checkShellNetwork(_ command: String, config: GuardConfig) -> GuardVerdict? {
        var hosts: [String] = []
        // 1. Anything written as a URL.
        if let re = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s'"`<>|;)\\]+"#) {
            let ns = command as NSString
            for m in re.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
                if let h = host(fromURL: ns.substring(with: m.range)) { hosts.append(h) }
            }
        }
        // 2. Tools whose arguments are hosts: `ssh user@host`, `nc host 443`, `scp file host:path`.
        let allSegments = segments(of: command)
        for words in allSegments {
            guard let program = words.first.map({ ($0 as NSString).lastPathComponent }), hostFirstPrograms.contains(program) else { continue }
            for arg in words.dropFirst() where !arg.hasPrefix("-") {
                let stripped = arg.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                let afterUser = stripped.split(separator: "@").last.map(String.init) ?? stripped
                let name = afterUser.split(separator: ":").first.map(String.init) ?? afterUser
                if matches(#"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, name) { hosts.append(name.lowercased()) }
            }
        }
        // 3. A blocked domain named without a scheme (`curl pastebin.com/raw/x`) in a command that can use the network.
        let usesNetwork = allSegments.contains { words in
            guard let first = words.first.map({ ($0 as NSString).lastPathComponent }) else { return false }
            return networkPrograms.contains(first) || networkPrograms.contains(String(first.prefix { !$0.isNumber && $0 != "." }))
        }
        if usesNetwork {
            let pieces = command.components(separatedBy: CharacterSet(charactersIn: " \t\n;|&<>()'\"`=,{}[]$/:@\\"))
            for piece in pieces where piece.contains(".") && hostMatches(piece, config.blockedDomains) {
                hosts.append(piece.lowercased())
            }
        }

        var best: GuardVerdict?
        for h in hosts {
            guard let v = checkHost(h, config: config) else { continue }
            if v.action == .block { return v }
            if best == nil { best = v }
        }
        return best
    }

    static func checkShellSecrets(_ command: String, config: GuardConfig) -> GuardVerdict? {
        // 1. Secret files mentioned anywhere in the command (cat, source, cp, python open(...), docker --env-file…)
        //    Writing ".env" into an ignore file is fine.
        let writesIgnoreFile = matches(#">>?\s*['"]?[^\s'";&|]*ignore['"]?(?=\s|$|[;&|])"#, command)
        if !writesIgnoreFile {
            for token in command.components(separatedBy: separators) where !token.isEmpty {
                if token.hasPrefix("-") { continue }
                if let name = secretMatch(token, config: config) {
                    return GuardVerdict(action: .block, kind: .secretFile, subject: name, reason: secretReason(name))
                }
            }
        }

        // 2. Commands that dump the environment or the keychain.
        if config.blockEnvDumps {
            for segment in segments(of: command) {
                if let v = checkDumpSegment(segment) { return v }
            }
        }

        // 3. Inline code in any language that reads environment variables.
        if config.blockInlineEnvCode,
           matches(inlineInterpreter, command),
           let api = firstMatch(envAPI, command) {
            return GuardVerdict(action: .block, kind: .envCode, subject: api,
                                reason: "Rollcage blocked inline code that reads environment variables (\(api)). " +
                                "Environment variables may hold the user's secrets. Ask the user for the specific non-secret value you need.")
        }
        return nil
    }

    static func checkCommandRules(_ command: String, config: GuardConfig) -> GuardVerdict? {
        var best: GuardVerdict?
        for rule in config.commandRules where rule.enabled {
            guard matches(rule.pattern, command, caseInsensitive: true) else { continue }
            let v = GuardVerdict(action: rule.action, kind: .command, subject: rule.name,
                                 reason: "Rollcage flagged this as a dangerous command (\(rule.name)). " +
                                 (rule.action == .block
                                  ? "It is blocked. Find a safer way, or ask the user to run it themselves."
                                  : "The user must approve it."))
            if rule.action == .block { return v }
            if best == nil { best = v }
        }
        return best
    }

    /// Splits a command line into simple commands.
    static func segments(of command: String) -> [[String]] {
        let parts = command.replacingOccurrences(of: #"\|\||&&|\$\(|[;|&\n`()]"#, with: "\u{1F}", options: .regularExpression)
            .split(separator: "\u{1F}")
        return parts.map { part in
            var words = part.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            while let first = words.first, ["sudo", "command", "builtin", "exec", "time", "nohup", "!"].contains(first) {
                words.removeFirst()
            }
            return words
        }
        .filter { !$0.isEmpty }
    }

    static let secretVarWords = ["KEY", "SECRET", "TOKEN", "PASSWORD", "PASSWD", "CREDENTIAL", "PRIVATE",
                                 "AUTH", "DSN", "DATABASE_URL", "CONNECTION_STRING", "_PASS", "COOKIE", "WEBHOOK", "SESSION"]
    static let harmlessVars: Set<String> = ["SSH_AUTH_SOCK", "GPG_AGENT_INFO", "KEYCHAIN", "XPC_SERVICE_NAME"]

    static func secretLookingVar(_ name: String) -> Bool {
        let up = name.uppercased()
        guard !harmlessVars.contains(up) else { return false }
        return secretVarWords.contains { up.contains($0) }
    }

    static func checkDumpSegment(_ words: [String]) -> GuardVerdict? {
        guard let first = words.first.map({ ($0 as NSString).lastPathComponent }) else { return nil }
        let args = Array(words.dropFirst())
        let nonFlags = args.filter { !$0.hasPrefix("-") }

        func dump(_ what: String) -> GuardVerdict {
            GuardVerdict(action: .block, kind: .envDump, subject: what,
                         reason: "Rollcage blocked `\(what)`: it would print environment variables, which may contain the user's secrets. " +
                         "Check for a variable without printing its value, e.g. `[ -n \"$NAME\" ] && echo set`.")
        }

        switch first {
        case "env":
            if nonFlags.isEmpty { return dump("env") }
        case "printenv":
            if nonFlags.isEmpty || nonFlags.contains(where: secretLookingVar) { return dump("printenv") }
        case "export", "declare", "typeset":
            if nonFlags.isEmpty && args.allSatisfy({ ["-p", "-x", "-px", "-xp"].contains($0) }) { return dump(first) }
        case "set":
            if args.isEmpty { return dump("set") }
        case "compgen":
            if args.contains("-e") || args.contains("-v") { return dump("compgen") }
        case "launchctl":
            if args.first == "getenv", args.dropFirst().contains(where: secretLookingVar) { return dump("launchctl getenv") }
            if args.first == "print" || args.first == "export" { return dump("launchctl \(args.first!)") }
        case "ps":
            if args.contains("-E") || (args.first.map { $0.range(of: #"^[a-zA-Z]{1,6}$"#, options: .regularExpression) != nil && $0.contains("e") } ?? false) {
                return dump("ps e")
            }
        case "cat", "less", "more", "head", "tail", "strings", "xxd", "od", "tr":
            if args.contains(where: { $0.contains("/proc/") && $0.contains("environ") }) { return dump("/proc/*/environ") }
        case "echo", "printf", "print", "say":
            let joined = args.joined(separator: " ")
            if let name = firstCapture(#"\$\{?!?([A-Za-z_][A-Za-z0-9_]*)"#, joined, where: secretLookingVar) {
                return dump("echo $\(name)")
            }
        case "security":
            let joined = args.joined(separator: " ")
            if joined.contains("dump-keychain")
                || (joined.range(of: #"find-(generic|internet)-password"#, options: .regularExpression) != nil
                    && (args.contains("-w") || args.contains("-g"))) {
                return GuardVerdict(action: .block, kind: .keychain, subject: "security \(args.first ?? "")",
                                    reason: "Rollcage blocked reading passwords from the macOS Keychain. Ask the user instead.")
            }
        default:
            break
        }
        return nil
    }

    /// An interpreter running code passed on the command line or via heredoc.
    static let inlineInterpreter = #"(?:^|[\s;&|(/])(?:python[0-9.]*|pypy[0-9]*|node|nodejs|bun|deno|ruby|irb|perl|php|lua|luajit|Rscript|julia|pwsh|powershell|osascript|groovy|kotlinc?|scala|swift|jshell|elixir|erl|tsx|ts-node)\b[^;&|\n]*?(?:\s(?:-c|-e|-E|-p|-r|--eval|--print|--command|-Command|eval)\b|\s-(?=\s|$)|<<)|(?:^|[\s;&|(])(?:g|n|m)?awk\b"#

    /// Environment access APIs across languages.
    static let envAPI = #"os\.environ|os\.getenv|\bgetenv\s*\(|process\.env|Deno\.env|Bun\.env|import\.meta\.env|\bENV\s*\[|\bENV\.(?:fetch|to_h|each|keys)|\$_ENV|\$_SERVER|%ENV|\$ENV\{|System\.getenv|Environment\.GetEnvironmentVariables?|std::env::vars?|\benv::vars?\b|os\.Getenv|os\.Environ|ProcessInfo\.processInfo\.environment|Sys\.getenv|\bENVIRON\b|\$env:|\bdotenv\b|load_dotenv|godotenv|System\.Environment|environ\["#

    // MARK: Regex helpers

    static func matches(_ pattern: String, _ s: String, caseInsensitive: Bool = false) -> Bool {
        s.range(of: pattern, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : .regularExpression) != nil
    }

    static func firstMatch(_ pattern: String, _ s: String) -> String? {
        guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
        return String(s[r])
    }

    static func firstCapture(_ pattern: String, _ s: String, where accept: (String) -> Bool) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
            let name = ns.substring(with: m.range(at: 1))
            if accept(name) { return name }
        }
        return nil
    }

    /// The verdict for one shell command, used by `rollcage-guard explain`.
    public static func explain(command: String, config: GuardConfig) -> GuardVerdict? {
        var c = config
        c.enabled = true
        return checkShell(command, config: c)
    }
}
