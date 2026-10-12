#!/usr/bin/env bash
#
# Install Foundry with a single command, without foundryup.
#
# Why not foundryup: the 108 MB release it downloads comes off GitHub's CDN, which
# measured ~33 KB/s from mainland China and therefore always times out. This script
# tries a direct download first and falls back to a mirror when that fails.
#
#   bash scripts/install-foundry-cn.sh
#
# Environment variables you can override:
#   FOUNDRY_VERSION    pin a version, e.g. v1.8.3 (default: look up the latest, fall back if not found)
#   MIRROR_PREFIX      mirror prefix, defaults to https://gh-proxy.com/
#   FOUNDRY_BIN_DIR    install directory, defaults to ~/.foundry/bin
#
set -euo pipefail

FOUNDRY_VERSION="${FOUNDRY_VERSION:-}"
MIRROR_PREFIX="${MIRROR_PREFIX:-https://gh-proxy.com/}"
BIN_DIR="${FOUNDRY_BIN_DIR:-$HOME/.foundry/bin}"
PINNED_FALLBACK="v1.8.3"

log() { printf '\033[36m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die() {
	printf '\033[31m%s\033[0m\n' "$*" >&2
	exit 1
}

for c in curl tar uname; do
	command -v "$c" >/dev/null 2>&1 || die "missing ${c}, please install it first."
done

# ---------- 1. Detect the platform ----------
case "$(uname -s)/$(uname -m)" in
Darwin/arm64) target="darwin_arm64" ;;
Darwin/x86_64) target="darwin_amd64" ;;
Linux/x86_64) target="linux_amd64" ;;
Linux/aarch64 | Linux/arm64) target="linux_arm64" ;;
*)
	die "unsupported platform: $(uname -s)/$(uname -m). Windows users should run this script inside WSL2."
	;;
esac
log "platform -> $target"

# ---------- 2. Determine the version ----------
if [ -z "$FOUNDRY_VERSION" ]; then
	log "looking up the latest version (falling back to ${PINNED_FALLBACK} if that fails)"
	tag="$(curl -fsSL --max-time 15 \
		https://api.github.com/repos/foundry-rs/foundry/releases/latest 2>/dev/null |
		grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
	FOUNDRY_VERSION="${tag:-$PINNED_FALLBACK}"
fi
log "version -> $FOUNDRY_VERSION"

# ---------- 3. Download: fall back to a mirror when the direct source fails ----------
asset="https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_VERSION}/foundry_${FOUNDRY_VERSION}_${target}.tar.gz"
candidates=("$asset" "${MIRROR_PREFIX%/}/$asset")

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

got=""
for url in "${candidates[@]}"; do
	log "trying $url"
	# --max-time is essential: a direct GitHub download from mainland China may not
	# "fail" but rather crawl forever. Without a ceiling it hangs here and the mirror
	# never gets its turn. If 108 MB will not arrive in 180 seconds this route is
	# slower than the mirror, so give up and move on.
	if curl -fL --connect-timeout 20 --retry 2 --max-time 180 --progress-bar \
		-o "$tmp/foundry.tar.gz" "$url"; then
		got="$url"
		break
	fi
	warn "that source did not work, trying the next one"
done
[ -n "$got" ] ||
	die "every download source failed. Try another mirror: MIRROR_PREFIX=<mirror prefix>/ bash $0"

# ---------- 4. Install ----------
mkdir -p "$BIN_DIR" "$tmp/x"
tar -xzf "$tmp/foundry.tar.gz" -C "$tmp/x"
for b in forge cast anvil chisel; do
	[ -f "$tmp/x/$b" ] || die "the archive has no ${b}; the download may be incomplete"
	install -m 0755 "$tmp/x/$b" "$BIN_DIR/$b"
done
log "installed to $BIN_DIR"

# ---------- 5. Verify + PATH hint ----------
echo
"$BIN_DIR/forge" --version | head -2
echo

case ":$PATH:" in
*":$BIN_DIR:"*) ;;
*)
	warn "add the following line to ~/.zshrc or ~/.bashrc, then reopen your terminal:"
	warn "  export PATH=\"\$PATH:$BIN_DIR\""
	;;
esac

log "done. Next step: bash scripts/doctor.sh"
