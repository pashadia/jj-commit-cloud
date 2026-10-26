#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  cc-workflow.sh up --workspace DIR [options]
  cc-workflow.sh status [--state-dir DIR]
  cc-workflow.sh down [--state-dir DIR]

Start the local Commit Cloud server and initialize a workspace with the custom
jj binary. The default native mode stores working files directly in DIR.

Options for up:
  --workspace DIR       Workspace directory to initialize or mount
  --mode MODE           native (default) or vfs
  --mount DIR           Empty mountpoint; required for vfs mode
  --project-id ID       Project ID, required when initializing a new workspace
  --reuse-existing-workspace  Use an existing workspace already initialized as local
  --port PORT           Local server port (default: 8080)
  --store-type TYPE     sqlite or spanner (default: sqlite)
  --sqlite-path FILE    SQLite database path (default: STATE_DIR/commit_cloud.db)
  --spanner-db RESOURCE Spanner resource path; also enables the Spanner store
  --clear-working-copy  Run `jj sparse set --clear` before a VFS mount
  --state-dir DIR       PID and log directory

Binary overrides:
  JJ_CC_SERVER_BIN, JJ_CC_JJ_BIN, JJ_CC_DAEMON_BIN, JJ_CC_VFS_BIN
Profile selection:
  JJ_CC_PROFILE=release|debug (default: release)
USAGE
}

fail() {
    printf 'cc-workflow: %s\n' "$*" >&2
    exit 1
}

SCRIPT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -P "$SCRIPT_DIR/.." && pwd)
PROFILE=${JJ_CC_PROFILE:-release}
[[ "$PROFILE" == "release" || "$PROFILE" == "debug" ]] || fail "JJ_CC_PROFILE must be 'release' or 'debug'"

if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    DEFAULT_STATE_DIR="$XDG_STATE_HOME/jj-cc-workflow"
else
    DEFAULT_STATE_DIR="${HOME:-/tmp}/.local/state/jj-cc-workflow"
fi

STATE_DIR=${JJ_CC_WORKFLOW_STATE_DIR:-$DEFAULT_STATE_DIR}
ACTION=${1:-}
[[ -n "$ACTION" ]] || { usage; exit 2; }
shift

WORKSPACE=
MOUNT=
PROJECT_ID=
PORT=8080
STORE_TYPE=sqlite
SQLITE_PATH=
SPANNER_DB=
CLEAR_WORKING_COPY=0
REUSE_EXISTING_WORKSPACE=0
MODE=native
MODE_EXPLICIT=0
PORT_EXPLICIT=0

while (($#)); do
    case "$1" in
        --workspace)
            (($# >= 2)) || fail "--workspace needs a directory"
            WORKSPACE=$2; shift 2 ;;
        --mount)
            (($# >= 2)) || fail "--mount needs a directory"
            MOUNT=$2; shift 2 ;;
        --mode)
            (($# >= 2)) || fail "--mode needs native or vfs"
            MODE=$2; MODE_EXPLICIT=1; shift 2 ;;
        --project-id)
            (($# >= 2)) || fail "--project-id needs an ID"
            PROJECT_ID=$2; shift 2 ;;
        --reuse-existing-workspace)
            REUSE_EXISTING_WORKSPACE=1; shift ;;
        --port)
            (($# >= 2)) || fail "--port needs a port number"
            PORT=$2; PORT_EXPLICIT=1; shift 2 ;;
        --store-type)
            (($# >= 2)) || fail "--store-type needs sqlite or spanner"
            STORE_TYPE=$2; shift 2 ;;
        --sqlite-path)
            (($# >= 2)) || fail "--sqlite-path needs a file path"
            SQLITE_PATH=$2; shift 2 ;;
        --spanner-db)
            (($# >= 2)) || fail "--spanner-db needs a resource path"
            SPANNER_DB=$2; STORE_TYPE=spanner; shift 2 ;;
        --clear-working-copy)
            CLEAR_WORKING_COPY=1; shift ;;
        --state-dir)
            (($# >= 2)) || fail "--state-dir needs a directory"
            STATE_DIR=$2; shift 2 ;;
        --help|-h)
            usage; exit 0 ;;
        *)
            fail "unknown option: $1" ;;
    esac
done

mkdir -p "$STATE_DIR"
STATE_DIR=$(cd -P "$STATE_DIR" && pwd)

SERVER_PID_FILE="$STATE_DIR/server.pid"
SERVER_BIN_FILE="$STATE_DIR/server.bin"
SERVER_LOG="$STATE_DIR/server.log"
VFS_PID_FILE="$STATE_DIR/vfs.pid"
VFS_BIN_FILE="$STATE_DIR/vfs.bin"
VFS_LOG="$STATE_DIR/vfs.log"
MOUNT_FILE="$STATE_DIR/mount.path"
WORKSPACE_FILE="$STATE_DIR/workspace.path"
MODE_FILE="$STATE_DIR/mode"
PORT_FILE="$STATE_DIR/port"

if ((PORT_EXPLICIT == 0)) && [[ -f "$PORT_FILE" ]]; then
    PORT=$(cat "$PORT_FILE")
fi
if [[ -n "$MOUNT" && $MODE_EXPLICIT == 0 ]]; then
    MODE=vfs
fi

resolve_binary() {
    local override=$1 default_path=$2 command_name=$3
    if [[ -n "$override" ]]; then
        [[ -x "$override" ]] || fail "binary is not executable: $override"
        (cd -P "$(dirname "$override")" && printf '%s/%s\n' "$PWD" "$(basename "$override")")
    elif [[ -x "$default_path" ]]; then
        (cd -P "$(dirname "$default_path")" && printf '%s/%s\n' "$PWD" "$(basename "$default_path")")
    else
        local found
        found=$(command -v "$command_name" || true)
        [[ -n "$found" ]] || fail "cannot find $command_name; build it or set its JJ_CC_*_BIN override"
        (cd -P "$(dirname "$found")" && printf '%s/%s\n' "$PWD" "$(basename "$found")")
    fi
}

pid_is_process() {
    local pid_file=$1 bin_file=$2 pid expected actual
    [[ -f "$pid_file" && -f "$bin_file" ]] || return 1
    pid=$(cat "$pid_file")
    expected=$(cat "$bin_file")
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    actual=$(ps -p "$pid" -o command= 2>/dev/null || true)
    [[ "$actual" == *"$expected"* ]]
}

tcp_is_open() {
    command -v nc >/dev/null 2>&1 || fail "the 'nc' utility is required to check the local server port"
    nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1
}

wait_for_server_port() {
    local pid attempt
    pid=$1
    for ((attempt = 0; attempt < 100; attempt++)); do
        if tcp_is_open; then
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            printf 'cc-workflow: Commit Cloud server exited during startup; see %s\n' "$SERVER_LOG" >&2
            tail -n 40 "$SERVER_LOG" >&2 || true
            return 1
        fi
        sleep 0.1
    done
    printf 'cc-workflow: timed out waiting for server on %s; see %s\n' "$SERVER_URL" "$SERVER_LOG" >&2
    return 1
}

start_server() {
    if tcp_is_open; then
        printf 'Server already listening at %s\n' "$SERVER_URL"
        return
    fi
    local args=(--host 127.0.0.1 --port "$PORT" --store-type "$STORE_TYPE")
    case "$STORE_TYPE" in
        sqlite)
            if [[ -z "$SQLITE_PATH" ]]; then SQLITE_PATH="$STATE_DIR/commit_cloud.db"; fi
            args+=(--sqlite-path "$SQLITE_PATH") ;;
        spanner)
            [[ -n "$SPANNER_DB" ]] || SPANNER_DB=${SPANNER_DATABASE:-}
            [[ -n "$SPANNER_DB" ]] || fail "Spanner requires --spanner-db or SPANNER_DATABASE"
            args+=(--spanner-db "$SPANNER_DB") ;;
        *)
            fail "unsupported store type: $STORE_TYPE" ;;
    esac

    if pid_is_process "$SERVER_PID_FILE" "$SERVER_BIN_FILE"; then
        fail "server PID is recorded but port $PORT is not accepting connections; inspect $SERVER_LOG"
    fi
    printf 'Starting Commit Cloud server: %s\n' "$SERVER_URL"
    nohup "$SERVER_BIN" "${args[@]}" >"$SERVER_LOG" 2>&1 </dev/null &
    local pid=$!
    printf '%s\n' "$pid" >"$SERVER_PID_FILE"
    printf '%s\n' "$SERVER_BIN" >"$SERVER_BIN_FILE"
    wait_for_server_port "$pid" || fail "server failed to start"
    printf 'Server ready (pid %s); log: %s\n' "$pid" "$SERVER_LOG"
}

start_vfs() {
    local workspace=$1 mount=$2 pid attempt
    if pid_is_process "$VFS_PID_FILE" "$VFS_BIN_FILE"; then
        if [[ -f "$MOUNT_FILE" && "$(cat "$MOUNT_FILE")" == "$mount" ]]; then
            printf 'VFS already running at %s\n' "$mount"
            return
        fi
        fail "another managed VFS process is running; stop it before selecting a different mountpoint"
    fi

    if [[ -n "$(find "$mount" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        fail "mountpoint must be empty: $mount"
    fi

    printf 'Starting VFS mount: %s -> %s\n' "$mount" "$workspace"
    nohup "$VFS_BIN" "$mount" "$workspace" >"$VFS_LOG" 2>&1 </dev/null &
    pid=$!
    printf '%s\n' "$pid" >"$VFS_PID_FILE"
    printf '%s\n' "$VFS_BIN" >"$VFS_BIN_FILE"
    printf '%s\n' "$mount" >"$MOUNT_FILE"
    printf '%s\n' "$workspace" >"$WORKSPACE_FILE"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [[ -d "$mount/commits" ]]; then
            printf 'VFS ready (pid %s); log: %s\n' "$pid" "$VFS_LOG"
            return
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            printf 'cc-workflow: jjfsd exited during startup; see %s\n' "$VFS_LOG" >&2
            tail -n 40 "$VFS_LOG" >&2 || true
            fail "VFS mount failed"
        fi
        sleep 0.1
    done
    tail -n 40 "$VFS_LOG" >&2 || true
    fail "timed out waiting for VFS mount at $mount"
}

stop_process() {
    local name=$1 pid_file=$2 bin_file=$3 pid attempt
    if ! pid_is_process "$pid_file" "$bin_file"; then
        rm -f "$pid_file" "$bin_file"
        return 0
    fi
    pid=$(cat "$pid_file")
    printf 'Stopping %s (pid %s)\n' "$name" "$pid"
    kill -TERM "$pid"
    for ((attempt = 0; attempt < 50; attempt++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$pid_file" "$bin_file"
            return 0
        fi
        sleep 0.1
    done
    printf 'cc-workflow: %s did not stop; inspect its log before stopping it manually\n' "$name" >&2
    return 1
}

case "$ACTION" in
    up)
        [[ -n "$WORKSPACE" ]] || fail "up requires --workspace"
        [[ "$MODE" == native || "$MODE" == vfs ]] || fail "mode must be native or vfs"
        if [[ "$MODE" == vfs ]]; then
            [[ -n "$MOUNT" ]] || fail "vfs mode requires --mount"
        else
            [[ -z "$MOUNT" ]] || fail "--mount is only used with --mode vfs"
            ((CLEAR_WORKING_COPY == 0)) || fail "--clear-working-copy is only available in vfs mode"
            if pid_is_process "$VFS_PID_FILE" "$VFS_BIN_FILE"; then
                fail "stop the managed VFS mount before starting native mode"
            fi
        fi
        [[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT > 0 && PORT <= 65535)) || fail "port must be in the range 1-65535"
        mkdir -p "$WORKSPACE"
        WORKSPACE=$(cd -P "$WORKSPACE" && pwd)
        if [[ "$MODE" == vfs ]]; then
            mkdir -p "$MOUNT"
            MOUNT=$(cd -P "$MOUNT" && pwd)
            [[ "$WORKSPACE" != "$MOUNT" ]] || fail "workspace and mountpoint must be different directories"
            case "$WORKSPACE/" in
                "$MOUNT/"*) fail "workspace cannot be inside the VFS mountpoint" ;;
            esac
            case "$MOUNT/" in
                "$WORKSPACE/"*) fail "VFS mountpoint cannot be inside the workspace" ;;
            esac
        fi
        if [[ ! -d "$WORKSPACE/.jj" && -z "$PROJECT_ID" ]]; then
            fail "new workspace needs --project-id"
        fi
        if [[ ! -d "$WORKSPACE/.jj" && $REUSE_EXISTING_WORKSPACE == 1 ]]; then
            fail "--reuse-existing-workspace requires an initialized workspace"
        fi
        if [[ "$MODE" == native && -d "$WORKSPACE/.jj" && $REUSE_EXISTING_WORKSPACE == 0 ]]; then
            if [[ ! -f "$MODE_FILE" || "$(cat "$MODE_FILE")" != native || ! -f "$WORKSPACE_FILE" || "$(cat "$WORKSPACE_FILE")" != "$WORKSPACE" ]]; then
                fail "native mode needs a new folder; pass --reuse-existing-workspace only if this workspace was initialized with --working-copy-type local"
            fi
        fi
        if [[ "$MODE" == vfs && $REUSE_EXISTING_WORKSPACE == 1 ]]; then
            fail "--reuse-existing-workspace is only for an existing native workspace"
        fi
        if [[ "$MODE" == vfs ]]; then
            if pid_is_process "$VFS_PID_FILE" "$VFS_BIN_FILE"; then
                if [[ ! -f "$MOUNT_FILE" || "$(cat "$MOUNT_FILE")" != "$MOUNT" || ! -f "$WORKSPACE_FILE" || "$(cat "$WORKSPACE_FILE")" != "$WORKSPACE" ]]; then
                    fail "a managed VFS mount is already running for a different workspace or mountpoint"
                fi
                if ((CLEAR_WORKING_COPY)); then
                    fail "stop the existing VFS mount before clearing the working copy"
                fi
            elif [[ -n "$(find "$MOUNT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
                fail "mountpoint must be empty: $MOUNT"
            fi
        fi

        TARGET_DIR="$REPO_ROOT/target/$PROFILE"
        SERVER_BIN=$(resolve_binary "${JJ_CC_SERVER_BIN:-}" "$TARGET_DIR/jj-cc-server" jj-cc-server)
        JJ_BIN=$(resolve_binary "${JJ_CC_JJ_BIN:-}" "$TARGET_DIR/jj" jj)
        DAEMON_BIN=$(resolve_binary "${JJ_CC_DAEMON_BIN:-}" "$TARGET_DIR/jj-cc-daemon" jj-cc-daemon)
        if [[ "$MODE" == vfs ]]; then
            VFS_BIN=$(resolve_binary "${JJ_CC_VFS_BIN:-}" "$REPO_ROOT/../jj-vfs-poc/target/$PROFILE/jjfsd" jjfsd)
        fi
        export JJ_CC_DAEMON_BIN="$DAEMON_BIN"

        SERVER_URL="http://127.0.0.1:$PORT"
        printf '%s\n' "$PORT" >"$PORT_FILE"
        start_server
        if [[ ! -d "$WORKSPACE/.jj" ]]; then
            printf 'Initializing Commit Cloud workspace: %s\n' "$WORKSPACE"
            init_args=(cc init --server "$SERVER_URL" --project-id "$PROJECT_ID")
            if [[ "$MODE" == native ]]; then
                init_args+=(--working-copy-type local)
            fi
            "$JJ_BIN" "${init_args[@]}" "$WORKSPACE"
        fi
        if ((CLEAR_WORKING_COPY)); then
            printf 'Clearing the workspace working copy with jj sparse set --clear\n'
            (cd "$WORKSPACE" && "$JJ_BIN" sparse set --clear)
        fi
        if [[ "$MODE" == vfs ]]; then
            start_vfs "$WORKSPACE" "$MOUNT"
            printf '\nWorkflow is running. Browse the virtual tree under %s.\n' "$MOUNT"
            printf 'VFS mount: %s\n' "$MOUNT"
        else
            printf '\nNative filesystem workflow is running in %s.\n' "$WORKSPACE"
        fi
        printf '%s\n' "$MODE" >"$MODE_FILE"
        printf '%s\n' "$WORKSPACE" >"$WORKSPACE_FILE"
        printf 'Server: %s\nWorkspace: %s\nState and logs: %s\n' "$SERVER_URL" "$WORKSPACE" "$STATE_DIR"
        printf 'The jj client daemon starts on its first Commit Cloud RPC.\n' ;;
    status)
        SERVER_URL="http://127.0.0.1:$PORT"
        if tcp_is_open; then printf 'Server: listening at %s\n' "$SERVER_URL"; else printf 'Server: stopped at %s\n' "$SERVER_URL"; fi
        if pid_is_process "$VFS_PID_FILE" "$VFS_BIN_FILE"; then
            printf 'VFS: running at %s (pid %s)\n' "$(cat "$MOUNT_FILE" 2>/dev/null || printf unknown)" "$(cat "$VFS_PID_FILE")"
        else
            printf 'VFS: stopped\n'
        fi
        if [[ -f "$MODE_FILE" ]]; then printf 'Mode: %s\n' "$(cat "$MODE_FILE")"; fi
        if [[ -f "$WORKSPACE_FILE" ]]; then printf 'Workspace: %s\n' "$(cat "$WORKSPACE_FILE")"; fi
        printf 'State and logs: %s\n' "$STATE_DIR" ;;
    down)
        local_mount=$(cat "$MOUNT_FILE" 2>/dev/null || true)
        stop_process jjfsd "$VFS_PID_FILE" "$VFS_BIN_FILE"
        stop_process jj-cc-server "$SERVER_PID_FILE" "$SERVER_BIN_FILE"
        rm -f "$MOUNT_FILE" "$WORKSPACE_FILE" "$MODE_FILE" "$PORT_FILE"
        if [[ -n "$local_mount" ]]; then printf 'Stopped managed components; mount directory remains at %s\n' "$local_mount"; else printf 'Stopped managed components\n'; fi ;;
    help|-h|--help)
        usage ;;
    *)
        usage >&2
        fail "unknown action: $ACTION" ;;
esac
