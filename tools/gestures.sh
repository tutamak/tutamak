#!/bin/bash
# Turns macOS's four-finger trackpad gestures off or back on; three-finger gestures are left alone.
#
#   gestures.sh status    current values
#   gestures.sh off       backs up the current values, turns four-finger gestures off
#   gestures.sh restore   writes the backed-up values back
#
# Choosing "three fingers" in System Settings does not turn four-finger gestures off,
# and these keys cannot be changed from there.
set -euo pipefail

BACKUP_DIR="$HOME/Library/Application Support/Tutamak"
BACKUP="$BACKUP_DIR/gestures-backup.tsv"
ACTIVATE=/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings

# "domain key"; currentHost = defaults -currentHost ... NSGlobalDomain
ENTRIES=(
  "com.apple.AppleMultitouchTrackpad TrackpadFourFingerHorizSwipeGesture"
  "com.apple.AppleMultitouchTrackpad TrackpadFourFingerVertSwipeGesture"
  "com.apple.AppleMultitouchTrackpad TrackpadFourFingerPinchGesture"
  "com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerHorizSwipeGesture"
  "com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerVertSwipeGesture"
  "com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerPinchGesture"
  "currentHost com.apple.trackpad.fourFingerHorizSwipeGesture"
  "currentHost com.apple.trackpad.fourFingerVertSwipeGesture"
  "currentHost com.apple.trackpad.fourFingerPinchSwipeGesture"
)

read_value() {
  if [ "$1" = currentHost ]; then
    defaults -currentHost read NSGlobalDomain "$2" 2>/dev/null || echo unset
  else
    defaults read "$1" "$2" 2>/dev/null || echo unset
  fi
}

write_value() {
  if [ "$1" = currentHost ]; then
    defaults -currentHost write NSGlobalDomain "$2" -int "$3"
  else
    defaults write "$1" "$2" -int "$3"
  fi
}

delete_value() {
  if [ "$1" = currentHost ]; then
    defaults -currentHost delete NSGlobalDomain "$2" 2>/dev/null || true
  else
    defaults delete "$1" "$2" 2>/dev/null || true
  fi
}

# Tries to reload the trackpad settings without logging out.
apply() {
  if [ -x "$ACTIVATE" ]; then "$ACTIVATE" -u >/dev/null 2>&1 || true; fi
}

case "${1:-status}" in
  status)
    for entry in "${ENTRIES[@]}"; do
      read -r domain key <<<"$entry"
      printf "%-52s %-48s %s\n" "$domain" "$key" "$(read_value "$domain" "$key")"
    done
    ;;

  off)
    mkdir -p "$BACKUP_DIR"
    if [ -f "$BACKUP" ]; then
      echo "Keeping the existing backup: $BACKUP"
    else
      : >"$BACKUP"
      for entry in "${ENTRIES[@]}"; do
        read -r domain key <<<"$entry"
        printf "%s\t%s\t%s\n" "$domain" "$key" "$(read_value "$domain" "$key")" >>"$BACKUP"
      done
      echo "Backed up the current values: $BACKUP"
    fi
    for entry in "${ENTRIES[@]}"; do
      read -r domain key <<<"$entry"
      write_value "$domain" "$key" 0
    done
    apply
    echo "macOS four-finger gestures are off; three-finger gestures are unchanged."
    echo "If a four-finger swipe still opens Mission Control or switches Spaces, log out and back in."
    ;;

  restore)
    if [ ! -f "$BACKUP" ]; then
      echo "No backup: $BACKUP" >&2
      exit 1
    fi
    while IFS=$'\t' read -r domain key value; do
      if [ "$value" = unset ]; then
        delete_value "$domain" "$key"
      else
        write_value "$domain" "$key" "$value"
      fi
    done <"$BACKUP"
    rm -f "$BACKUP"
    apply
    echo "Four-finger gestures are restored. Log out and back in if they do not take effect."
    ;;

  *)
    echo "usage: $0 status|off|restore" >&2
    exit 2
    ;;
esac
