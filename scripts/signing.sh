#!/usr/bin/env bash
# iOS signing from Windows (Git Bash) — no Mac needed.
#
#   1) scripts/signing.sh csr <email> "<Your Name>"
#        → signing/dist.key (private key, keep safe) + signing/dist.csr
#        Upload dist.csr at developer.apple.com → Certificates → + → Apple Distribution,
#        download distribution.cer.
#
#   2) scripts/signing.sh secrets <distribution.cer> <profile.mobileprovision> \
#                                 <AuthKey_XXXX.p8> <KEY_ID> <ISSUER_ID> <TEAM_ID>
#        → builds a .p12 and stores everything as GitHub Actions secrets via `gh`.
#
# Everything lands in ./signing (git-ignored). Nothing is printed.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p signing

case "${1:-}" in
  csr)
    [[ $# -eq 3 ]] || { echo "usage: $0 csr <email> \"<Your Name>\""; exit 1; }
    openssl genrsa -out signing/dist.key 2048 2>/dev/null
    # MSYS_NO_PATHCONV stops Git Bash rewriting "/emailAddress=…" into a Windows path.
    MSYS_NO_PATHCONV=1 openssl req -new -key signing/dist.key -out signing/dist.csr \
      -subj "/emailAddress=$2/CN=$3/C=US"
    echo "Created signing/dist.csr — upload it as an Apple Distribution certificate request."
    ;;

  secrets)
    [[ $# -eq 7 ]] || { echo "usage: $0 secrets <cer> <mobileprovision> <p8> <KEY_ID> <ISSUER_ID> <TEAM_ID>"; exit 1; }
    cer=$2; profile=$3; p8=$4; key_id=$5; issuer=$6; team=$7
    [[ -f signing/dist.key ]] || { echo "signing/dist.key missing — run the csr step first."; exit 1; }

    openssl x509 -inform DER -in "$cer" -out signing/dist.pem
    pass=$(openssl rand -hex 16)
    # 3DES/SHA1 PKCS#12 so macOS `security import` on the CI runner accepts it.
    openssl pkcs12 -export -inkey signing/dist.key -in signing/dist.pem -out signing/dist.p12 \
      -passout "pass:$pass" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

    base64 -w0 signing/dist.p12 | gh secret set DIST_CERT_P12_BASE64
    printf '%s' "$pass"         | gh secret set DIST_CERT_PASSWORD
    base64 -w0 "$profile"       | gh secret set APPSTORE_PROFILE_BASE64
    gh secret set ASC_KEY_P8 < "$p8"
    printf '%s' "$key_id"       | gh secret set ASC_KEY_ID
    printf '%s' "$issuer"       | gh secret set ASC_ISSUER_ID
    printf '%s' "$team"         | gh secret set APPLE_TEAM_ID
    echo "All 7 signing secrets stored in the GitHub repo."
    ;;

  *)
    sed -n '2,16p' "$0"
    exit 1
    ;;
esac
