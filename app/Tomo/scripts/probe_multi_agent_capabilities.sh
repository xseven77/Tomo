#!/bin/sh

# Read-only compatibility probe. It intentionally does not print account
# metadata, API keys, session titles, prompts, tool arguments, or transcripts.

set -eu

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_version() {
    name="$1"
    if ! command_exists "$name"; then
        printf '%s\tmissing\n' "$name"
        return
    fi

    version="$($name --version 2>/dev/null | sed -n '1p')"
    if [ -z "$version" ]; then
        version="$($name version 2>/dev/null | sed -n '1p')"
    fi
    printf '%s\tinstalled\t%s\n' "$name" "$version"
}

has_help_text() {
    label="$1"
    pattern="$2"
    shift 2
    if "$@" --help 2>&1 | grep -q "$pattern"; then
        printf '%s\tsupported\n' "$label"
    else
        printf '%s\tunsupported\n' "$label"
    fi
}

for runtime in codex hermes claude reasonix; do
    print_version "$runtime"
done

if command_exists codex; then
    has_help_text codex.app-server 'generate-json-schema' codex app-server

    probe_root="$(mktemp -d /tmp/codexling-codex-homes.XXXXXX)"
    trap 'rm -rf "$probe_root"' EXIT HUP INT TERM
    mkdir -p "$probe_root/personal" "$probe_root/work"
    printf 'cli_auth_credentials_store = "file"\n' > "$probe_root/personal/config.toml"
    printf 'cli_auth_credentials_store = "file"\n' > "$probe_root/work/config.toml"
    personal_status="$(CODEX_HOME="$probe_root/personal" codex login status 2>&1 || true)"
    work_status="$(CODEX_HOME="$probe_root/work" codex login status 2>&1 || true)"
    if [ "$personal_status" = "Not logged in" ] && [ "$work_status" = "Not logged in" ]; then
        printf 'codex.multi-home\tsupported\n'
    else
        printf 'codex.multi-home\tprobe-inconclusive\n'
    fi

    schema_root="$(mktemp -d /tmp/codexling-codex-schema.XXXXXX)"
    codex app-server generate-json-schema --experimental --out "$schema_root" >/dev/null 2>&1
    schema_bundle="$schema_root/codex_app_server_protocol.schemas.json"
    for method in 'thread/list' 'thread/started' 'turn/started' 'account/read' 'account/rateLimits/read'; do
        if grep -q "$method" "$schema_bundle"; then
            printf 'codex.protocol.%s\tsupported\n' "$method"
        else
            printf 'codex.protocol.%s\tunsupported\n' "$method"
        fi
    done
    rm -rf "$schema_root"
fi

if command_exists hermes; then
    has_help_text hermes.acp 'Agent Client Protocol' hermes
    has_help_text hermes.hooks 'Inspect and manage shell-script hooks' hermes
fi

if command_exists claude; then
    has_help_text claude.agents-json 'Print active sessions' claude agents
fi

if command_exists reasonix; then
    if reasonix acp --help 2>&1 | grep -q 'workspace-only'; then
        printf 'reasonix.acp\tsupported\n'
    else
        printf 'reasonix.acp\tunsupported\n'
    fi
fi

for app in Codex Claude Reasonix; do
    if [ -d "/Applications/$app.app" ]; then
        printf '%s.desktop\tinstalled\n' "$app"
    else
        printf '%s.desktop\tmissing\n' "$app"
    fi
done
