#!/bin/bash
# Collects everything needed to work out why permissions aren't sticking.
# Read-only — changes nothing. Run it, then paste the whole output back.

APP_DEV="$HOME/ClaudeCode/Scribe/Scribe.app"
APP_SYS="/Applications/Scribe.app"
BUNDLE_ID="com.ethantruslow.scribe"

echo "############ Scribe doctor ############"
date
echo

echo "===== 1. macOS version ====="
sw_vers
echo

echo "===== 2. Is it running? ====="
if pgrep -lx Scribe; then
  echo "-> running from:"
  ps -eo pid,comm,args | grep "[C]ursorGlow" | head -5
else
  echo "NOT RUNNING"
fi
echo

echo "===== 3. How many copies exist? ====="
echo "-- in ClaudeCode:"
[ -d "$APP_DEV" ] && ls -dl "$APP_DEV" || echo "   (absent)"
echo "-- in /Applications:"
[ -d "$APP_SYS" ] && ls -dl "$APP_SYS" || echo "   (absent)"
echo "-- anywhere Spotlight knows about:"
mdfind -name "Scribe.app" 2>/dev/null | head -10 || echo "   (none)"
echo

echo "===== 4. Code signature of the ClaudeCode copy ====="
if [ -d "$APP_DEV" ]; then
  codesign -dvvv "$APP_DEV" 2>&1 | grep -Ei "^Identifier|^Format|^CDHash|^Signature|^TeamIdentifier|^Authority|^Flags"
  echo "-- verify:"
  codesign --verify --deep --strict --verbose=2 "$APP_DEV" 2>&1 | head -5
else
  echo "(absent)"
fi
echo

echo "===== 5. Signature of the /Applications copy (if any) ====="
if [ -d "$APP_SYS" ]; then
  codesign -dvvv "$APP_SYS" 2>&1 | grep -Ei "^Identifier|^CDHash|^Signature"
else
  echo "(absent)"
fi
echo

echo "===== 6. Crash reports ====="
find ~/Library/Logs/DiagnosticReports -iname "*Scribe*" -mtime -1 2>/dev/null | head -5 \
  || echo "none in the last day"
echo

echo "===== 7. What the app itself logged (last 10 min) ====="
log show --last 10m --predicate 'eventMessage CONTAINS "Scribe:"' --info 2>/dev/null \
  | grep "Scribe:" | tail -30
echo "(if this section is empty, the app never started or never logged)"
echo

echo "===== 8. TCC decisions mentioning Scribe (last 15 min) ====="
log show --last 15m --predicate 'subsystem == "com.apple.TCC"' --info 2>/dev/null \
  | grep -i scribe | tail -20
echo "(empty here is normal on some systems)"
echo

echo "===== 9. Most recent recording session ====="
SESSIONS="$HOME/Library/Application Support/Scribe"
if [ -d "$SESSIONS" ]; then
  LATEST="$(ls -t "$SESSIONS" 2>/dev/null | head -1)"
  if [ -n "$LATEST" ]; then
    echo "-> $SESSIONS/$LATEST"
    ls -la "$SESSIONS/$LATEST" | head -12
  else
    echo "(no sessions recorded yet)"
  fi
else
  echo "(no session folder yet — nothing has been recorded)"
fi
echo

echo "===== 10. Current permission state as the system sees it ====="
echo "Accessibility list entries mentioning our bundle id:"
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service, client, auth_value from access where client like '%scribe%';" 2>&1 \
  | head -10
echo "(a 'unable to open database' or 'authorization denied' line here is expected"
echo " unless Terminal has Full Disk Access — not a problem)"
echo

echo "############ end ############"
