from pathlib import Path
import zipfile, textwrap, os, json, shutil, subprocess

root = Path("/mnt/data/trusttunnel-railway-easy")
root.mkdir(parents=True, exist_ok=True)

files = {}

files["Dockerfile"] = r'''FROM debian:bookworm-slim

ARG TT_VERSION=latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tar iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Download the official TrustTunnel prebuilt release.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) TT_ARCH="x86_64" ;; \
      arm64) TT_ARCH="aarch64" ;; \
      *) echo "Unsupported architecture: $(dpkg --print-architecture)"; exit 1 ;; \
    esac; \
    if [ "$TT_VERSION" = "latest" ]; then \
      TT_VERSION="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
        https://github.com/TrustTunnel/TrustTunnel/releases/latest \
        | sed -E 's#^.*/tag/v?##')"; \
    fi; \
    echo "Installing TrustTunnel v${TT_VERSION} for ${TT_ARCH}"; \
    RELEASE_FILE="trusttunnel-v${TT_VERSION}-linux-${TT_ARCH}.tar.gz"; \
    curl -fsSL \
      "https://github.com/TrustTunnel/TrustTunnel/releases/download/v${TT_VERSION}/${RELEASE_FILE}" \
      -o /tmp/trusttunnel.tar.gz; \
    mkdir -p /tmp/trusttunnel-release; \
    tar -xzf /tmp/trusttunnel.tar.gz -C /tmp/trusttunnel-release; \
    cp /tmp/trusttunnel-release/*/trusttunnel_endpoint /usr/local/bin/; \
    cp /tmp/trusttunnel-release/*/setup_wizard /usr/local/bin/; \
    chmod +x /usr/local/bin/trusttunnel_endpoint /usr/local/bin/setup_wizard; \
    rm -rf /tmp/trusttunnel.tar.gz /tmp/trusttunnel-release

COPY --chmod=755 entrypoint.sh /scripts/entrypoint.sh
COPY --chmod=755 get-client.sh /scripts/get-client.sh

WORKDIR /trusttunnel_endpoint
VOLUME ["/trusttunnel_endpoint"]

ENTRYPOINT ["/scripts/entrypoint.sh"]
'''

files["entrypoint.sh"] = r'''#!/bin/sh
set -eu

DATA_DIR="/trusttunnel_endpoint"
cd "$DATA_DIR"

INTERNAL_PORT="${TT_LISTEN_PORT:-${RAILWAY_TCP_APPLICATION_PORT:-8443}}"
PUBLIC_HOST="${TT_HOSTNAME:-${RAILWAY_TCP_PROXY_DOMAIN:-}}"

if [ -z "${TT_CREDENTIALS:-}" ]; then
  echo "ERROR: TT_CREDENTIALS is missing."
  echo "Set it to username:password in Railway Variables."
  exit 1
fi

if [ -z "$PUBLIC_HOST" ]; then
  echo "ERROR: No public TrustTunnel hostname is available."
  echo "Create a Railway TCP Proxy pointing to internal port ${INTERNAL_PORT}, then redeploy."
  echo "Or set TT_HOSTNAME manually."
  exit 1
fi

if [ ! -f credentials.toml ] || [ ! -f vpn.toml ] || [ ! -f hosts.toml ]; then
  echo "First start: generating TrustTunnel configuration..."
  setup_wizard \
    -m non-interactive \
    -a "0.0.0.0:${INTERNAL_PORT}" \
    -c "$TT_CREDENTIALS" \
    -n "$PUBLIC_HOST" \
    --cert-type self-signed \
    --lib-settings vpn.toml \
    --hosts-settings hosts.toml
fi

# Keep the internal listen port aligned with Railway's TCP proxy.
if grep -q '^listen_address[[:space:]]*=' vpn.toml; then
  sed -i -E \
    "s#^listen_address[[:space:]]*=.*#listen_address = \"0.0.0.0:${INTERNAL_PORT}\"#" \
    vpn.toml
fi

# Railway exposes raw TCP but not public UDP. Remove the QUIC listener so
# clients don't try HTTP/3/QUIC against an unreachable UDP endpoint.
if grep -q '^\[listen_protocols\.quic\]$' vpn.toml; then
  echo "Railway mode: disabling QUIC/HTTP3 listener (TCP HTTP/1.1 + HTTP/2 remain enabled)."
  awk '
    /^\[listen_protocols\.quic\]$/ { skipping=1; next }
    skipping && /^\[/ { skipping=0 }
    !skipping { print }
  ' vpn.toml > vpn.toml.tmp
  mv vpn.toml.tmp vpn.toml
fi

echo
echo "============================================================"
echo " TrustTunnel is starting"
echo " Internal address : 0.0.0.0:${INTERNAL_PORT}"
if [ -n "${RAILWAY_TCP_PROXY_PORT:-}" ]; then
  echo " Public address   : ${PUBLIC_HOST}:${RAILWAY_TCP_PROXY_PORT}"
else
  echo " Public hostname  : ${PUBLIC_HOST}"
fi
echo " To get your tt:// client link:"
echo "   railway ssh -- /scripts/get-client.sh"
echo "============================================================"
echo

exec trusttunnel_endpoint vpn.toml hosts.toml
'''

files["get-client.sh"] = r'''#!/bin/sh
set -eu

cd /trusttunnel_endpoint

if [ ! -f vpn.toml ] || [ ! -f hosts.toml ]; then
  echo "ERROR: TrustTunnel configuration has not been generated yet." >&2
  exit 1
fi

PUBLIC_HOST="${TT_HOSTNAME:-${RAILWAY_TCP_PROXY_DOMAIN:-}}"
PUBLIC_PORT="${TT_PUBLIC_PORT:-${RAILWAY_TCP_PROXY_PORT:-}}"

if [ -z "$PUBLIC_HOST" ] || [ -z "$PUBLIC_PORT" ]; then
  echo "ERROR: Railway TCP proxy hostname/port is not available." >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  CLIENT_NAME="$1"
elif [ -n "${TT_CLIENT_NAME:-}" ]; then
  CLIENT_NAME="$TT_CLIENT_NAME"
elif [ -n "${TT_CREDENTIALS:-}" ]; then
  CLIENT_NAME="${TT_CREDENTIALS%%:*}"
else
  echo "ERROR: Give the client username as an argument:" >&2
  echo "  /scripts/get-client.sh USERNAME" >&2
  exit 1
fi

exec trusttunnel_endpoint vpn.toml hosts.toml \
  -c "$CLIENT_NAME" \
  -a "${PUBLIC_HOST}:${PUBLIC_PORT}"
'''

files["setup-railway.sh"] = r'''#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-trusttunnel}"
INTERNAL_PORT="${INTERNAL_PORT:-8443}"
VOLUME_PATH="/trusttunnel_endpoint"

if ! command -v railway >/dev/null 2>&1; then
  echo "Railway CLI is not installed."
  echo "Install it first:"
  echo "  bash <(curl -fsSL railway.com/install.sh)"
  exit 1
fi

if ! railway whoami >/dev/null 2>&1; then
  echo "Login to Railway first:"
  railway login
fi

echo
read -r -p "TrustTunnel username [user]: " TT_USER
TT_USER="${TT_USER:-user}"

while true; do
  read -r -s -p "TrustTunnel password: " TT_PASS
  echo
  if [ -n "$TT_PASS" ]; then
    break
  fi
  echo "Password cannot be empty."
done

# Use the linked project if there is one; otherwise create a new project.
if ! railway status >/dev/null 2>&1; then
  echo "Creating Railway project 'trusttunnel'..."
  railway init --name trusttunnel
else
  echo "Using the Railway project already linked to this folder."
fi

echo "Creating service '${SERVICE_NAME}'..."
railway add \
  --service "$SERVICE_NAME" \
  --variables "TT_CREDENTIALS=${TT_USER}:${TT_PASS}"

# railway add links the new service to the current directory.
echo "Adding persistent TrustTunnel volume..."
railway volume add --mount-path "$VOLUME_PATH"

echo "Creating Railway TCP proxy on internal port ${INTERNAL_PORT}..."
railway tcp-proxy create --port "$INTERNAL_PORT"

echo "Deploying..."
railway up --detach

cat <<'EOF'

Deployment started.

When the service is healthy, get your TrustTunnel client link with:

  railway ssh -- /scripts/get-client.sh

To see logs:

  railway logs -n 100

To open the Railway dashboard:

  railway open

IMPORTANT:
- This Railway deployment uses TCP (HTTP/1.1 / HTTP/2).
- QUIC/HTTP3 is automatically disabled because Railway does not expose public UDP.
- Keep the /trusttunnel_endpoint volume attached or your generated config will be lost.
EOF
'''

files["README.md"] = r'''# Easy TrustTunnel on Railway

This package deploys the official **TrustTunnel** endpoint to Railway with the
minimum setup possible.

It automatically:

- downloads the latest official TrustTunnel release during the Docker build;
- creates the TrustTunnel configuration on first boot;
- uses Railway's TCP Proxy hostname and port;
- listens internally on port `8443`;
- disables the QUIC/HTTP3 listener because Railway does not expose public UDP;
- stores configuration and certificates under `/trusttunnel_endpoint`;
- includes a helper that prints your `tt://` client link.

## Fastest installation

### 1. Install Railway CLI

Linux/macOS/WSL:

```bash
bash <(curl -fsSL railway.com/install.sh)
railway login
