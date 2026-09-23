# Tomo Agent & Provider Brand Assets

This directory is the project-wide source of truth for Agent, coding-tool, model,
and API-provider brand artwork. UI code should use these files instead of drawing
temporary letter marks or downloading logos at runtime.

## Layout

Each `catalog/<slug>/` directory may contain:

- `icon.svg`: small monochrome/brand icon for compact connection controls.
- `color.svg`: color icon when the upstream collection provides one.
- `logo.svg` or `logo.png`: wider or high-detail artwork for large cards.
- `app-icon.png`: vendor application icon when provided by its official repo.

Prefer `color.svg`, then `icon.svg`, for UI icons. Preserve the original aspect
ratio and clear space. Do not recolor trademark artwork unless its own brand guide
allows it.

### SVG sizing

SVG `width`/`height` must be explicit pixel values (e.g. `width="64" height="64"`,
or `width="91" height="24"` for wordmarks) — never `1em`. AppKit's `NSImage` rasterizes
at the declared size, so `1em` collapses to ~1px and the logo renders as a smeared sliver.
See `BRAND_INVENTORY.md` for the per-brand file inventory and previews.

## Sources and licenses

- Most AI brands come from [Lobe Icons](https://github.com/lobehub/lobe-icons),
  commit `f07e9be35aef452ce735f95ea8204a14ecc513f7`, MIT license.
- Codex additionally vendors the Lobe Icons static PNG export from
  `@lobehub/icons-static-png@1.91.0`; the app prefers it because macOS CoreSVG
  drops part of the upper-left lobe when rasterizing the compound SVG path.
- Hermes Agent artwork comes from the
  [official Hermes repository](https://github.com/hermes-agent-org/hermes),
  commit `036cbdfa0a3158454a0a2a7a7388cf70353326b4`, MIT license.
  The app-specific `hermes-agent/app-icon.png` is user-provided custom artwork
  and is preferred by Tomo's connection UI.
- Reasonix artwork comes from the
  [official DeepSeek-Reasonix repository](https://github.com/esengine/DeepSeek-Reasonix),
  commit `e83b8dbe0e79b04284b4cc181d24127821c4513d`, MIT license.

The corresponding license texts are vendored under `THIRD_PARTY_LICENSES/`.
Brand names and logos can remain trademarks of their respective owners even
when the asset repository is MIT-licensed. Use them only to identify the related
integration or service.

## Included catalog

Priority integrations: Codex, Hermes Agent, Claude Code, Reasonix, and DeepSeek.

Common coding agents and tools: GitHub Copilot, Gemini CLI, Cursor, Windsurf,
Qwen Code, Kimi Code, OpenCode, OpenHands, Qoder, Kiro, Replit, Devin, OpenClaw,
Pi Agent, and Antigravity.

Common providers and runtimes: OpenAI, Anthropic, Google Gemini, Moonshot,
Qwen, OpenRouter, Mistral, Groq, Together AI, Ollama, Cohere, Perplexity,
Azure AI, AWS Bedrock, SiliconFlow, Zhipu, MiniMax, Hugging Face, NVIDIA,
xAI, Fireworks, Vertex AI, Cloudflare Workers AI, and LM Studio.
