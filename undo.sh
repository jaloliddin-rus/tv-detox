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
before=$(sh_tv cat /data/local/tmp/tvhome-before.txt 2>/dev/null | head -1)
sh_tv rm -f /data/local/tmp/tvhome-disabled.txt /data/local/tmp/tvhome-home.txt /data/local/tmp/tvhome-before.txt
adb -s "$TV" uninstall com.ansub.tvhome >/dev/null 2>&1 || true

# Projectivy stays installed, so hand Home to the TV's own home screen by name: the one it had
# before projectivy.sh, else the first known launcher that's on. Android 9 has no roles, so
# set-home-activity is what changes it there. Known launchers are in step with install.sh.
homes=$(sh_tv cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null \
  | grep / | sed 's/^ *//')
own=
for c in "$before" $(for p in $back com.google.android.tvlauncher com.google.android.apps.tv.launcherx \
    com.google.android.leanbacklauncher com.mitv.tvhome com.amazon.tv.launcher; do echo "$homes" | grep "^$p/"; done); do
  case "$c" in com.spocky.projengmenu/*|com.ansub.tvhome/*|"") continue ;; esac
  echo "$homes" | grep -qx "$c" && { own=$c; break; }
done
if [ -n "$own" ]; then
  sh_tv cmd role add-role-holder --user 0 android.app.role.HOME "${own%%/*}" >/dev/null 2>&1 || true
  sh_tv cmd package set-home-activity "$own" >/dev/null 2>&1 || true
fi
sh_tv cmd role remove-role-holder --user 0 android.app.role.HOME com.spocky.projengmenu >/dev/null 2>&1 || true

# Projectivy's "Override current launcher" is an accessibility service that catches Home. Turn it off.
a11y=$(sh_tv settings get secure enabled_accessibility_services)
case "$a11y" in *com.spocky.projengmenu/*)
  rest=$(echo "$a11y" | tr ':' '\n' | grep -v '^com.spocky.projengmenu/' | paste -s -d: -)
  if [ -n "$rest" ]; then sh_tv settings put secure enabled_accessibility_services "$rest"
  else sh_tv settings delete secure enabled_accessibility_services >/dev/null; fi
  echo "Turned off Projectivy's Override current launcher" ;;
esac
adb -s "$TV" shell input keyevent KEYCODE_HOME

now=$(sh_tv cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1)
case "$now" in
  com.spocky.projengmenu/*|com.ansub.tvhome/*)
    echo "Home still opens $now. Projectivy is still installed: uninstall it from the TV, or press Home and pick your TV's own home screen." >&2
    exit 1 ;;
esac
case "$was" in
  com.spocky.projengmenu/*) echo "Done. Home opens your TV's own home screen again. Projectivy is still installed if you want it back." ;;
  *) echo "Removed. Your TV is back to its own home screen." ;;
esac
