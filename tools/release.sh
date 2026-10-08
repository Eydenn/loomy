#!/usr/bin/env bash
# Publishes a Loomy release whose tag is already pushed: GitHub release with the npm tarball, Homebrew tap formula
# (public archive + sha256), then the local Homebrew install.
#   tools/release.sh <X.Y.Z> "<release notes>"
# Checks first: clean tree, VERSION / package.json / badges / CHANGELOG heading all at X.Y.Z, tag vX.Y.Z on HEAD and on
# GitHub. Needs gh (logged in), npm, curl, git; the tap is cloned into a temporary folder.
set -euo pipefail
V="${1:-}"; NOTES="${2:-}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && -n "$NOTES" ]] || { echo "usage: tools/release.sh <X.Y.Z> \"<notes>\"" >&2; exit 2; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GH_REPO="Eydenn/loomy"; TAP="https://github.com/Eydenn/homebrew-tap.git"
cd "$REPO"

fail() { echo "release: $*" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || fail "uncommitted changes"
[[ "$(cat VERSION)" == "$V" ]] || fail "VERSION is $(cat VERSION)"
grep -q "\"version\": \"$V\"" package.json || fail "package.json is not at $V"
for f in README.md README.fr.md; do grep -q "badge/version-$V-" "$f" || fail "$f badge is not at $V"; done
grep -q "^## $V — " CHANGELOG.md || fail "no '## $V — ' heading in CHANGELOG.md"
[[ "$(git rev-parse "v$V^{commit}" 2>/dev/null)" == "$(git rev-parse HEAD)" ]] || fail "tag v$V is not on HEAD"
REMOTE_TAG="$(git ls-remote --tags origin "refs/tags/v$V^{}" | cut -f1)"
[[ -n "$REMOTE_TAG" ]] || fail "tag v$V is not pushed"
[[ "$REMOTE_TAG" == "$(git rev-parse HEAD)" ]] || fail "tag v$V on GitHub is not HEAD"
gh release view "v$V" -R "$GH_REPO" >/dev/null 2>&1 && fail "release v$V already exists"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/loomy-release.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
npm pack --pack-destination "$TMP" >/dev/null 2>&1 || fail "npm pack failed"
gh release create "v$V" -R "$GH_REPO" "$TMP/loomy-$V.tgz" --latest --title "v$V" --notes "$NOTES"

curl -fsSL -o "$TMP/src.tar.gz" "https://github.com/$GH_REPO/archive/refs/tags/v$V.tar.gz"
SHA="$(shasum -a 256 "$TMP/src.tar.gz" 2>/dev/null || sha256sum "$TMP/src.tar.gz")"; SHA="${SHA%% *}"
git clone -q "$TAP" "$TMP/tap"
sed -i.bak -E "s|archive/refs/tags/v[0-9.]+\.tar\.gz|archive/refs/tags/v$V.tar.gz|; s|sha256 \"[0-9a-f]+\"|sha256 \"$SHA\"|" "$TMP/tap/Formula/loomy.rb"
rm -f "$TMP/tap/Formula/loomy.rb.bak"
grep -q "archive/refs/tags/v$V.tar.gz" "$TMP/tap/Formula/loomy.rb" && grep -q "sha256 \"$SHA\"" "$TMP/tap/Formula/loomy.rb" \
  || fail "tap formula not updated (url or sha256 pattern changed): release v$V exists, fix the tap by hand"
git -C "$TMP/tap" commit -qam "loomy $V"
git -C "$TMP/tap" push -q
echo "tap: Formula/loomy.rb → v$V ($SHA)"

if command -v brew >/dev/null 2>&1; then
  brew update >/dev/null 2>&1 || true
  brew upgrade eydenn/tap/loomy >/dev/null 2>&1 || true
  loomy --version || true
fi
