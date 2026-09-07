#!/bin/bash
# Creates a stable self-signed *code-signing* identity ("SnapMark Dev") in its own keychain.
# Signing every build with the same identity keeps macOS privacy permissions (Screen
# Recording) across rebuilds — ad-hoc signatures change with every build and lose them.
#
#   ./Packaging/make_dev_cert.sh        # run once; build.sh then picks the identity up automatically
#
# The only interactive step is trusting the certificate for code signing: macOS asks for
# your login password once ("security wants to make changes to your Certificate Trust Settings").
set -euo pipefail

NAME="${SNAPMARK_SIGN_IDENTITY:-SnapMark Dev}"
KC="$HOME/Library/Keychains/snapmark-dev.keychain-db"
PASS_FILE="$HOME/Library/Application Support/SnapMark/dev-keychain.pass"

if [[ -f "$KC" ]] && security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "✓ Identity \"$NAME\" already exists in $KC"
  exit 0
fi

# Keychain password: random, stored 0600 so build.sh can unlock the keychain after a reboot.
mkdir -p "$(dirname "$PASS_FILE")"
if [[ -f "$PASS_FILE" ]]; then
  PASS="$(cat "$PASS_FILE")"
else
  PASS="$(openssl rand -hex 24)"
  (umask 077; printf '%s' "$PASS" > "$PASS_FILE")
fi

if [[ ! -f "$KC" ]]; then
  security create-keychain -p "$PASS" "$KC"
fi
security set-keychain-settings "$KC"          # no auto-lock
security unlock-keychain -p "$PASS" "$KC"

# Add to the user's keychain search list (keeps the existing entries).
if ! security list-keychains -d user | grep -q "snapmark-dev.keychain-db"; then
  existing=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
    [[ -n "$line" ]] && existing+=("$line")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "${existing[@]}" "$KC"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/ext.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
O = SnapMark (local development)
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" 2>/dev/null

# Private key first (traditional RSA PEM — `security import` rejects PKCS#8), then the certificate with trust.
openssl rsa -in "$TMP/key.pem" -out "$TMP/key_rsa.pem" 2>/dev/null
security import "$TMP/key_rsa.pem" -k "$KC" -t priv -f openssl -T /usr/bin/codesign -T /usr/bin/security >/dev/null
echo "▸ Trusting \"$NAME\" for code signing — macOS will ask for your login password once."
if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$TMP/cert.pem"; then
  echo "✗ Trust settings were not applied (dialog cancelled?). The identity cannot be used until it is trusted."
  echo "  Re-run this script to try again."
  exit 1
fi
# Let codesign use the key without a keychain prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null 2>&1 || true

echo "✓ Identity ready:"
security find-identity -v -p codesigning "$KC" | grep "$NAME" || true
echo "  build.sh will now sign with \"$NAME\" automatically."
