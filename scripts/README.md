# Toolchain setup for Claude Code on the web

This environment's network allowlist blocks the usual Foundry/solc installers
(`api.github.com` and `binaries.soliditylang.org` are not allowlisted), but GitHub
**release assets** are. So we install `forge`/`cast`/`anvil` and the `foundry.toml`-pinned
`solc` by downloading the release tarballs directly.

## Environment "Setup script" field (recommended)

The **Setup script** field runs **before the repo is cloned**, so it can't call
`scripts/install-foundry.sh`. Paste this self-contained snippet instead. Its output is
cached in the environment snapshot, so later sessions start with the toolchain already on
disk (no per-session re-download).

```bash
set -euo pipefail
case "$(uname -m)" in x86_64|amd64) A=amd64;; aarch64|arm64) A=arm64;; *) A=amd64;; esac
if ! command -v forge >/dev/null 2>&1; then
  curl -fsSL -m 180 -o /tmp/foundry.tgz \
    "https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_linux_${A}.tar.gz"
  tar -xzf /tmp/foundry.tgz -C /usr/local/bin forge cast anvil chisel
  rm -f /tmp/foundry.tgz
fi
S=0.8.34   # keep in sync with foundry.toml solc_version
if [ ! -x "$HOME/.svm/$S/solc-$S" ]; then
  mkdir -p "$HOME/.svm/$S"
  curl -fsSL -m 120 -o "$HOME/.svm/$S/solc-$S" \
    "https://github.com/ethereum/solidity/releases/download/v$S/solc-static-linux"
  chmod +x "$HOME/.svm/$S/solc-$S"
fi
forge --version
```

(`solc` goes into svm's path so `forge` auto-detects it; `forge` fetches the `lib/`
submodules itself on first build via the allowlisted `github.com`/`codeload.github.com`.)

## Inside a session

The repo is cloned by then, so just run the committed script:

```bash
bash scripts/install-foundry.sh
```

## Running the Base mainnet fork tests

Set `BASE_RPC_URL` (and allowlist its host, e.g. `api.developer.coinbase.com`) in the
environment, then:

```bash
forge test --match-contract InProcessFork -vvv
```
