# Rollcage Guard

[![CI](https://github.com/nmaties/rollcage-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/nmaties/rollcage-guard/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A free, open-source hook that stops AI coding agents from **reading your secrets**, **leaking keys in commits** and **running destructive commands**. It works with **Claude Code, Codex CLI, Cursor and Gemini CLI**.

```console
$ rollcage-guard install
Claude Code   hook added to ~/.claude/settings.json
Cursor        hook added to ~/.cursor/hooks.json
Gemini CLI    hook added to ~/.gemini/settings.json

$ rollcage-guard explain "cat .env.local"
block: .env.local
Rollcage blocked access to .env.local: it contains secrets the user hasn't shared with coding agents. …

$ rollcage-guard explain "git push --force origin main"
ask: Force push
```

Agents run as you. They can read every file you can and run every command you can, and it takes one approved prompt for a `cat .env` to send your keys to a model, or for an `rm -rf` on the wrong path to delete your work. Rollcage Guard checks every tool call before it runs, using each agent's own hook system. It runs locally, needs no account and sends nothing anywhere.

## What it stops

| | Examples | Default |
|---|---|---|
| **Secret files** | `.env`, `.env.local`, `.envrc`, `.dev.vars`, `.npmrc`, `~/.ssh`, `~/.aws`, `~/.kube/config`, `*.pem`, `*.key`, Rails `master.key`, `*.tfstate`, `*.tfvars`, service-account JSON, `wp-config.php`… (`.env.example` and friends are allowed) | block |
| **Environment dumps** | `env`, `printenv`, `export -p`, `set`, `echo $OPENAI_API_KEY`, `ps eww`, `/proc/*/environ`, Keychain password reads | block |
| **Code that reads env vars** | `python -c 'os.environ'`, `node -e 'process.env'`, `ruby -e`, `php -r`, `perl -e`, `deno eval`, `awk ENVIRON`… | block |
| **Destructive commands** | `rm -rf ~` / `.` / `*`, `git clean -f`, `DROP DATABASE`, `TRUNCATE`, `prisma migrate reset`, `rails db:drop`, `mkfs`, `diskutil erase…` | block |
| **Risky commands** | `git reset --hard`, `git checkout .`, force push, `curl … \| sh`, `sudo`, `terraform destroy`, `kubectl delete`, `npm publish`, `vercel --prod` | ask |
| **Cloud and production** | `aws … delete-*`, `gcloud … delete`, `fly destroy`, `heroku apps:destroy`, `supabase db reset`, `gh repo delete`, `curl -X DELETE` to remote APIs, connections to remote databases | ask |
| **Key leaks** | Before `git commit` or `git push`: Anthropic, OpenAI, AWS, GitHub, Stripe, Google, Slack, npm, SendGrid and Resend keys, private keys, database URLs with passwords, and secret files in what's about to be committed or pushed | block |
| **Protected branches** | Pushing to `main`, `master`, `production`, `prod` or `release` | ask |
| **Exfiltration sites** | Paste, file-drop and tunnel sites in URLs and commands: `pastebin.com`, `transfer.sh`, `webhook.site`, `ngrok`, `trycloudflare.com`… An optional allowed-sites-only mode asks before anything else. | block |

**Block** refuses the call and tells the agent why, so it can find a safer way. **Ask** shows the agent's own approval prompt. Codex, Gemini CLI and Cursor's file-read hook can't ask, so there "ask" becomes a block with an explanation.

## Install

### macOS: signed and notarized binary (Apple silicon and Intel)

```bash
curl -fsSL -o /tmp/rollcage-guard.tar.gz https://github.com/nmaties/rollcage-guard/releases/latest/download/rollcage-guard-macos.tar.gz
tar -xzf /tmp/rollcage-guard.tar.gz -C /tmp rollcage-guard
sudo install -d /usr/local/bin && sudo install -m 755 /tmp/rollcage-guard /usr/local/bin/
rollcage-guard install
```

### Homebrew

```bash
brew tap nmaties/rollcage-guard https://github.com/nmaties/rollcage-guard
brew trust nmaties/rollcage-guard   # Homebrew 7 and later asks before installing from third-party taps
brew install rollcage-guard
rollcage-guard install
```

### From source (macOS or Linux, Swift 5.9+)

```bash
git clone https://github.com/nmaties/rollcage-guard && cd rollcage-guard
swift build -c release
sudo install -m 755 .build/release/rollcage-guard /usr/local/bin/
rollcage-guard install
```

Restart any agent that's already running so it loads the hook.

## Use

```text
rollcage-guard install [AGENT...]          add the hook to every agent found, or only the ones named
rollcage-guard uninstall [AGENT...]        remove it again
rollcage-guard status                      which agents are guarded, where the rules and log are
rollcage-guard explain "COMMAND"           what the guard would do with a command (add --cwd DIR for git checks)
rollcage-guard log [-n 50]                 what it blocked or asked about recently
rollcage-guard config --init               write the default rules to a file you can edit
```

Agents are `claude`, `codex`, `cursor` and `gemini`. `install` edits each agent's config file, keeps every other setting and hook as it was, and saves a one-time backup next to it (`*.rollcage-backup`). Run `rollcage-guard uninstall` before deleting the binary, or the hooks will point at a file that's gone.

## How it works

| Agent | Config file | Hook |
|---|---|---|
| Claude Code | `~/.claude/settings.json` | `PreToolUse` on every tool |
| Codex CLI | `~/.codex/hooks.json` | `PreToolUse` on shell commands and patches (approve it once with `/hooks` in Codex) |
| Cursor | `~/.cursor/hooks.json` | `beforeShellExecution`, `beforeReadFile`, `beforeMCPExecution` |
| Gemini CLI | `~/.gemini/settings.json` | `BeforeTool` on every tool |

Before each tool call, the agent runs `rollcage-guard --agent <name>` with the call as JSON on stdin. The guard pulls out the file paths, shell commands and URLs and checks them against the rules. For `git commit` and `git push` it also checks the staged changes and the commits about to leave. It then answers in the format that agent expects. A call takes a few milliseconds; git checks give up after 4 seconds.

It **fails open**. If anything inside the guard goes wrong, the call is allowed, so a bug can't lock you out of your agent. Blocks and approval requests are logged with keys masked (`sk-ant-api0••••`), never in full.

## Configure

The defaults apply until you write a rules file:

```bash
rollcage-guard config --init     # macOS: ~/Library/Application Support/Rollcage/guard.json
                                 # Linux: ~/.config/rollcage/guard.json
```

Every check can be switched off (`secretsEnabled`, `blockEnvDumps`, `blockInlineEnvCode`, `commandsEnabled`, `networkEnabled`, `leakGuardEnabled`, `protectedBranchesEnabled`), and every list can be edited: `secretFilePatterns`, `secretAllowPatterns`, `blockedDomains`, `allowedDomains`, `protectedBranches`. Command rules are regular expressions with an action, and you can add your own:

```json
{
  "id": "no-prod-migrations",
  "name": "Migrations against production",
  "detail": "anything that runs migrations with NODE_ENV=production",
  "pattern": "NODE_ENV=production[^;&|\\n]*\\bmigrate\\b",
  "action": "block",
  "enabled": true
}
```

The hook reads the file on every call, so changes apply straight away. New built-in rules from later versions are added to your file automatically. Set `ROLLCAGE_GUARD_HOME` to keep the rules and log somewhere else.

## Limits

- **It's a guardrail, not a sandbox.** It sees the tool calls an agent makes, not what happens inside a script the agent writes and then runs. Use it alongside your agent's sandbox and permission settings, not instead of them.
- **It matches patterns.** It catches the ways agents actually reach for secrets and run destructive commands, not every possible disguise. If you find a bypass, please [report it](SECURITY.md).
- **It only covers agents with hooks**: Claude Code, Codex CLI, Cursor and Gemini CLI. Aider, Goose and others have no pre-tool-use hook to plug into.

## Rollcage for Mac

Rollcage Guard is the open-source core of **[Rollcage](https://rollcage.app/?utm_source=github&utm_medium=readme&utm_campaign=rollcage-guard)**, a Mac menu-bar app for what a hook can't do:

- **Instant snapshots** of your projects when any agent starts (APFS clones, near-zero disk space).
- **Undo a whole agent session in one click**, with a report of every file it deleted, edited and created.
- **A mass-delete alarm** when files start disappearing.
- **A leaked-key scan** of agent transcripts and history, with links to rotate each key.
- A UI for the guard's rules and log, agent alerts when an agent needs you, plan limits, token costs and more.

Installing the app takes over these hooks automatically and keeps your rules and log. [Try it free for 7 days](https://rollcage.app/download?utm_source=github&utm_medium=readme&utm_campaign=rollcage-guard).

## Contributing

Issues and pull requests are welcome, especially false positives (something safe that was blocked) and false negatives (something dangerous that got through). Please include the exact command or tool call. Run the tests with `swift test`.

## License

[MIT](LICENSE)
