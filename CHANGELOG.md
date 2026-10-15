# Changelog

## Unreleased

- Claude Code plugin (`/plugin install rollcage --marketplace nmaties/rollcage-guard`) that adds the Rollcage MCP server at https://rollcage.app/mcp.

## 1.0.0

First open-source release of the guard from [Rollcage](https://rollcage.app) 1.0.2, as a standalone CLI.

- Blocks secret files, environment dumps and inline code that reads environment variables.
- Blocks or asks before destructive commands, cloud deletions, DELETE requests and remote database connections.
- Checks what `git commit` and `git push` would send for API keys, private keys and secret files, and asks before pushes to protected branches.
- Blocks paste, file-drop and tunnel sites, with an optional allowed-sites-only mode.
- `install`, `uninstall`, `status`, `explain`, `log` and `config` commands for Claude Code, Codex CLI, Cursor and Gemini CLI.
- Builds on macOS and Linux.
