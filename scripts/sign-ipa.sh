#!/usr/bin/env bash
# Signature optionnelle d'une IPA tvOS avec un certificat et un profil
# fournis par l'utilisateur (compte développeur payant). Inutile si
# atvloadly signe avec votre Apple ID (cas par défaut).
#
# Variables d'environnement (secrets GitHub, jamais dans le dépôt) :
#   SIGN_P12_BASE64        certificat + clé privée (.p12) en base64
#   SIGN_P12_PASSWORD      mot de passe du .p12
#   SIGN_PROFILE_BASE64    profil de provisionnement tvOS (.mobileprovision) en base64
#
# Usage : scripts/sign-ipa.sh <entrée.ipa> <sortie.ipa>
set -euo pipefail

IN="${1:?IPA en entrée requise}"
OUT="${2:?IPA de sortie requise}"
: "${SIGN_P12_BASE64:?secret SIGN_P12_BASE64 absent}"
: "${SIGN_P12_PASSWORD:?secret SIGN_P12_PASSWORD absent}"
: "${SIGN_PROFILE_BASE64:?secret SIGN_PROFILE_BASE64 absent}"

WORK="$(mktemp -d)"
KEYCHAIN="$WORK/signing.keychain-db"
KEYCHAIN_PASS="$(uuidgen)"
cleanup() {
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "$SIGN_P12_BASE64" | base64 --decode > "$WORK/cert.p12"
echo "$SIGN_PROFILE_BASE64" | base64 --decode > "$WORK/profile.mobileprovision"

security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security set-keychain-settings -lut 900 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$SIGN_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -F'"' '/"/{print $2; exit}')"
[[ -n "$IDENTITY" ]] || { echo "::error::aucune identité de signature dans le .p12" >&2; exit 1; }

security cms -D -i "$WORK/profile.mobileprovision" > "$WORK/profile.plist"
PROFILE_PLATFORM="$(/usr/libexec/PlistBuddy -c 'Print :Platform:0' "$WORK/profile.plist" 2>/dev/null || echo "?")"
EXPIRY="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$WORK/profile.plist")"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$WORK/profile.plist")"
echo "Profil : plateforme=$PROFILE_PLATFORM, application-identifier=$APP_ID, expiration=$EXPIRY"
[[ "$PROFILE_PLATFORM" == "tvOS" ]] || echo "::warning::le profil n'indique pas la plateforme tvOS ($PROFILE_PLATFORM)"
if [[ "$(date -j -f '%a %b %d %T %Z %Y' "$EXPIRY" +%s 2>/dev/null || echo 0)" -lt "$(date +%s)" ]]; then
  echo "::error::profil expiré ($EXPIRY)" >&2
  exit 1
fi
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$WORK/profile.plist" > "$WORK/entitlements.plist"

unzip -q "$IN" -d "$WORK/x"
APP="$(find "$WORK/x/Payload" -maxdepth 1 -name '*.app' -type d | head -n 1)"
cp "$WORK/profile.mobileprovision" "$APP/embedded.mobileprovision"

# Frameworks d'abord (de l'intérieur vers l'extérieur), puis l'application.
find "$APP" -depth \( -name "*.framework" -o -name "*.dylib" \) -print0 | while IFS= read -r -d '' item; do
  codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$item"
done
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --entitlements "$WORK/entitlements.plist" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT_ABS"
(cd "$WORK/x" && zip -qry -X "$OUT_ABS" Payload)
echo "IPA signée : $OUT_ABS"
