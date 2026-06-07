#!/bin/bash
# Claude Code on the web — SessionStart hook.
# Installs the Foundry toolchain (forge/cast/anvil) and the pinned solc, which the
# environment's network allowlist blocks via the usual installers (api.github.com and
# binaries.soliditylang.org are not allowlisted) but permits via GitHub release assets.
# Web sessions only — local Claude Code sessions exit immediately (no slowdown).
set -uo pipefail

# Only run in remote (web) sessions.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
FOUNDRY_BIN="$HOME/.foundry/bin"

# Persist Foundry on PATH for this session's shells.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$FOUNDRY_BIN:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi
export PATH="$FOUNDRY_BIN:$PATH"

case "$(uname -m)" in
  x86_64|amd64) FARCH=amd64 ;;
  aarch64|arm64) FARCH=arm64 ;;
  *) FARCH=amd64 ;;
esac

# 1. Foundry (forge/cast/anvil) — direct release-asset download (foundryup's API call is blocked).
if ! command -v forge >/dev/null 2>&1; then
  echo "session-start: installing Foundry ($FARCH)..." >&2
  mkdir -p "$FOUNDRY_BIN"
  if curl -fsSL -m 180 -o /tmp/foundry.tar.gz \
      "https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_linux_${FARCH}.tar.gz"; then
    tar -xzf /tmp/foundry.tar.gz -C "$FOUNDRY_BIN" && rm -f /tmp/foundry.tar.gz
  else
    echo "session-start: WARNING - Foundry download failed; forge unavailable" >&2
  fi
fi

# 2. solc pinned in foundry.toml — fetch from GitHub into svm's path (its default source is blocked).
SOLC_VERSION="$(grep -E '^[[:space:]]*solc_version' "$PROJECT_DIR/foundry.toml" 2>/dev/null \
  | head -1 | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')"
SOLC_VERSION="${SOLC_VERSION:-0.8.34}"
SOLC_PATH="$HOME/.svm/$SOLC_VERSION/solc-$SOLC_VERSION"
if [ ! -x "$SOLC_PATH" ]; then
  echo "session-start: installing solc $SOLC_VERSION..." >&2
  mkdir -p "$HOME/.svm/$SOLC_VERSION"
  if curl -fsSL -m 120 -o "$SOLC_PATH" \
      "https://github.com/ethereum/solidity/releases/download/v${SOLC_VERSION}/solc-static-linux"; then
    chmod +x "$SOLC_PATH"
  else
    echo "session-start: WARNING - solc $SOLC_VERSION download failed" >&2
    rm -f "$SOLC_PATH"
  fi
fi

# 3. Git submodules (forge-std, openzeppelin-contracts) for a fresh clone.
if [ -f "$PROJECT_DIR/.gitmodules" ]; then
  git -C "$PROJECT_DIR" submodule update --init --recursive >/dev/null 2>&1 \
    || echo "session-start: WARNING - submodule update failed" >&2
fi

echo "session-start: foundry toolchain ready" >&2
exit 0
