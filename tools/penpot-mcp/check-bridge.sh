#!/usr/bin/env bash
# Probes a running bridge: the plugin manifest on :4400 and an MCP `initialize`
# handshake on :4401. Exits non-zero on the first thing that does not answer.
set -uo pipefail

PLUGIN_URL="http://localhost:4400"
MCP_URL="http://localhost:4401/mcp"

fail() {
    printf 'FAIL %s\n' "$*" >&2
    exit 1
}

manifest="$(curl -fsS --max-time 10 "$PLUGIN_URL/manifest.json")" || fail "no manifest at $PLUGIN_URL/manifest.json"
case "$manifest" in *'"plugin.js"'*) ;; *) fail "manifest does not name the plugin entry point: $manifest" ;; esac
printf 'ok   plugin manifest at %s/manifest.json\n' "$PLUGIN_URL"

curl -fsS --max-time 10 -o /dev/null "$PLUGIN_URL/plugin.js" || fail "no plugin code at $PLUGIN_URL/plugin.js"
printf 'ok   plugin code at %s/plugin.js\n' "$PLUGIN_URL"

handshake="$(curl -fsS --max-time 10 -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check-bridge","version":"1.0"}}}')" ||
    fail "no MCP endpoint at $MCP_URL"
case "$handshake" in *'"serverInfo"'*) ;; *) fail "MCP endpoint did not complete initialize: $handshake" ;; esac
printf 'ok   MCP initialize at %s\n' "$MCP_URL"
