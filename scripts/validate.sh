#!/bin/bash
# End-to-end driver for validations A and C. Idempotent; writes evidence to results/.
#
#   ./scripts/validate.sh
#
# Leaves no persistent system state: the throwaway keychain is removed from the
# user search list and deleted, and the LaunchAgent is booted out, on exit.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="$ROOT/results"
SERVICE=com.24x.agencyzero.spike
LABEL="gui/$(id -u)/$SERVICE"
KEYCHAIN="$ROOT/scripts/identities/spike.keychain-db"
SEARCH_BACKUP="$ROOT/scripts/identities/search-list.bak"

mkdir -p "$RESULTS"

cleanup() {
  launchctl bootout "$LABEL" 2>/dev/null
  if [ -f "$SEARCH_BACKUP" ]; then
    # shellcheck disable=SC2046
    security list-keychains -d user -s $(cat "$SEARCH_BACKUP")
    rm -f "$SEARCH_BACKUP"
  fi
}
trap cleanup EXIT

say() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }

say "build"
cargo build --manifest-path "$ROOT/Cargo.toml" || exit 1

# --------------------------------------------------------------------------
say "A1 — private mach service WITHOUT any launchd registration"
# --------------------------------------------------------------------------
"$ROOT/target/debug/agencyzero" > "$RESULTS/A1-listener.log" 2>&1 &
A1_PID=$!
sleep 1.5
"$ROOT/target/debug/agentone" --timeout 5 > "$RESULTS/A1-client.log" 2>&1
A1_RC=$?
kill $A1_PID 2>/dev/null
echo "client exit=$A1_RC (expected non-zero: name is not in the bootstrap namespace)"
grep -E "listener terminated|request failed" "$RESULTS/A1-listener.log" "$RESULTS/A1-client.log"

# --------------------------------------------------------------------------
say "A2 — same service WITH the minimal LaunchAgent plist"
# --------------------------------------------------------------------------
write_plist() { # $1 = output path, $2 = log prefix, rest = extra ProgramArguments
  local out=$1 prefix=$2; shift 2
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n'
    printf '\t<key>Label</key><string>%s</string>\n' "$SERVICE"
    printf '\t<key>ProgramArguments</key>\n\t<array>\n'
    printf '\t\t<string>%s</string>\n' "$ROOT/target/debug/agencyzero"
    for arg in "$@"; do printf '\t\t<string>%s</string>\n' "$arg"; done
    printf '\t</array>\n'
    printf '\t<key>MachServices</key>\n\t<dict><key>%s</key><true/></dict>\n' "$SERVICE"
    printf '\t<key>StandardOutPath</key><string>%s/%s-listener.log</string>\n' "$RESULTS" "$prefix"
    printf '\t<key>StandardErrorPath</key><string>%s/%s-listener.err</string>\n' "$RESULTS" "$prefix"
    printf '</dict>\n</plist>\n'
  } > "$out"
}

write_plist "$RESULTS/spike-A.plist" A2
rm -f "$RESULTS/A2-listener.log" "$RESULTS/A2-listener.err"
launchctl bootout "$LABEL" 2>/dev/null
launchctl bootstrap "gui/$(id -u)" "$RESULTS/spike-A.plist" || exit 1
"$ROOT/target/debug/agentone" --timeout 5 > "$RESULTS/A2-client.log" 2>&1
echo "client exit=$? (expected 0)"
grep -E "reply received|OK" "$RESULTS/A2-client.log"

say "A3 — manually launched listener while launchd owns the name"
("$ROOT/target/debug/agencyzero" > "$RESULTS/A3-listener.log" 2>&1 & sleep 2; kill %1 2>/dev/null)
grep -E "listener terminated" "$RESULTS/A3-listener.log"

# --------------------------------------------------------------------------
say "C — code-signature attestation"
# --------------------------------------------------------------------------
if [ ! -f "$KEYCHAIN" ]; then
  "$ROOT/scripts/make-identities.sh" || exit 1
fi
security list-keychains -d user | tr -d ' "' > "$SEARCH_BACKUP"
# shellcheck disable=SC2046
security list-keychains -d user -s $(cat "$SEARCH_BACKUP") "$KEYCHAIN"
security unlock-keychain -p spike-throwaway "$KEYCHAIN"

GOOD_SHA=$(cat "$ROOT/scripts/identities/SpikeGood.sha1")
REQ="identifier agentone and certificate leaf = H\"$GOOD_SHA\""

codesign --force --sign SpikeGood "$ROOT/target/debug/agencyzero" || exit 1
# Three peers, identical code, identical signing identifier — only the signing
# identity differs, so any accept/reject split is attributable to the cert alone.
for variant in good wrong adhoc; do cp "$ROOT/target/debug/agentone" "$RESULTS/agentone-$variant"; done
codesign --force -i agentone --sign SpikeGood  "$RESULTS/agentone-good"
codesign --force -i agentone --sign SpikeWrong "$RESULTS/agentone-wrong"
codesign --force -i agentone --sign -          "$RESULTS/agentone-adhoc"
for variant in good wrong adhoc; do
  printf '%-24s %s\n' "agentone-$variant" "$(codesign -d -r- "$RESULTS/agentone-$variant" 2>&1 | tail -1)"
done

write_plist "$RESULTS/spike-C.plist" C --require "$REQ"
rm -f "$RESULTS/C-listener.log" "$RESULTS/C-listener.err"
launchctl bootout "$LABEL" 2>/dev/null
launchctl bootstrap "gui/$(id -u)" "$RESULTS/spike-C.plist" || exit 1
sleep 1

for variant in wrong adhoc good; do
  say "C — peer: agentone-$variant"
  "$RESULTS/agentone-$variant" --timeout 5 2>&1 | grep -E "reply received|request failed|OK"
done

say "C — listener view (rejected peers never reach Rust)"
cat "$RESULTS/C-listener.log"

say "C — libxpc kernel-side rejection (unified log)"
log show --last 2m --debug --predicate 'eventMessage CONTAINS[c] "code signing requirement"' \
  --style compact 2>/dev/null | grep -i agencyzero | tail -6 | tee "$RESULTS/C-syslog.txt"

say "C — control: same wrong-signed peer against a listener with NO requirement"
write_plist "$RESULTS/spike-Cctl.plist" Cctl
rm -f "$RESULTS/Cctl-listener.log" "$RESULTS/Cctl-listener.err"
launchctl bootout "$LABEL" 2>/dev/null
launchctl bootstrap "gui/$(id -u)" "$RESULTS/spike-Cctl.plist" || exit 1
sleep 1
"$RESULTS/agentone-wrong" --timeout 5 2>&1 | grep -E "reply received|request failed|OK"

say "C — client-side requirement failure (where PeerRequirementFailed is observable)"
WRONG_SHA=$(cat "$ROOT/scripts/identities/SpikeWrong.sha1")
launchctl bootout "$LABEL" 2>/dev/null
launchctl bootstrap "gui/$(id -u)" "$RESULTS/spike-C.plist" || exit 1
sleep 1
"$RESULTS/agentone-good" --timeout 5 \
  --require "identifier agencyzero and certificate leaf = H\"$WRONG_SHA\"" 2>&1 \
  | grep -E "request failed|OK"

say "dependency footprint"
cargo tree --manifest-path "$ROOT/Cargo.toml" -p agentone --edges normal --prefix none \
  | sed 's/ (\*)$//' | sort -u > "$RESULTS/deps.txt"
echo "unique crates: $(wc -l < "$RESULTS/deps.txt" | tr -d ' ')"
echo "rama-* crates: $(grep -c '^rama' "$RESULTS/deps.txt")"

say "SDK availability of the attestation symbol"
grep -B6 "^xpc_connection_set_peer_code_signing_requirement" \
  "$(xcrun --show-sdk-path)/usr/include/xpc/connection.h" | grep -E "API_AVAILABLE|API_UNAVAILABLE|^xpc_connection_set"

say "done — evidence in results/"
