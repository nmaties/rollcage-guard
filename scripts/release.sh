#!/bin/bash
# Builds a signed, notarized universal macOS binary and (with --publish) attaches it to a GitHub release.
#
#   scripts/release.sh             build, sign and notarize into dist/
#   scripts/release.sh --publish   also create the GitHub release vX.Y.Z and update Formula/rollcage-guard.rb
#
# Needs a "Developer ID Application" certificate in the keychain and notary credentials saved with:
#   xcrun notarytool store-credentials rollcage-notary --apple-id you@example.com --team-id ABCDE12345
# Override either with SIGN_IDENTITY / NOTARY_PROFILE (or put them in scripts/signing.env, which git ignores).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f scripts/signing.env ]] && source scripts/signing.env

VERSION=$(sed -n 's/^let version = "\(.*\)"$/\1/p' Sources/rollcage-guard/main.swift)
PROFILE="${NOTARY_PROFILE:-rollcage-notary}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate found." >&2; exit 1; }

echo "Building rollcage-guard $VERSION (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/rollcage-guard"

rm -rf dist && mkdir -p dist/stage
cp "$BIN" dist/stage/rollcage-guard
codesign --force --timestamp --options runtime --sign "$IDENTITY" dist/stage/rollcage-guard
codesign --verify --strict dist/stage/rollcage-guard

echo "Notarizing (usually 1–5 minutes)…"
ditto -c -k dist/stage/rollcage-guard dist/notarize.zip
xcrun notarytool submit dist/notarize.zip --keychain-profile "$PROFILE" --wait
rm dist/notarize.zip

cp LICENSE README.md dist/stage/
TARBALL="dist/rollcage-guard-macos.tar.gz"
tar -czf "$TARBALL" -C dist/stage rollcage-guard LICENSE README.md
SHA=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)
echo "$SHA  rollcage-guard-macos.tar.gz" > "$TARBALL.sha256"
rm -rf dist/stage
echo "Built $TARBALL ($SHA)"

if [[ "${1:-}" == "--publish" ]]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  URL="https://github.com/$REPO/releases/download/v$VERSION/rollcage-guard-macos.tar.gz"
  sed -i '' -e "s|^  url \".*\"|  url \"$URL\"|" -e "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" \
      -e "s|^  version \".*\"|  version \"$VERSION\"|" Formula/rollcage-guard.rb
  git add Formula/rollcage-guard.rb
  git diff --cached --quiet || git commit -m "Formula: rollcage-guard $VERSION"
  git push
  NOTES=$(awk "/^## $VERSION/{f=1;next} /^## /{f=0} f" CHANGELOG.md)
  gh release create "v$VERSION" "$TARBALL" "$TARBALL.sha256" --title "rollcage-guard $VERSION" --notes "$NOTES"
fi
