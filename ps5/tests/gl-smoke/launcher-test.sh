#!/usr/bin/env bash
# Game launcher check, run by run-in-container.sh with the mkxp binary it
# built: lists three copies of the smoke test game, picks the second one
# with the keyboard and checks that it ran there (result.txt in its folder).
#
#   launcher-test.sh <mkxp binary> <smoke test dir> <screenshot dir>

set -euo pipefail

mkxp=$1
test_dir=$2
shots=$3

lib=/tmp/launcher-lib
launch=/tmp/launcher
rm -rf "${lib}" "${launch}" "${HOME}/.local/share/mkxp"
mkdir -p "${lib}/NotAGame" "${launch}" "${shots}"

make_game() {
    mkdir -p "$1/Data"
    sed "s/^Title=.*/Title=$2/" "${test_dir}/Game.ini" > "$1/Game.ini"
    printf 'rgssVersion=3\n' > "$1/mkxp.conf"
    ruby -rzlib -e 'File.binwrite(ARGV[1], Marshal.dump([[1, "Main", Zlib::Deflate.deflate(File.read(ARGV[0]))]]))' \
         "${test_dir}/main.rb" "$1/Data/Scripts.rvdata2"
}

# Listed by title: First Quest, Second Quest, Zeta (found one level down)
make_game "${lib}/b-game" "Second Quest"
make_game "${lib}/a-game" "First Quest"
make_game "${lib}/Extracted/Zeta" "Zeta"
mkdir -p "${lib}/a-game/Graphics/Titles1"
convert -size 544x416 gradient:orange-purple -fill white \
        -draw "rectangle 120,150 424,266" "${lib}/a-game/Graphics/Titles1/Title.png"

# No game in the working directory, so mkxp starts the launcher
cp "${mkxp}" "${launch}/mkxp"
printf 'gameLibrary=%s\n' "${lib}" > "${launch}/mkxp.conf"

cat > /tmp/launcher-drive.sh <<EOF
cd "${launch}"
SDL_AUDIODRIVER=dummy ALSOFT_DRIVERS=null ./mkxp > log.txt 2>&1 &
pid=\$!
sleep 5
import -window root "${shots}/launcher.png"
xdotool key Down
sleep 1
import -window root "${shots}/launcher-selected.png"
xdotool key Return
wait \$pid
EOF
timeout 120 xvfb-run -a -s "-screen 0 1280x720x24" bash /tmp/launcher-drive.sh || true

grep -E "Launcher|GL Version" "${launch}/log.txt" || true

result="${lib}/b-game/result.txt"
if [ -f "${result}" ] \
   && diff <(grep -v '^text_pixels' "${result}") "${test_dir}/expected.txt" > /dev/null \
   && [ ! -e "${lib}/a-game/result.txt" ] \
   && grep -q "found 3 games" "${launch}/log.txt"; then
    echo "PASS"
else
    echo "FAIL"
    ls -R "${lib}"
    grep -v '^[0-9a-f]*-' "${launch}/log.txt" | head -30
    exit 1
fi
