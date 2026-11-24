#!/bin/bash
# Automatic reinstall of Health Hook on your iPhone (runs on your Mac).
#
# The app's signing profile expires (free Apple account: 7 days; paid account: 1 year). Run every hour by launchd
# (see install-auto-reinstall.sh), this script rebuilds and reinstalls the app when:
#   - the installed app expires in less than MARGIN_DAYS days (2 by default);
#   - the iPhone is reachable by Xcode: same Wi-Fi as the Mac ("Connect via network" ticked once in Xcode →
#     Devices and Simulators) or USB cable. A VPN such as Tailscale is not enough: Xcode finds the iPhone on the LAN.
# Expiration of the installed app: saved after each successful reinstall (`expiration` file); the first time
# (app installed from Xcode), taken from the newest profile of the app among Xcode's provisioning profiles.
# On failure nothing is saved: new attempt one hour later, until it works.
#
# Usage: reinstall.sh [--force]   (--force: reinstall whatever the date)
# Optional settings in ~/Library/Application Support/HealthHook/config (VAR=value lines):
#   TEAM=<Team ID>       default: DEVELOPMENT_TEAM from Local.xcconfig (never guessed from the keychain, which may
#                        hold other people's certificates)
#   IPHONE=<identifier>  default: the first paired iPhone (xcrun devicectl list devices)
#   MARGIN_DAYS=2
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$HOME/Library/Application Support/HealthHook"
LOG="$STATE/reinstall.log"
EXPIRATION="$STATE/expiration"          # expiration (epoch) of the app installed by this script
mkdir -p "$STATE"
MARGIN_DAYS=2; TEAM=""; IPHONE=""
[ -f "$STATE/config" ] && . "$STATE/config"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
notify() { osascript -e "display notification \"$2\" with title \"Health Hook\" subtitle \"$1\"" >/dev/null 2>&1 || true; }
readable() { date -r "$1" '+%Y-%m-%d %H:%M'; }
# Build setting from Local.xcconfig (personal), else HealthHook.xcconfig (defaults)
setting() { cat "$REPO/Local.xcconfig" "$REPO/HealthHook.xcconfig" 2>/dev/null \
  | sed -n "s|^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([^[:space:]/]*\).*|\1|p" | grep -m1 . ; }

# One run at a time (a build can take longer than an hour); a lock older than 2 hours is taken over
LOCK="$STATE/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  [ -n "$(find "$LOCK" -maxdepth 0 -mmin +120 2>/dev/null)" ] || exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rmdir "$LOCK" 2>/dev/null' EXIT

[ -n "$TEAM" ] || TEAM=$(setting DEVELOPMENT_TEAM)
BUNDLE_ID="$(setting BUNDLE_ID_PREFIX).healthhook"

# Expiration (epoch) of .mobileprovision files: the latest one among those of this app (explicit app id, not "*")
profiles_expiration() {
  local f
  for f in "$@"; do
    [ -f "$f" ] && security cms -D -i "$f" 2>/dev/null > "$TMP/$(basename "$f").plist"
  done
  /usr/bin/python3 - "$TMP" "$BUNDLE_ID" <<'EOF'
import glob, plistlib, sys
folder, bundle = sys.argv[1], sys.argv[2]
dates = []
for p in glob.glob(folder + "/*.plist"):
    try:
        d = plistlib.load(open(p, "rb"))
    except Exception:
        continue
    if d.get("Entitlements", {}).get("application-identifier", "").endswith("." + bundle):
        dates.append(d["ExpirationDate"].timestamp())
print(int(max(dates)) if dates else "")
EOF
  rm -f "$TMP"/*.plist
}

# 1. Expiration of the installed app: known (installed by this script), otherwise from Xcode's profiles
END=""
if [ -s "$EXPIRATION" ]; then
  END=$(cat "$EXPIRATION")
else
  END=$(profiles_expiration "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision \
                            "$HOME/Library/MobileDevice/Provisioning Profiles/"*.mobileprovision)
  [ -n "$END" ] && echo "$END" > "$EXPIRATION" && log "Installed app expires (from Xcode's profiles): $(readable "$END")"
fi
NOW=$(date +%s)
HOURS_LEFT=$(( ${END:-0} > 0 ? (${END:-0} - NOW) / 3600 : -1 ))
if [ "${1:-}" != "--force" ] && [ -n "$END" ] && [ $(( END - NOW )) -gt $(( MARGIN_DAYS * 86400 )) ]; then
  exit 0
fi

fail() {
  log "FAILED: $1"
  # Notify only within 24 hours of expiration (otherwise one attempt per hour = too noisy)
  if [ -z "$END" ] || [ "$HOURS_LEFT" -lt 24 ]; then
    notify "Reinstall failed" "$1 — the app expires ${END:+on $(readable "$END")}."
  fi
  exit 1
}

[ -n "$TEAM" ] || fail "no Team ID (set DEVELOPMENT_TEAM in Local.xcconfig, or TEAM in $STATE/config)"

# 2. iPhone reachable?
xcrun devicectl list devices --json-output "$TMP/devices.json" >/dev/null 2>&1 || { log "devicectl unavailable"; exit 0; }
ID=$(/usr/bin/python3 - "$TMP/devices.json" "$IPHONE" <<'EOF'
import json, sys
wanted = sys.argv[2]
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, co, pr = d.get("hardwareProperties", {}), d.get("connectionProperties", {}), d.get("deviceProperties", {})
    if hw.get("platform") != "iOS" or co.get("pairingState") != "paired":
        continue
    if wanted and wanted not in (d.get("identifier"), hw.get("udid"), pr.get("name")):
        continue
    if co.get("tunnelState") == "unavailable":
        continue
    print(d["identifier"]); break
EOF
)
[ -n "$ID" ] || exit 0   # iPhone not around: try again later
log "iPhone reachable ($ID), installed app valid until ${END:+$(readable "$END")}: rebuilding"

# 3. Up-to-date code + project + build (-allowProvisioningUpdates renews the profile)
cd "$REPO" || fail "repository not found"
git pull --ff-only -q >> "$LOG" 2>&1 || log "git pull failed: building the local version"
xcodegen generate --quiet >> "$LOG" 2>&1 || fail "xcodegen"
BUILD="$STATE/build"
xcodebuild -project HealthHook.xcodeproj -target HealthHook -configuration Debug -sdk iphoneos \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" SYMROOT="$BUILD" build > "$STATE/build.log" 2>&1 \
  || fail "Xcode build (see $STATE/build.log)"
APP="$BUILD/Debug-iphoneos/HealthHook.app"
[ -d "$APP" ] || fail "app not found after the build"
NEW=$(profiles_expiration "$APP/embedded.mobileprovision")
[ -n "$NEW" ] || fail "cannot read the expiration of the new profile"
[ "$NEW" -gt $(( NOW + MARGIN_DAYS * 86400 )) ] \
  || fail "the new profile already expires on $(readable "$NEW") (check your Apple account in Xcode)"

# 4. Install
xcrun devicectl device install app --device "$ID" "$APP" >> "$LOG" 2>&1 || fail "install on the iPhone"
echo "$NEW" > "$EXPIRATION"
log "OK: app reinstalled, valid until $(readable "$NEW")"
notify "App reinstalled" "Valid until $(readable "$NEW"). The date in Home Assistant is updated at the next sync (pull down in the app to send now)."
