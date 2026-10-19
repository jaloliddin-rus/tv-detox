#!/bin/sh
# Removes the home screen (this one or Projectivy) and turns your TV's own home screen back on.
# Usage: sh undo.sh <TV_IP>
set -e
cd "$(dirname "$0")"
[ -n "$1" ] || { echo "Usage: sh undo.sh <TV_IP>" >&2; exit 1; }
case "$1" in
  *.*.*.*:*) TV=$1 ;;
  *.*.*.*)   TV=$1:5555 ;;
  *)         TV=$1 ;;
esac
case "$TV" in *:*) adb connect "$TV" >/dev/null || true ;; esac
[ "$(adb -s "$TV" get-state 2>/dev/null)" = device ] || {
  echo "Can't reach $TV. Check the TV is on, on the same Wi-Fi, and has USB/network debugging turned on." >&2; exit 1; }

sh_tv() { adb -s "$TV" shell "$@" | tr -d '\r'; }
# Reads a file on the TV. The redirect runs on the TV, so a missing file gives nothing.
tv_file() { sh_tv "cat /data/local/tmp/$1 2>/dev/null"; }
CHANGES=changes-${TV%%:*}.txt

# Known TV home screens, in step with install.sh.
LAUNCHERS="com.google.android.tvlauncher com.google.android.apps.tv.launcherx com.google.android.leanbacklauncher
  com.mitv.tvhome com.amazon.tv.launcher"

# Turn back on whatever install.sh or projectivy.sh turned off: the TV's list, the laptop's copy,
# and any known home screen that's off, in case both lists were lost.
back=$( { tv_file tvhome-disabled.txt
          [ -f "$CHANGES" ] && sed -n 's/^off //p' "$CHANGES"
          for p in $LAUNCHERS; do sh_tv pm list packages -d "$p" | sed -n "s/^package:$p\$/$p/p"; done
        } | sort -u)
failed=
for p in $back; do
  sh_tv pm list packages -d "$p" | grep -qx "package:$p" || continue
  if sh_tv pm enable "$p" | grep -q "new state: enabled"; then echo "Turned $p back on"
  else echo "Couldn't turn $p back on." >&2; failed=1; fi
done
was=$(tv_file tvhome-home.txt | head -1)
before=$(tv_file tvhome-before.txt | head -1)
adb -s "$TV" uninstall com.ansub.tvhome >/dev/null 2>&1 || true

# Projectivy stays installed, so hand Home to the TV's own home screen by name: the one it had
# before projectivy.sh, else the first known one that's on. Android 9 has no roles, so
# set-home-activity is what changes it there.
homes=$(sh_tv cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null \
  | grep / | sed 's/^ *//') || true
own=
for c in "$before" $back $LAUNCHERS; do
  case "$c" in com.spocky.projengmenu*|com.ansub.tvhome*|"") continue ;; esac
  for h in $homes; do
    case "$h" in "$c"|"$c"/*) own=$h; break ;; esac
  done
  [ -z "$own" ] || break
done
if [ -n "$own" ]; then
  sh_tv cmd role add-role-holder --user 0 android.app.role.HOME "${own%%/*}" >/dev/null 2>&1 || true
  sh_tv cmd package set-home-activity "$own" >/dev/null 2>&1 || true
fi
sh_tv cmd role remove-role-holder --user 0 android.app.role.HOME com.spocky.projengmenu >/dev/null 2>&1 || true

# Projectivy's "Override current launcher" is an accessibility service that catches Home. Turn it off.
a11y=$(sh_tv settings get secure enabled_accessibility_services)
case "$a11y" in *com.spocky.projengmenu/*)
  rest=$(echo "$a11y" | tr ':' '\n' | grep -v '^com.spocky.projengmenu/' | paste -s -d: -) || true
  if [ -n "$rest" ]; then sh_tv "settings put secure enabled_accessibility_services '$rest'"
  else sh_tv settings delete secure enabled_accessibility_services >/dev/null; fi
  echo "Turned off Projectivy's Override current launcher" ;;
esac
adb -s "$TV" shell input keyevent KEYCODE_HOME

now=$(sh_tv cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1)
case "$now" in
  com.spocky.projengmenu/*)
    echo "Home still opens Projectivy. Uninstall it from the TV, or press Home and pick your TV's own home screen." >&2
    exit 1 ;;
  com.ansub.tvhome/*)
    echo "Home still opens this home screen: it couldn't be uninstalled. Run this again." >&2
    exit 1 ;;
esac

# Only forget what was turned off once it's all back on, so a second run can try again.
[ -n "$failed" ] || { sh_tv rm -f /data/local/tmp/tvhome-disabled.txt /data/local/tmp/tvhome-home.txt /data/local/tmp/tvhome-before.txt
                      rm -f "$CHANGES"; }
# Android saves this a few seconds later. Restarting before then can undo it.
[ -z "$back" ] || { echo "Saving the change on the TV, this takes 15 seconds…"; sleep 15; }

case "$now" in
  "$own") ;;
  *) echo "If the TV asks which home screen to use, pick your TV's own and choose Always." ;;
esac
case "$was" in
  com.spocky.projengmenu/*) echo "Done. Projectivy is still installed if you want it back. Wait 30 seconds before you restart the TV." ;;
  *) echo "Removed. Your TV is back to its own home screen." ;;
esac
