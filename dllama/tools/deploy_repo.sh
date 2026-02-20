#!/usr/bin/env bash
# deploy_repo.sh — Build & sync ~/distributed-llama from rock0 to all worker nodes
#
# Usage: ./deploy_repo.sh [--build] [--clean] [nodes_file]
#
#   --build        Compile before syncing (runs BUILD_CMD in REPO_DIR)
#   --clean        Run CLEAN_CMD before building (implies --build)
#
# All tunables can be overridden via environment variables.
set -euo pipefail

# ── Tunables (override via env) ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${NODES_FILE:=$SCRIPT_DIR/../nodes.txt}"
: "${REPO_DIR:=$HOME/distributed-llama}"
: "${BUILD_CMD:=make dllama}"
: "${CLEAN_CMD:=make clean}"
: "${RSYNC_EXCLUDE:=.git}"
LOCAL_HOST="$(hostname)"
RSYNC_OPTS=(-az --delete)
USER="$(whoami)"

# ── Parse flags ──────────────────────────────────────────────────────────────
DO_BUILD=false
DO_CLEAN=false
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --build)      DO_BUILD=true ;;
    --clean)      DO_CLEAN=true; DO_BUILD=true ;;
    *)            POSITIONAL+=("$arg") ;;
  esac
done
# First positional arg overrides nodes file
[[ ${#POSITIONAL[@]} -gt 0 ]] && NODES_FILE="${POSITIONAL[0]}"

# Build rsync excludes from space-separated list
IFS=' ' read -ra EXCLUDES <<< "$RSYNC_EXCLUDE"
for pat in "${EXCLUDES[@]}"; do
  RSYNC_OPTS+=(--exclude="$pat")
done

# ── Validate ─────────────────────────────────────────────────────────────────
if [[ ! -d "$REPO_DIR" ]]; then
  echo "ERROR: Source repo not found at $REPO_DIR" >&2
  exit 1
fi

if [[ ! -f "$NODES_FILE" ]]; then
  echo "ERROR: Nodes file not found at $NODES_FILE" >&2
  exit 1
fi

# ── Build (optional)
if $DO_BUILD; then
  echo "==> Building in $REPO_DIR ..."
  if $DO_CLEAN; then
    echo "    clean: $CLEAN_CMD"
    (cd "$REPO_DIR" && eval "$CLEAN_CMD")
  fi
  echo "    build: $BUILD_CMD"
  (cd "$REPO_DIR" && eval "$BUILD_CMD")
  echo "==> Build complete."
fi

# ── Read target nodes ────────────────
mapfile -t NODES < <(
  grep -vE '^\s*(#|$)' "$NODES_FILE" | sed 's/[[:space:]]//g' |
  grep -vxF "$LOCAL_HOST"
)

if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "No remote nodes found in $NODES_FILE (local host: $LOCAL_HOST)"
  exit 0
fi

echo "==> Syncing $REPO_DIR to ${#NODES[@]} nodes (excluding $LOCAL_HOST)..."

# ── Rsync in parallel ────────────────────────────────────────────────────────
declare -A PIDS
for node in "${NODES[@]}"; do
  echo "    -> $node"
  rsync "${RSYNC_OPTS[@]}" "$REPO_DIR/" "${USER}@${node}:${REPO_DIR}/" &
  PIDS[$node]=$!
done

# ── Wait & collect results ───────────────────────────────────────────────────
FAIL=0
for node in "${NODES[@]}"; do
  if wait "${PIDS[$node]}"; then
    echo "  [OK]   $node"
  else
    echo "  [FAIL] $node" >&2
    ((FAIL++))
  fi
done

# ── Start all enabled dllama-worker instances for each user/port ────────────
# Read user/port list from Ansible defaults
USERS_FILE="$SCRIPT_DIR/../../ansible/roles/dllama/defaults/main.yml"
declare -A USER_PORTS
if [[ -f "$USERS_FILE" ]]; then
  while IFS= read -r line; do
    if [[ $line =~ username:\ ([^,]+),\ port:\ ([0-9]+) ]]; then
      user="${BASH_REMATCH[1]}"
      port="${BASH_REMATCH[2]}"
      USER_PORTS[$user]=$port
    fi
  done < <(grep -E 'username:|port:' "$USERS_FILE" | paste - -)
fi

echo "==> Ensuring dllama-worker instances are started for each user/port..."
for node in "${NODES[@]}"; do
  for user in "${!USER_PORTS[@]}"; do
    port="${USER_PORTS[$user]}"
    ssh "${USER}@${node}" "systemctl --user daemon-reload; systemctl --user start dllama-worker@${port}.service" &
  done
  wait
  echo "  [OK]   $node workers started"
done
# Local host
for user in "${!USER_PORTS[@]}"; do
  port="${USER_PORTS[$user]}"
  systemctl --user daemon-reload
  systemctl --user start dllama-worker@${port}.service || true
done

echo "==> Done. ${#NODES[@]} nodes targeted, $FAIL sync failures."
exit "$FAIL"
