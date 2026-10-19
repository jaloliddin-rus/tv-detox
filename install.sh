#!/bin/sh
# Installs the home screen on your TV and makes it the default. Only needs adb.
#
#   sh install.sh <TV_IP>                          your TV apps, picked for you
#   sh install.sh <TV_IP> "com.netflix.ninja,com.google.android.youtube.tv"
#   sh install.sh <TV_IP> "" "bluetooth,sound,picture"   adds settings shortcuts by the clock
#
# Uses out/tvhome.apk if you built it, otherwise downloads the latest release.
set -e
cd "$(dirname "$0")"

TARGET="$1"; APPS="$2"; QUICK="$3"
[ -n "$TARGET" ] || { echo "Usage: sh install.sh <TV_IP> [\"app1,app2,...\"] [\"bluetooth,sound,picture\"]" >&2; exit 1; }
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

APK=out/tvhome.apk
if [ ! -f "$APK" ]; then
  APK=$(mktemp -d)/tvhome.apk
  echo "Downloading the home screen…"
  curl -fsSL -o "$APK" https://github.com/Ansub/tv-detox/releases/latest/download/tvhome.apk
fi

echo "Installing… If your TV shows a Google Play Protect message, follow it on the TV to allow the install."
if ! out=$(adb -s "$TV" install -r "$APK" 2>&1); then
  case "$out" in
    *UPDATE_INCOMPATIBLE*) echo "Replacing an older copy signed with a different key…"
                           adb -s "$TV" uninstall com.ansub.tvhome >/dev/null; adb -s "$TV" install "$APK" ;;
    *) echo "$out" >&2; exit 1 ;;
  esac
fi

if [ -n "$APPS" ] || [ -n "$QUICK" ]; then
  # The stamp makes the app apply this list once, even if Android later replays this start.
  set -- --es stamp "$(date +%s)"
  [ -n "$APPS" ] && set -- "$@" --es apps "\"$APPS\""
  [ -n "$QUICK" ] && set -- "$@" --es quick "\"$QUICK\""
  adb -s "$TV" shell am start -n com.ansub.tvhome/.MainActivity "$@" >/dev/null
fi

ME=com.ansub.tvhome/.MainActivity
sh_tv() { adb -s "$TV" shell "$@" | tr -d '\r'; }
current_home() { sh_tv cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1; }

# Make it the default home: the role (Android 10+) and the classic way.
sdk=$(sh_tv getprop ro.build.version.sdk); case "$sdk" in ""|*[!0-9]*) sdk=0 ;; esac
if [ "$sdk" -ge 29 ]; then
  sh_tv cmd role add-role-holder --user 0 android.app.role.HOME com.ansub.tvhome >/dev/null 2>&1 || true
fi
sh_tv cmd package set-home-activity "$ME" >/dev/null 2>&1 || true
# Remember which home screen is meant to be in charge, for check.sh and undo.sh.
sh_tv "echo $ME > /data/local/tmp/tvhome-home.txt"

# Known TV home screens that are safe to turn off.
LAUNCHERS="com.google.android.tvlauncher com.google.android.apps.tv.launcherx com.google.android.leanbacklauncher
  com.mitv.tvhome com.amazon.tv.launcher"

# Only known launchers get turned off. Settings, setup and System UI also answer Home, and
# the TV needs them to start, so they, unknown apps and anything always running stay on.
is_launcher() {
  case "$1" in
    com.ansub.tvhome|com.spocky.projengmenu|com.android.settings|com.android.tv.settings|com.android.systemui|com.android.provision) return 1 ;;
    *setup*|*wraith*|*provision*|*systemui*|*tvcenter*|*.tv.framework*|*.tvinput*|com.sony.dtv.*) return 1 ;;
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
    case "$p" in com.ansub.tvhome|com.spocky.projengmenu|com.android.settings|com.android.tv.settings) ;; *) echo "Leaving $p on: it may be needed for your TV to start." ;; esac
  done
  others=$(echo $others | tr ' ' '\n')
  if [ -n "$others" ]; then
    echo "Your TV's own home screen keeps taking over:"
    echo "$others" | sed 's/^/  /'
    answer=${YES:+y}
    if [ -z "$answer" ]; then
      printf "Turn it off so Home opens your new home screen? You can undo this with undo.sh. [y/N] "
      { read answer </dev/tty; } 2>/dev/null || answer=n
    fi
    case "$answer" in
      y|Y|yes)
        for p in $others; do
          if sh_tv pm disable-user --user 0 "$p" | grep -q "new state: disabled"; then
            sh_tv "echo $p >> /data/local/tmp/tvhome-disabled.txt"
            echo "off $p" >> "changes-$(echo "$TV" | tr ':' '_').txt"
          else echo "Couldn't turn off $p." >&2; fi
        done
        # Android saves this a few seconds later. Restarting before then can undo it.
        echo "Saving the change on the TV, this takes 15 seconds…"
        sleep 15
        sh_tv cmd package set-home-activity "$ME" >/dev/null 2>&1 || true ;;
      *) echo "Left it on. Your TV may keep opening its own home screen." ;;
    esac
  fi
fi

adb -s "$TV" shell input keyevent KEYCODE_HOME
if [ "$(current_home)" = "$ME" ]; then
  echo "Done. Press Home on your remote to see it."
else
  echo "Installed, but your TV still opens its own home screen. If it asks which home screen to use, pick \"Home\" and choose Always."
fi
