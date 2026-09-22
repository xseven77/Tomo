# Tomo Project

## Current Status

Tomo is a native Swift/SwiftUI macOS menu-bar app (accessory mode) paired with a local Rust LLM gateway. It is no longer an initial shell or folder-layout proposal.

Implemented:

1. Multi-provider account and quota monitoring for Codex (OpenAI OAuth PKCE), Google Gemini (OAuth), DeepSeek, and OpenCode (Go/Zen) API keys, with unified refresh, per-account credential files, and carousel display.
2. Multi-agent activity monitoring for Codex, DeepSeek Harness (DSH), Hermes, Antigravity, and Pi — passive, read-only discovery from local session/state files (SQLite, JSONL, zstd archives) plus a Unix-socket event bridge; no hooks are injected into any agent.
3. A local LLM gateway built from the Rust workspace (`crates/gateway-server` → `codexling-gateway`), supervised as a helper subprocess on `127.0.0.1:58349` with local bearer-token auth. It proxies OpenAI Chat Completions, OpenAI Responses, and Anthropic Messages, routes across accounts (smooth round-robin or pinned with automatic failover), brokers keys, and records telemetry.
4. Model health inspection: scheduled + manual probes per account, strict `/v1/models` filtering, full diagnostics on `/v1/models/all`, persisted failure reasons and latencies.
5. One-click gateway integration for Hermes, Pi, and DSH (idempotent, span-based config edits with capacity/modality/reasoning declarations; token rotation syncs automatically).
6. Status-bar capsule (task dot + quota text + activity wave), notch panel (provider card carousel, multi-display targeting, drag on external displays, legacy fallback), detached companion dashboard (horizontal/vertical), standalone pet window, and gateway window (7 tabs).
7. Built-in and custom pet discovery, Tomo pet installation, and two-way pet selection sync with Codex.
8. Configurable automatic refresh, local snapshot caching, update checks, and optional always-on-top window behavior.
9. Ad-hoc signed `.app`, `.zip`, and `.dmg` packaging plus an interactive GitHub Release script.

The distributed build is currently ad-hoc signed and is **not notarized**.

## Current Folder Layout

```text
Tomo/
├── README.md
├── PROJECT.md
├── Cargo.toml             # Rust workspace: gateway + protocol crates
├── crates/                # gateway-ir / -stream / -state / -routing / -server,
│                          # protocol-openai-chat / -openai-responses / -anthropic-messages,
│                          # provider-openai-compatible
├── spikes/                # feasibility spikes (gateway-feasibility)
├── fixtures/              # protocol fixtures used by Rust tests
├── docs/
│   ├── manual/            # code-derived operation manual (closest to reality)
│   ├── concepts/          # UI concept / preview HTML + index README
│   ├── multi-agent/       # multi-agent & gateway research and plans
│   └── *.md               # current plans and feature records
├── app/
│   ├── Tomo/         # Swift package: app, agent-bridge CLI, tests, release scripts
│   └── landing/           # Next.js landing
├── docker/landing/         # landing container deployment
├── scripts/               # brand asset sync helpers
└── assets/screenshots/    # README screenshots
```

## Technical Boundaries

- Use Swift + SwiftUI with AppKit where macOS status-item, notch, and window behavior requires it.
- Keep the non-public ChatGPT `wham` and `subscriptions` endpoints isolated in `CodexUsageService` and `TomoParser`.
- Store all provider credentials as isolated files with mode `0600` under `~/Library/Application Support/Tomo/` (Codex OAuth under `Runtimes/Codex/<UUID>/`, Gemini under `gemini_oauth/`, DeepSeek/OpenCode under dedicated credential directories); migrate and remove legacy Keychain entries when found. Keychain remains in use only for gateway-side key escrow (`GatewaySecretBroker`).
- Store the last successful quota snapshot and companion statistics in Application Support.
- Read agent session/state files (Codex SQLite/JSONL, DSH zstd, Hermes SQLite, Antigravity transcripts, Pi JSONL) locally and read-only; the activity parser derives task state and a truncated visible summary only — it never persists, uploads, or renders model reasoning, raw tool arguments, complete prompts, tokens, or environment variables.
- Read Codex pet configuration read-only except when the user explicitly selects or installs a pet.
- The gateway binds to loopback by default; when LAN access is enabled it binds `0.0.0.0` and enforces bearer auth on chat/model endpoints for non-loopback peers, with admin endpoints requiring auth from all peers.
- Never request account passwords, browser cookies, or MFA codes.

## Release Boundary

`package_app.sh` builds the Swift app and agent-bridge, builds the Rust gateway via Cargo, and produces ad-hoc signed local artifacts containing all three binaries. `release_app.sh` validates the workspace and GitHub authentication, updates the version, packages and verifies the DMG, commits the version when needed, pushes the branch/tag, and creates or updates the GitHub Release.

Apple Developer ID signing and notarization remain future release-hardening work.
