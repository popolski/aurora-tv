#!/usr/bin/env bash
# Pseudo-signature (ad hoc) du .app avant empaquetage, avec ses droits (entitlements).
#
# L'IPA n'est pas signée avec un certificat : atvloadly la re-signe avec votre Apple ID.
# Pour savoir quels droits demander (ici le groupe d'apps partagé avec l'extension
# Top Shelf), un outil de signature lit ceux de la signature existante : une
# signature ad hoc les y inscrit, sans certificat ni secret.
#
# Usage : scripts/fakesign.sh <chemin/Lanterne.app>
set -euo pipefail

APP="${1:?chemin du .app requis}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_ENT="$ROOT/App/Lanterne.entitlements"
EXT_ENT="$ROOT/App/TopShelf/TopShelf.entitlements"

sign() { codesign --force --sign - --timestamp=none "$@"; }

# De l'intérieur vers l'extérieur : frameworks, extensions, puis l'app.
if [[ -d "$APP/Frameworks" ]]; then
  find "$APP/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) -print0 |
    while IFS= read -r -d '' item; do sign "$item"; done
fi
if [[ -d "$APP/PlugIns" ]]; then
  find "$APP/PlugIns" -maxdepth 1 -name "*.appex" -print0 |
    while IFS= read -r -d '' ext; do
      [[ -d "$ext/Frameworks" ]] && find "$ext/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) -print0 |
        while IFS= read -r -d '' item; do sign "$item"; done
      sign --entitlements "$EXT_ENT" "$ext"
    done
fi
sign --entitlements "$APP_ENT" "$APP"

echo "Droits inscrits :"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null || true
for ext in "$APP"/PlugIns/*.appex; do
  [[ -d "$ext" ]] && { echo "$(basename "$ext") :"; codesign -d --entitlements - --xml "$ext" 2>/dev/null | plutil -p - 2>/dev/null || true; }
done
