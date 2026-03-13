#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

: "${REMOTE_HOST:?Set REMOTE_HOST to the control plane server host.}"
: "${REMOTE_USER:?Set REMOTE_USER to the control plane server user.}"

REMOTE_PORT="${REMOTE_PORT:-22}"
SSH_IDENTITY_FILE="${SSH_IDENTITY_FILE:-$HOME/.ssh/id_ed25519}"
REMOTE_DIR="${REMOTE_DIR:-/home/$REMOTE_USER/Orchard}"
REMOTE_DATA_DIR="${REMOTE_DATA_DIR:-$REMOTE_DIR/data}"
REMOTE_CONFIG_DIR="${REMOTE_CONFIG_DIR:-/home/$REMOTE_USER/orchard-config}"
REMOTE_ENV_FILE="${REMOTE_ENV_FILE:-$REMOTE_CONFIG_DIR/control-plane.env}"
LEGACY_ENV_FILE="${LEGACY_ENV_FILE:-$REMOTE_DIR/control-plane.env}"
IMAGE_NAME="${IMAGE_NAME:-orchard-control-plane:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-orchard-control-plane}"
HOST_PORT="${HOST_PORT:-18080}"

REMOTE_TARGET="$REMOTE_USER@$REMOTE_HOST"
SSH_CMD=(ssh -i "$SSH_IDENTITY_FILE" -p "$REMOTE_PORT" "$REMOTE_TARGET")
RSYNC_SSH="ssh -i $SSH_IDENTITY_FILE -p $REMOTE_PORT"

echo "Checking remote env file..."
if ! "${SSH_CMD[@]}" "test -f '$REMOTE_ENV_FILE' || test -f '$LEGACY_ENV_FILE'"; then
    cat >&2 <<EOF
Missing remote env file.

Create one from:
  $REPO_ROOT/deploy/control-plane.env.example

Expected remote path:
  $REMOTE_ENV_FILE
EOF
    exit 1
fi

echo "Syncing source to $REMOTE_TARGET:$REMOTE_DIR ..."
rsync -az --delete \
    --exclude '.build' \
    --exclude '.git' \
    --exclude '.swiftpm' \
    --exclude 'DerivedData' \
    --exclude 'data' \
    --exclude 'control-plane.env' \
    -e "$RSYNC_SSH" \
    "$REPO_ROOT/" "$REMOTE_TARGET:$REMOTE_DIR/"

echo "Building and restarting $CONTAINER_NAME ..."
"${SSH_CMD[@]}" "
set -euo pipefail
mkdir -p '$REMOTE_CONFIG_DIR' '$REMOTE_DATA_DIR'
if [ ! -f '$REMOTE_ENV_FILE' ] && [ -f '$LEGACY_ENV_FILE' ]; then
    mv '$LEGACY_ENV_FILE' '$REMOTE_ENV_FILE'
    chmod 600 '$REMOTE_ENV_FILE'
fi
cd '$REMOTE_DIR'
docker build -t '$IMAGE_NAME' -f Dockerfile.controlplane .
docker rm -f '$CONTAINER_NAME' >/dev/null 2>&1 || true
docker run -d \
    --name '$CONTAINER_NAME' \
    --restart unless-stopped \
    --env-file '$REMOTE_ENV_FILE' \
    -v '$REMOTE_DATA_DIR:/data' \
    -p '$HOST_PORT:8080' \
    '$IMAGE_NAME' >/dev/null
sleep 3
curl -fsS 'http://127.0.0.1:$HOST_PORT/health'
"
