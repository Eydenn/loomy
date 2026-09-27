#!/bin/sh
# Installs the "loomy" command without npm, bun or Homebrew.
# Creates a small script in ~/.local/bin (or $LOOMY_PREFIX/bin) that calls this folder.
#
#   ./install.sh              installer
#   ./install.sh --uninstall  uninstall
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
PREFIX="${LOOMY_PREFIX:-$HOME/.local}"
TARGET="$PREFIX/bin/loomy"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$TARGET"
  echo "loomy uninstalled ($TARGET removed)."
  exit 0
fi

mkdir -p "$PREFIX/bin"
printf '#!/bin/sh\n# Installed by install.sh of Loomy.\nexec "%s/bin/loomy" "$@"\n' "$DIR" >"$TARGET"
chmod +x "$TARGET" "$DIR/bin/loomy"
chmod +x "$DIR"/scripts/*.sh

echo "loomy installed: $TARGET → $DIR"
case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) echo "Add $PREFIX/bin to your PATH, for example: echo 'export PATH=\"$PREFIX/bin:\$PATH\"' >> ~/.zshrc" ;;
esac
echo "Check the machine with: loomy doctor --fix"
