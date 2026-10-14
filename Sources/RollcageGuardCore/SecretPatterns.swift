import Foundation

/// One kind of credential the guard recognises. Used by the leak guard, which checks what an agent
/// is about to commit or push, and to mask keys before anything is written to the log.
public struct SecretRule {
    public enum Confidence { case certain, possible }

    public let name: String
    public let pattern: String
    /// Capture group holding the secret itself (0 = whole match).
    public var group = 0
    public var confidence = Confidence.certain
    /// Where the user replaces this kind of key.
    public var rotateURL: String? = nil

    public static let all: [SecretRule] = [
        SecretRule(name: "Anthropic API key", pattern: #"sk-ant-[A-Za-z0-9_-]{24,}"#,
                   rotateURL: "https://console.anthropic.com/settings/keys"),
        SecretRule(name: "OpenAI API key", pattern: #"sk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{24,}|\bsk-[A-Za-z0-9]{40,}"#,
                   rotateURL: "https://platform.openai.com/api-keys"),
        SecretRule(name: "AWS access key", pattern: #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,
                   rotateURL: "https://console.aws.amazon.com/iam/home#/security_credentials"),
        SecretRule(name: "GitHub token", pattern: #"\bgh[pousr]_[A-Za-z0-9]{36,}|\bgithub_pat_[A-Za-z0-9_]{60,}"#,
                   rotateURL: "https://github.com/settings/tokens"),
        SecretRule(name: "Stripe live key", pattern: #"\b[sr]k_live_[A-Za-z0-9]{20,}"#,
                   rotateURL: "https://dashboard.stripe.com/apikeys"),
        SecretRule(name: "Stripe webhook secret", pattern: #"\bwhsec_[A-Za-z0-9]{24,}"#,
                   rotateURL: "https://dashboard.stripe.com/webhooks"),
        SecretRule(name: "Stripe test key", pattern: #"\b[sr]k_test_[A-Za-z0-9]{20,}"#, confidence: .possible,
                   rotateURL: "https://dashboard.stripe.com/test/apikeys"),
        SecretRule(name: "Google API key", pattern: #"\bAIza[0-9A-Za-z_-]{35}\b"#,
                   rotateURL: "https://console.cloud.google.com/apis/credentials"),
        SecretRule(name: "Slack token", pattern: #"\bxox[baprs]-[A-Za-z0-9-]{20,}"#,
                   rotateURL: "https://api.slack.com/apps"),
        SecretRule(name: "npm token", pattern: #"\bnpm_[A-Za-z0-9]{36}\b"#,
                   rotateURL: "https://www.npmjs.com/settings/~/tokens"),
        SecretRule(name: "SendGrid key", pattern: #"\bSG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}"#,
                   rotateURL: "https://app.sendgrid.com/settings/api_keys"),
        SecretRule(name: "Resend key", pattern: #"\bre_[A-Za-z0-9]{8,}_[A-Za-z0-9]{20,}"#,
                   rotateURL: "https://resend.com/api-keys"),
        SecretRule(name: "Private key", pattern: #"-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----[A-Za-z0-9+/=\\\s]{40,}?-----END (?:[A-Z]+ )*PRIVATE KEY-----"#),
        SecretRule(name: "Database URL with password",
                   pattern: #"\b(?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|rediss?|amqps?)://[^\s:"'/@\\]+:([^\s"'@\\]{6,})@[^\s"'/\\]+"#,
                   group: 1),
        SecretRule(name: "JSON Web Token", pattern: #"\beyJ[A-Za-z0-9_-]{12,}\.eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{16,}"#,
                   confidence: .possible),
        SecretRule(name: "Secret-looking value",
                   pattern: #"\b[A-Z][A-Z0-9_]*(?:SECRET|TOKEN|API_?KEY|PASSWORD|PASSWD|PRIVATE_KEY|ACCESS_KEY)[A-Z0-9_]*\\?["']?\s*[=:]\s*\\?["']?([A-Za-z0-9_\-+/=.]{20,})"#,
                   group: 1, confidence: .possible),
    ]

    public static let compiled: [(rule: SecretRule, regex: NSRegularExpression)] = all.compactMap { rule in
        (try? NSRegularExpression(pattern: rule.pattern)).map { (rule, $0) }
    }

    private static let placeholderWords = ["example", "your", "xxxx", "placeholder", "changeme", "replace", "redacted",
                                           "process.env", "dummy", "sample", "0000000", "abcdef", "123456"]

    /// False for values that are obviously placeholders, and for catch-all matches that don't look random.
    public static func plausible(_ value: String, rule: SecretRule) -> Bool {
        let lower = value.lowercased()
        if placeholderWords.contains(where: { lower.contains($0) }) { return false }
        if value.contains("****") || value.contains("....") || value.contains("•") { return false }
        guard rule.name == "Secret-looking value" else { return true }
        // The catch-all needs to look random: mixed character classes and high entropy.
        let hasDigit = value.contains(where: \.isNumber)
        let hasLetter = value.contains(where: \.isLetter)
        guard hasDigit, hasLetter, !value.contains("/") || value.count >= 32 else { return false }
        var counts: [Character: Double] = [:]
        for c in value { counts[c, default: 0] += 1 }
        let n = Double(value.count)
        let entropy = -counts.values.reduce(0) { $0 + ($1 / n) * log2($1 / n) }
        return entropy >= 3.6
    }

    /// Names of the certain-kind credentials in `text` (no values), in the order found.
    public static func certainKinds(in text: String) -> [String] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var names: [String] = []
        for (rule, regex) in compiled where rule.confidence == .certain {
            for match in regex.matches(in: text, range: whole) {
                let range = match.range(at: rule.group)
                guard range.location != NSNotFound, plausible(ns.substring(with: range), rule: rule) else { continue }
                if !names.contains(rule.name) { names.append(rule.name) }
                break
            }
        }
        return names
    }

    /// `text` with credential values masked, for logs.
    public static func masked(_ text: String) -> String {
        var out = text
        for (rule, regex) in compiled where rule.confidence == .certain {
            let ns = out as NSString
            var ranges: [NSRange] = []
            for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                let r = match.range(at: rule.group)
                if r.location != NSNotFound { ranges.append(r) }
            }
            for r in ranges.reversed() {
                let value = (out as NSString).substring(with: r)
                let keep = min(4, value.count / 4)
                out = (out as NSString).replacingCharacters(in: r, with: String(value.prefix(keep)) + "••••")
            }
        }
        return out
    }
}
