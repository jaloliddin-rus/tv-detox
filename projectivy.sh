#!/bin/sh
# Installs Projectivy Launcher from Google Play and makes it the default home screen,
# instead of this repo's own. Only needs adb, and you on the remote to press Install.
#
#   sh projectivy.sh <TV_IP>
#
# It waits up to 5 minutes for you to press Install, so give it time if a tool runs it for you.
# YES=1 answers yes to turning off the TV's own home screen.
# Undo with undo.sh. Projectivy itself stays installed; uninstall it from the TV if you like.
set -e
cd "$(dirname "$0")"

PKG=com.spocky.projengmenu
TARGET="$1"
[ -n "$TARGET" ] || { echo "Usage: sh projectivy.sh <TV_IP>" >&2; exit 1; }
command -v adb >/dev/null 2>&1 || {
  echo "adb is missing. Install it first:" >&2
  echo "  Mac:     brew install android-platform-tools" >&2
  echo "  Windows: https://developer.android.com/tools/releases/platform-tools" >&2
  exit 1; }

# An IP gets :5555 added; an adb serial (like emulator-5554) is used as is.
case "$TARGET" in
  *.*.*.*:*) TV=$TARGET ;;
  *.*.*.*)   TV=$TARGET:5555 ;;
  *)         TV=$TARGET ;;
esac
case "$TV" in *:*) adb connect "$TV" >/dev/null || true ;; esac

state=$(adb -s "$TV" get-state 2>&1 || true)
case "$state" in
  device) ;;
  *unauthorized*) echo "Your TV is asking \"Allow debugging?\". Press Allow (tick \"Always allow\"), then run this again." >&2; exit 1 ;;
  *) echo "Can't reach $TV. Check the TV is on, on the same Wi-Fi, and has USB/network debugging turned on." >&2; exit 1 ;;
esac

sh_tv() { adb -s "$TV" shell "$@" | tr -d '\r'; }
installed() { sh_tv pm list packages "$PKG" | grep -qx "package:$PKG"; }
current_home() { sh_tv cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1; }

# Google Play can't be driven over adb, so open the store page and wait for you to press Install.
if ! installed; then
  sh_tv pm list packages com.android.vending | grep -qx package:com.android.vending || {
    echo "This TV has no Google Play (it may be in Basic TV mode or signed out). Sign in to Google, then run this again." >&2; exit 1; }
  sh_tv input keyevent KEYCODE_WAKEUP
  echo "Opening Projectivy Launcher in Google Play on your TV. Press Install with the remote."
  out=$(sh_tv am start -a android.intent.action.VIEW -d "market://details?id=$PKG")
  case "$out" in *Error*) echo "Couldn't open Google Play on your TV: $out" >&2; exit 1 ;; esac
  printf "Waiting for it to install"
  i=0
  until installed; do
    i=$((i + 1))
    [ $i -le 60 ] || { echo; echo "Projectivy didn't install within 5 minutes. Install it from Google Play, then run this again." >&2; exit 1; }
    printf "."; sleep 5
  done
  echo
fi

# Ask the TV which of Projectivy's screens answers Home, rather than guessing its class name.
ME=$(sh_tv cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null \
  | grep "^ *$PKG/" | sed 's/^ *//' | head -1)
case "$ME" in
  "") echo "Projectivy is installed but doesn't offer itself as a home screen on this TV." >&2
      echo "Open Projectivy, go to Settings > General and turn on \"Override current launcher\"." >&2
      exit 1 ;;
esac

# Make it the default home: the role (Android 10+) and the classic way.
sdk=$(sh_tv getprop ro.build.version.sdk); case "$sdk" in ""|*[!0-9]*) sdk=0 ;; esac
if [ "$sdk" -ge 29 ]; then
  sh_tv cmd role add-role-holder --user 0 android.app.role.HOME "$PKG" >/dev/null 2>&1 || true
fi
sh_tv cmd package set-home-activity "$ME" >/dev/null 2>&1 || true
# Remember which home screen is meant to be in charge, for check.sh and undo.sh.
sh_tv "echo $ME > /data/local/tmp/tvhome-home.txt"

# Known TV home screens that are safe to turn off. Kept in step with install.sh.
LAUNCHERS="com.google.android.tvlauncher com.google.android.apps.tv.launcherx com.google.android.leanbacklauncher
  com.mitv.tvhome com.amazon.tv.launcher"

# Only known launchers get turned off. Settings, setup and System UI also answer Home, and
# the TV needs them to start, so they, unknown apps and anything always running stay on.
is_launcher() {
  case "$1" in
    "$PKG"|com.ansub.tvhome|com.android.settings|com.android.tv.settings|com.android.systemui|com.android.provision) return 1 ;;
    *setup*|*wraith*|*provision*|*systemui*|*tvcenter*|*.tv.framework*|*.tvinput*) return 1 ;;
  esac
  case " $(echo $LAUNCHERS) " in *" $1 "*) ;; *) return 1 ;; esac
  # If we can't read its flags, or it always runs, leave it on.
  flags=$(sh_tv dumpsys package "$1" 2>/dev/null | grep -m1 'pkgFlags=\[') || return 1
  case "$flags" in *PERSISTENT*) return 1 ;; esac
  return 0
}

# Most TVs' own launchers still win when you press Home. The fix is to turn them off
# (not uninstall). We save what we turned off on the TV, so undo.sh can turn it back on.
if [ "$(current_home)" != "$ME" ]; then
  others=""
  for p in $(sh_tv cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null \
      | grep / | sed 's|/.*||; s/^ *//' | sort -u); do
    if is_launcher "$p"; then others="$others $p"; continue; fi
    case "$p" in "$PKG"|com.ansub.tvhome|com.android.settings|com.android.tv.settings) ;; *) echo "Leaving $p on: it may be needed for your TV to start." ;; esac
  done
  others=$(echo $others | tr ' ' '\n')
  if [ -n "$others" ]; then
    echo "Your TV's own home screen keeps taking over:"
    echo "$others" | sed 's/^/  /'
    answer=${YES:+y}
    if [ -z "$answer" ]; then
      printf "Turn it off so Home opens Projectivy? You can undo this with undo.sh. [y/N] "
      { read answer </dev/tty; } 2>/dev/null || answer=n
    fi
    case "$answer" in
      y|Y|yes)
        for p in $others; do
          if sh_tv pm disable-user --user 0 "$p" | grep -q "new state: disabled"; then
            sh_tv "echo $p >> /data/local/tmp/tvhome-disabled.txt"
          else echo "Couldn't turn off $p." >&2; fi
        done
        # Android saves this a few seconds later. Restarting before then can undo it.
        echo "Saving the change on the TV, this takes 15 seconds…"
        sleep 15
        sh_tv cmd package set-home-activity "$ME" >/dev/null 2>&1 || true ;;
      *) echo "Left it on. Your TV may keep opening its own home screen. In Projectivy, Settings > General > \"Override current launcher\" can work around it." ;;
    esac
  fi
fi

adb -s "$TV" shell input keyevent KEYCODE_HOME
if [ "$(current_home)" = "$ME" ]; then
  echo "Done. Press Home on your remote to see Projectivy."
else
  echo "Installed, but your TV still opens its own home screen. If it asks which home screen to use, pick Projectivy and choose Always."
  echo "Otherwise, in Projectivy turn on Settings > General > \"Override current launcher\"."
fi
