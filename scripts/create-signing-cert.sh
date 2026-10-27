#!/bin/bash
# Sotto - Create a stable self-signed code-signing certificate
# =============================================================
# Why: Sotto is signed ad-hoc (no paid Apple Developer account). Ad-hoc signatures
# get a new code hash on every build, so macOS forgets the TCC permissions you
# granted (Microphone, Accessibility, Screen Recording) each time you rebuild.
#
# A *stable* self-signed identity gives the app a constant designated requirement,
# so macOS remembers your permission grants across rebuilds. This is free and needs
# no Apple Developer account.
#
# Run this ONCE (idempotent). Then use scripts/build-and-install.sh as usual.
#
# Usage:
#   ./scripts/create-signing-cert.sh [--force] ["Certificate Name"]
# Default certificate name: "Sotto Self-Signed"
#   --force   Delete any existing cert/key with this name and recreate.
#
# Import strategy (stock macOS / Apple Silicon, no Homebrew OpenSSL required):
#   1. Generate PEM cert + key with /usr/bin/openssl (LibreSSL).
#   2. Import cert.pem and key.pem separately via `security import` (avoids
#      broken PKCS12 MAC/algorithm mismatches with Keychain).
#   3. Trust the cert for codeSigning so it appears in
#      `security find-identity -v -p codesigning`.
#   4. Optionally fall back to a macOS-compatible PKCS12 only when separate
#      PEM import fails. Never pass OpenSSL 3's `-legacy` to LibreSSL.

set -euo pipefail

FORCE=0
CERT_NAME="Sotto Self-Signed"

while [ $# -gt 0 ]; do
    case "$1" in
        --force|-f)
            FORCE=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--force] [\"Certificate Name\"]"
            echo "  --force   Replace any existing identity named Certificate Name"
            exit 0
            ;;
        -*)
            echo "❌ Unknown option: $1"
            echo "Usage: $0 [--force] [\"Certificate Name\"]"
            exit 1
            ;;
        *)
            CERT_NAME="$1"
            shift
            ;;
    esac
done

KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
# Older macOS may still use login.keychain (no -db suffix).
if [ ! -f "$KEYCHAIN" ] && [ -f "${HOME}/Library/Keychains/login.keychain" ]; then
    KEYCHAIN="${HOME}/Library/Keychains/login.keychain"
fi
P12_PW="sotto-local"

echo "🔐 Sotto self-signed code-signing certificate"
echo "============================================="

identity_present() {
    security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"
}

# Remove existing cert(s) / identity with this common name from the login keychain.
# Best-effort: macOS variants differ (delete-identity vs delete-certificate).
remove_existing_identity() {
    echo "📍 Removing existing '$CERT_NAME' from login keychain (if any)..."
    # Prefer delete-identity (cert + private key) when available.
    if security delete-identity -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
        # May be more than one; keep deleting until none remain.
        while security delete-identity -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; do :; done
    fi
    # Also clear leftover certificates with this CN (orphans from failed imports).
    while security delete-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; do :; done
}

if identity_present; then
    if [ "$FORCE" -eq 0 ]; then
        echo "✅ Code-signing identity already exists: '$CERT_NAME'"
        security find-identity -v -p codesigning | grep -F "$CERT_NAME" || true
        echo "   Re-run with --force to delete and recreate."
        exit 0
    fi
    remove_existing_identity
elif [ "$FORCE" -eq 1 ]; then
    # Broken imports can leave a cert/key that is not a codesigning identity.
    remove_existing_identity
fi

# Prefer Apple's LibreSSL (/usr/bin/openssl) when present; Homebrew OpenSSL 3
# is fine too for generation (we avoid PKCS12 with OpenSSL 3 defaults).
if [ -x /usr/bin/openssl ]; then
    OPENSSL="/usr/bin/openssl"
else
    OPENSSL="$(command -v openssl || true)"
fi
if [ -z "$OPENSSL" ]; then
    echo "❌ openssl not found. Install OpenSSL or use the system /usr/bin/openssl."
    exit 1
fi

OPENSSL_VER="$("$OPENSSL" version 2>/dev/null || echo "$OPENSSL")"
echo "   Using: $OPENSSL_VER"

# OpenSSL 3.x supports -legacy; LibreSSL and OpenSSL 1.x do not.
IS_OPENSSL3=0
case "$OPENSSL_VER" in
    OpenSSL\ 3*|OpenSSL\ 4*) IS_OPENSSL3=1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "📍 Generating a self-signed code-signing certificate..."

# Mirror Keychain Access → Certificate Assistant → Self Signed Root + Code Signing:
# a self-signed root with codeSigning EKU so user trust settings can make it
# appear in `security find-identity -v -p codesigning`.
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $CERT_NAME
[v3]
basicConstraints   = critical,CA:true
keyUsage           = critical,digitalSignature,keyCertSign
extendedKeyUsage   = critical,codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

authorize_codesign_key() {
    # Allow codesign to use the private key without prompting on every build.
    # This may prompt once for your login keychain password.
    echo "📍 Authorizing codesign to use the key (you may be asked for your login password)..."
    if [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
        security set-key-partition-list -S apple-tool:,apple:,codesign: \
            -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
    else
        security set-key-partition-list -S apple-tool:,apple:,codesign: \
            -s "$KEYCHAIN" >/dev/null 2>&1 || \
            echo "   (If you weren't prompted, the first build may ask you to 'Always Allow'.)"
    fi
}

trust_for_codesigning() {
    # User-domain trust (no sudo). trustRoot is correct because we issued a
    # self-signed CA/root. Without this, Keychain may import the items but
    # find-identity -p codesigning still shows nothing.
    echo "📍 Trusting certificate for code signing..."
    if ! security add-trusted-cert -r trustRoot -p codeSign -p basic \
            -k "$KEYCHAIN" "$TMP/cert.pem" >/dev/null 2>"$TMP/trust.err"; then
        # Some macOS versions reject -k with add-trusted-cert; retry without.
        if ! security add-trusted-cert -r trustRoot -p codeSign -p basic \
                "$TMP/cert.pem" >/dev/null 2>>"$TMP/trust.err"; then
            echo "   ⚠️  Could not set codeSigning trust automatically."
            echo "   In Keychain Access: find '$CERT_NAME' → Get Info → Trust →"
            echo "   Code Signing → Always Trust, then unlock/relock the keychain."
            return 1
        fi
    fi
    return 0
}

import_pem_separately() {
    echo "📍 Importing certificate and private key (PEM) into login keychain..."
    # Certificate first.
    if ! security import "$TMP/cert.pem" -k "$KEYCHAIN" -t cert \
            -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>"$TMP/import.err"; then
        echo "   Certificate import failed."
        return 1
    fi
    # Private key: -A allows all apps initially; partition-list narrows later.
    # Empty passphrase PEM from openssl -nodes.
    if ! security import "$TMP/key.pem" -k "$KEYCHAIN" -t priv \
            -A >/dev/null 2>>"$TMP/import.err"; then
        # Some Keychains want explicit allowed tools instead of -A.
        if ! security import "$TMP/key.pem" -k "$KEYCHAIN" -t priv \
                -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>>"$TMP/import.err"; then
            echo "   Private key import failed."
            return 1
        fi
    fi
    return 0
}

# PKCS12 fallback — only used if PEM import fails.
# Never pass -legacy to LibreSSL (unknown option → huge usage dump).
export_pkcs12_macos_compatible() {
    local out="$1"
    if [ "$IS_OPENSSL3" -eq 1 ]; then
        # OpenSSL 3 defaults (AES-256 + SHA-256 MAC) are rejected by macOS
        # with "MAC verification failed". Prefer -legacy; fall back to
        # explicit classic bags. Suppress usage text on failure.
        if "$OPENSSL" pkcs12 -export \
                -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
                -out "$out" -passout "pass:$P12_PW" -name "$CERT_NAME" \
                -legacy >/dev/null 2>"$TMP/p12.err"; then
            return 0
        fi
        if "$OPENSSL" pkcs12 -export \
                -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
                -out "$out" -passout "pass:$P12_PW" -name "$CERT_NAME" \
                -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 \
                >/dev/null 2>"$TMP/p12.err"; then
            return 0
        fi
        return 1
    fi
    # LibreSSL / OpenSSL 1.x: no -legacy. Default export is already classic;
    # pin SHA1/3DES explicitly when the option exists (ignore unknown quietly).
    if "$OPENSSL" pkcs12 -export \
            -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
            -out "$out" -passout "pass:$P12_PW" -name "$CERT_NAME" \
            -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 \
            >/dev/null 2>"$TMP/p12.err"; then
        return 0
    fi
    # Last resort: LibreSSL default algorithms (usually Keychain-compatible).
    if "$OPENSSL" pkcs12 -export \
            -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
            -out "$out" -passout "pass:$P12_PW" -name "$CERT_NAME" \
            >/dev/null 2>"$TMP/p12.err"; then
        return 0
    fi
    return 1
}

import_via_pkcs12() {
    echo "📍 Falling back to PKCS12 import..."
    if ! export_pkcs12_macos_compatible "$TMP/identity.p12"; then
        echo "   Could not create a macOS-compatible PKCS12 file."
        return 1
    fi
    if ! security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PW" \
            -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>"$TMP/import.err"; then
        echo "   PKCS12 security import failed."
        return 1
    fi
    return 0
}

print_manual_fallback() {
    echo ""
    echo "Manual fallback (Keychain Access → Certificate Assistant):"
    echo "  1. Open Keychain Access.app"
    echo "  2. menu Certificate Assistant → Create a Certificate…"
    echo "  3. Name: $CERT_NAME"
    echo "  4. Identity Type: Self Signed Root"
    echo "  5. Certificate Type: Code Signing"
    echo "  6. Create → then select the cert → Get Info → Trust →"
    echo "     Code Signing → Always Trust"
    echo "  7. Verify:"
    echo "       security find-identity -v -p codesigning | grep \"$CERT_NAME\""
    echo "  8. Continue with: ./scripts/build-and-install.sh"
}

# --- Primary path: separate PEM import + trust ---
IMPORTED=0
if import_pem_separately; then
    IMPORTED=1
elif import_via_pkcs12; then
    IMPORTED=1
else
    echo "❌ Could not import the certificate/key into your login keychain."
    if [ -s "$TMP/import.err" ]; then
        # One short line of context — never dump openssl usage text.
        head -n 3 "$TMP/import.err" >&2 || true
    fi
    print_manual_fallback
    exit 1
fi

trust_for_codesigning || true
authorize_codesign_key

echo ""
if identity_present; then
    echo "✅ Done. Code-signing identity created:"
    security find-identity -v -p codesigning | grep -F "$CERT_NAME"
    echo ""
    echo "Next: ./scripts/build-and-install.sh"
    exit 0
fi

echo "❌ Certificate import did not produce a usable code-signing identity."
echo "   (Items may be in Keychain but not trusted for Code Signing.)"
print_manual_fallback
exit 1
