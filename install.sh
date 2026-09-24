#!/bin/sh
# Installe la commande « loomy » sans npm, bun ni Homebrew.
# Crée un petit script dans ~/.local/bin (ou $LOOMY_PREFIX/bin) qui appelle ce dossier.
#
#   ./install.sh              installer
#   ./install.sh --uninstall  désinstaller
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
PREFIX="${LOOMY_PREFIX:-$HOME/.local}"
TARGET="$PREFIX/bin/loomy"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$TARGET"
  echo "loomy désinstallé ($TARGET supprimé)."
  exit 0
fi

mkdir -p "$PREFIX/bin"
printf '#!/bin/sh\n# Installé par install.sh de Loomy.\nexec "%s/bin/loomy" "$@"\n' "$DIR" >"$TARGET"
chmod +x "$TARGET" "$DIR/bin/loomy"
chmod +x "$DIR"/scripts/*.sh

echo "loomy installé : $TARGET → $DIR"
case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) echo "Ajoutez $PREFIX/bin à votre PATH, par exemple : echo 'export PATH=\"$PREFIX/bin:\$PATH\"' >> ~/.zshrc" ;;
esac
echo "Vérifiez la machine avec : loomy doctor --fix"
