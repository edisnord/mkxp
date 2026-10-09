#!/usr/bin/env bash
# RPG Maker MV check, run by gl-smoke/run-in-container.sh with an mkxp
# binary that has Outsider linked in: the launcher lists a generated MV game
# (packaged NW.js style, in www/), starts it on Outsider, and the game's
# bitmaps (result.txt) and what reached the screen (a screenshot) are
# compared against what it draws.
#
#   mv-launcher-test.sh <mkxp binary> <Outsider shims dir> <corescript dir> <screenshot dir>

set -euo pipefail

mkxp=$1
shims=$2
corescript=$3
shots=$4
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

lib=/tmp/mv-lib
launch=/tmp/mv-launcher
game="${lib}/MV Smoke/www"
rm -rf "${lib}" "${launch}" "${HOME}/.local/share/mkxp"
mkdir -p "${lib}" "${launch}/outsider" "${shots}"

bash "${here}/make-game.sh" "${corescript}" "${here}/../../../assets/liberation.ttf" "${game}"

cp "${mkxp}" "${launch}/mkxp"
cp -r "${shims}" "${launch}/outsider/shims"
printf 'gameLibrary=%s\n' "${lib}" > "${launch}/mkxp.conf"

cat > /tmp/mv-drive.sh <<EOF
cd "${launch}"
SDL_AUDIODRIVER=dummy ALSOFT_DRIVERS=null ./mkxp > log.txt 2>&1 &
pid=\$!
sleep 5
import -window root "${shots}/mv-launcher.png"
xdotool key Return
sleep 3
import -window root "${shots}/mv-game.png"
wait \$pid
EOF
timeout 120 xvfb-run -a -s "-screen 0 1280x720x24" bash /tmp/mv-drive.sh || true

grep -E "Launcher|Starting Outsider|RPG Maker MV game|\[GL\] Version" "${launch}/log.txt" || true

# The 816x624 window sits centered on the 1280x720 screen, at (232, 48)
pixel() {
    convert "${shots}/mv-game.png" -crop "1x1+$1+$2" -depth 8 txt:- | grep -o '#[0-9A-F]\{6\}'
}

expected='background #0000ff
square #ff0000
screen 816x624'
result="${game}/result.txt"

if [ -f "${result}" ] \
   && [ "$(grep -v '^text_pixels' "${result}")" = "${expected}" ] \
   && [ "$(awk '/^text_pixels/ {print $2}' "${result}")" -gt 100 ] \
   && [ "$(pixel 332 148)" = "#FF0000" ] \
   && [ "$(pixel 700 500)" = "#0000FF" ]; then
    echo "PASS"
else
    echo "FAIL"
    cat "${result}" 2>/dev/null || true
    echo "screen: square $(pixel 332 148), background $(pixel 700 500)"
    grep -v '^[0-9a-f]*-' "${launch}/log.txt" | tail -30
    exit 1
fi
