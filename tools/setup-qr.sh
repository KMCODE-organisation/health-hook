#!/bin/bash
# Shows a QR code that configures Health Hook: scan it with the iPhone's Camera app, tap "Open in Health Hook",
# then confirm in the app. Made on your Mac by qrencode (brew install qrencode): the URL is not sent anywhere.
#
# Usage: tools/setup-qr.sh               (asks for the webhook URL, hidden)
#        <command printing the URL> | tools/setup-qr.sh
# The URL is not taken as an argument, to keep it out of your shell history.
set -euo pipefail
command -v qrencode >/dev/null || { echo "Install qrencode first: brew install qrencode"; exit 1; }
if [ -t 0 ]; then
  read -rsp "Webhook URL (https://…/api/webhook/…): " URL; echo
else
  read -r URL
fi
case "$URL" in
  https://*/api/webhook/?*) ;;
  *) echo "Not a webhook URL: expected https://<your Home Assistant>/api/webhook/<id> (iOS refuses http://)"; exit 1 ;;
esac
ENCODED=$(/usr/bin/python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$URL")
qrencode -t ansiutf8 "healthhook://config?url=$ENCODED"
echo "Anyone who scans this code can send data to your sensors: clear the terminal afterwards."
