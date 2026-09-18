#!/usr/bin/env bash
# Penpot MCP bridge. Serves the plugin (manifest on :4400), the MCP streamable
# HTTP endpoint (:4401), the plugin WebSocket (:4402) and the REPL (:4403).
#
# Runs the two servers as direct children: upstream's `pnpm run start` spawns
# them into process groups of their own, which survive a kill of the parent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$ROOT/node_modules/@penpot/mcp"
export PATH="$ROOT/node_modules/.bin:$PATH"

log() { printf '[bridge] %s\n' "$*" >&2; }

any_alive() {
    local pid
    for pid in "$@"; do
        kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}

# A previous run killed with SIGKILL leaves node processes holding the ports.
# They are identified by their working directory, so an unrelated process that
# happens to hold port 4400 is left alone.
stop_previous() {
    local proc pid cwd exe stale=()
    for proc in /proc/[0-9]*; do
        pid="${proc#/proc/}"
        [ "$pid" = "$$" ] && continue
        cwd="$(readlink "$proc/cwd" 2>/dev/null)" || continue
        case "$cwd" in "$PKG" | "$PKG"/*) ;; *) continue ;; esac
        exe="$(basename "$(readlink "$proc/exe" 2>/dev/null || true)")"
        case "$exe" in node | esbuild | pnpm) stale+=("$pid") ;; esac
    done
    [ ${#stale[@]} -eq 0 ] && return 0

    log "stopping processes left by an earlier run: ${stale[*]}"
    kill -TERM "${stale[@]}" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        any_alive "${stale[@]}" || return 0
        sleep 0.5
    done
    kill -KILL "${stale[@]}" 2>/dev/null || true
}

# pnpm 11 replaced `onlyBuiltDependencies` with `allowBuilds` in
# pnpm-workspace.yaml, and pnpm 12 fails an install outright while any
# dependency's build scripts are undecided. esbuild and sharp need theirs, and
# pnpm only learns which packages are pending by attempting them, so the first
# install on a fresh tree is expected to stop. `approve-builds` records the
# decision in the workspace's pnpm-workspace.yaml, which sits inside
# node_modules and so is lost to every reinstall.
install_workspace() {
    local install_log="$ROOT/.pnpm-install.log"
    if pnpm -r install >"$install_log" 2>&1; then
        cat "$install_log"
        return 0
    fi
    if grep -q ERR_PNPM_IGNORED_BUILDS "$install_log"; then
        log "approving the dependency build scripts pnpm stopped for, then retrying"
        pnpm approve-builds --all --yes
        pnpm -r install
        return 0
    fi
    cat "$install_log" >&2
    return 1
}

bootstrap() {
    [ -d "$PKG" ] || npm --prefix "$ROOT" install
    cd "$PKG"
    install_workspace
    pnpm run build
}

stop_previous
bootstrap

( cd "$PKG/packages/server" && exec node dist/index.js ) &
server_pid=$!
( cd "$PKG/packages/plugin" && exec node node_modules/vite/bin/vite.js build --watch --config vite.config.ts ) &
plugin_pid=$!

stop_children() {
    kill -TERM "$server_pid" "$plugin_pid" 2>/dev/null || true
    wait "$server_pid" "$plugin_pid" 2>/dev/null || true
}
trap stop_children EXIT
trap 'log "stopped"; stop_children; exit 0' INT TERM

log "MCP endpoint http://localhost:4401/mcp | plugin manifest http://localhost:4400/manifest.json"

set +e
wait -n
status=$?
log "a bridge process exited with status $status; stopping the other"
stop_children
exit "$status"
