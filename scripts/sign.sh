#!/bin/bash
# Usage: sign.sh <SpikeGood|SpikeWrong|adhoc|strip> <binary>...
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
KEYCHAIN="$DIR/identities/spike.keychain-db"
IDENTITY=$1; shift

for bin in "$@"; do
  case "$IDENTITY" in
    adhoc)
      codesign --force --sign - "$bin" ;;
    strip)
      codesign --remove-signature "$bin" ;;
    *)
      codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$bin" ;;
  esac
  echo "== $bin =="
  codesign -d -r- "$bin" 2>&1 || true
done
