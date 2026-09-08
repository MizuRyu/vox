#!/usr/bin/env bash
# Install or update Vox from the latest GitHub Release.
#   curl -fsSL https://raw.githubusercontent.com/MizuRyu/vox/main/scripts/install.sh | bash
set -euo pipefail

REPO="MizuRyu/vox"
APP="/Applications/Vox.app"

[ "$(uname -m)" = "arm64" ] || { echo "error: Vox requires Apple Silicon (arm64)" >&2; exit 1; }
if pgrep -x Vox >/dev/null; then
  echo "error: Vox is running. Quit it from the menu bar (Vox → Vox を終了) and run again." >&2
  exit 1
fi

echo "==> Resolving latest release..."
# Follow the /releases/latest redirect instead of the API (no rate limit).
tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")
tag=${tag##*/}                                  # e.g. v1.0.0
version=${tag#v}
[ "$tag" != "latest" ] || { echo "error: could not resolve the latest release tag" >&2; exit 1; }
base_url="https://github.com/$REPO/releases/download/$tag"
dmg_name="Vox-${version}.dmg"

tmp=$(mktemp -d)
mount_point=""
trap 'rm -rf "$tmp"; [ -n "$mount_point" ] && hdiutil detach "$mount_point" -quiet || true' EXIT

echo "==> Downloading $dmg_name..."
curl -fsSL -o "$tmp/$dmg_name" "$base_url/$dmg_name"
curl -fsSL -o "$tmp/$dmg_name.sha256" "$base_url/$dmg_name.sha256"
(cd "$tmp" && shasum -a 256 -c "$dmg_name.sha256" >/dev/null) \
  || { echo "error: checksum mismatch for $dmg_name" >&2; exit 1; }

echo "==> Mounting dmg..."
mount_point=$(hdiutil attach "$tmp/$dmg_name" -nobrowse -readonly | grep -o '/Volumes/.*' | head -1)
[ -d "$mount_point/Vox.app" ] || { echo "error: Vox.app not found in dmg" >&2; exit 1; }

echo "==> Installing to $APP..."
rm -rf "$APP"
cp -R "$mount_point/Vox.app" "$APP"
hdiutil detach "$mount_point" -quiet
mount_point=""

# The build is not Developer ID signed or notarized, so Gatekeeper would block the first launch.
echo "==> Removing quarantine attribute..."
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "==> Done: Vox $version installed. Open /Applications/Vox.app and grant Microphone, Accessibility, and Input Monitoring on first launch."
