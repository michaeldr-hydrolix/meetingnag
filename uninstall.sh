#!/bin/bash
# Removes MeetingNag completely (app, login item, lid-closed mode, installer receipts).
# Settings and the acknowledgement log in ~/Library/Application Support/MeetingNag are kept.
# Usage: sudo bash uninstall.sh      (also available as ⏰ › Uninstall MeetingNag…)
LABEL="io.local.meetingnag"

if [[ $EUID -ne 0 ]]; then exec sudo /bin/bash "$0" "$(id -un)"; fi

USER_NAME="${1:-$(stat -f%Su /dev/console)}"
USER_UID="$(id -u "$USER_NAME")"
USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')"

launchctl bootout "gui/$USER_UID/$LABEL" 2>/dev/null || true
pkill -x MeetingNag 2>/dev/null || true
rm -f "$USER_HOME/Library/LaunchAgents/$LABEL.plist"

/usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 || true
rm -f /etc/sudoers.d/meetingnag "$USER_HOME/Library/Application Support/MeetingNag/.lidmode"

tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true
sudo -u "$USER_NAME" tccutil reset Calendar "$LABEL" >/dev/null 2>&1 || true

pkgutil --forget io.local.meetingnag.app >/dev/null 2>&1 || true
pkgutil --forget io.local.meetingnag.lidmode >/dev/null 2>&1 || true

rm -rf /Applications/MeetingNag.app "$USER_HOME/Applications/MeetingNag.app"
echo "MeetingNag removed. Settings and log kept in ~/Library/Application Support/MeetingNag."
