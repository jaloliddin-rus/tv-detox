#!/bin/sh
# Removes the home screen (this one or Projectivy) and turns your TV's own home screen back on.
# Usage: sh undo.sh <TV_IP>
set -e
[ -n "$1" ] || { echo "Usage: sh undo.sh <TV_IP>" >&2; exit 1; }
case "$1" in
  *.*.*.*:*) TV=$1 ;;
  *.*.*.*)   TV=$1:5555 ;;
  *)         TV=$1 ;;
esac
case "$TV" in *:*) adb connect "$TV" >/dev/null || true ;; esac

sh_tv() { adb -s "$TV" shell "$@" | tr -d '\r'; }

# Turn back on whatever install.sh or projectivy.sh turned off, before removing this home screen.
back=$(sh_tv cat /data/local/tmp/tvhome-disabled.txt 2>/dev/null | sort -u)
for p in $back; do
  sh_tv pm enable "$p" >/dev/null && echo "Turned $p back on"
done
was=$(sh_tv cat /data/local/tmp/tvhome-home.txt 2>/dev/null | head -1)
sh_tv rm -f /data/local/tmp/tvhome-disabled.txt /data/local/tmp/tvhome-home.txt
adb -s "$TV" uninstall com.ansub.tvhome >/dev/null 2>&1 || true

# Projectivy stays installed, so hand Home to the TV's own home screen by name.
# Android 9 has no roles, so set-home-activity is what changes it there. Known launchers are in
# step with install.sh, for when nothing was turned off.
for p in $back com.google.android.tvlauncher com.google.android.apps.tv.launcherx com.google.android.leanbacklauncher \
    com.mitv.tvhome com.amazon.tv.launcher; do
  own=$(sh_tv cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null \
    | grep "^ *$p/" | sed 's/^ *//' | head -1)
  [ -n "$own" ] || continue
  sh_tv cmd role add-role-holder --user 0 android.app.role.HOME "$p" >/dev/null 2>&1 || true
  sh_tv cmd package set-home-activity "$own" >/dev/null 2>&1 || true
  break
done
sh_tv cmd role remove-role-holder --user 0 android.app.role.HOME com.spocky.projengmenu >/dev/null 2>&1 || true
adb -s "$TV" shell input keyevent KEYCODE_HOME

case "$was" in
  com.spocky.projengmenu/*)
    echo "Done. Projectivy is still installed: if Home still opens it, turn off \"Override current launcher\""
    echo "in Projectivy's settings, or uninstall Projectivy from the TV." ;;
  *) echo "Removed. Your TV is back to its own home screen." ;;
esac
