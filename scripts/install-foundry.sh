#!/bin/bash
# Setup script for Claude Code on the web.
#
# Installs the Foundry toolchain (forge/cast/anvil) and the foundry.toml-pinned solc from
# GitHub release assets. The usual installers are blocked by this environment's network
# allowlist (api.github.com and binaries.soliditylang.org aren't allowlisted), but GitHub
# release assets (release-assets.githubusercontent.com) ARE, so we fetch directly.
#
# Use this file FROM INSIDE a session (the repo is cloned by then):  bash scripts/install-foundry.sh
#
# NOTE: the environment's "Setup script" field runs BEFORE the repo is cloned, so it cannot
# reference this file. For that field, paste the self-contained snippet from scripts/README.md
# (same install, no repo dependency) — its output is cached so later sessions skip re-downloading.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
BIN_DIR="${FOUNDRY_BIN_DIR:-/usr/local/bin}" # on PATH + cached; override for testing
export PATH="$BIN_DIR:$PATH"

case "$(uname -m)" in
  x86_64 | amd64) FARCH=amd64 ;;
  aarch64 | arm64) FARCH=arm64 ;;
  *) FARCH=amd64 ;;
esac

# 1. Foundry (forge/cast/anvil/chisel) — direct release-asset download into a PATH dir.
if ! command -v forge >/dev/null 2>&1; then
  echo "setup: installing Foundry ($FARCH) -> $BIN_DIR"
  mkdir -p "$BIN_DIR"
  curl -fsSL -m 180 -o /tmp/foundry.tar.gz \
    "https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_linux_${FARCH}.tar.gz"
  tar -xzf /tmp/foundry.tar.gz -C "$BIN_DIR" forge cast anvil chisel
  rm -f /tmp/foundry.tar.gz
fi

# 2. solc pinned in foundry.toml -> GitHub static binary into svm's path (forge auto-detects it).
SOLC_VERSION="$(grep -E '^[[:space:]]*solc_version' "$PROJECT_DIR/foundry.toml" 2>/dev/null \
  | head -1 | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')"
SOLC_VERSION="${SOLC_VERSION:-0.8.34}"
SOLC_PATH="$HOME/.svm/$SOLC_VERSION/solc-$SOLC_VERSION"
if [ ! -x "$SOLC_PATH" ]; then
  echo "setup: installing solc $SOLC_VERSION"
  mkdir -p "$HOME/.svm/$SOLC_VERSION"
  curl -fsSL -m 120 -o "$SOLC_PATH" \
    "https://github.com/ethereum/solidity/releases/download/v${SOLC_VERSION}/solc-static-linux"
  chmod +x "$SOLC_PATH"
fi

# 3. Submodules (forge-std, openzeppelin-contracts).
if [ -f "$PROJECT_DIR/.gitmodules" ]; then
  git -C "$PROJECT_DIR" submodule update --init --recursive
fi

echo "setup: ready — $(forge --version | head -1)"
