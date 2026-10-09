#!/usr/bin/env bash
# Assembles a minimal RPG Maker MV game for testing the MV/MZ runtime
# (Outsider): the engine from KADOKAWA's MIT licensed MV corescript, the
# MkxpSmoke plugin from this directory (which replaces the title screen with
# a test scene, so no database or pictures are needed), and a font.
#
#   make-game.sh <corescript checkout> <font.ttf> <output dir>

set -euo pipefail

core=$1
font=$2
out=$3
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "${out}/js/libs" "${out}/js/plugins" "${out}/fonts" "${out}/data" "${out}/save"

# The rpg_*.js files are the concatenation of the corescript's sources, in
# the order its rpg_*.json files give (what its "npm run build" does)
for part in core managers objects scenes sprites windows; do
    python3 -c 'import json, sys; print("\n".join(json.load(open(sys.argv[1]))))' \
            "${core}/rpg_${part}.json" |
        while read -r file; do cat "${core}/${file}"; echo; done > "${out}/js/rpg_${part}.js"
done

cp "${core}"/js/libs/*.js "${out}/js/libs/"
cp "${core}/js/main.js" "${core}/template/index.html" "${out}/"
mv "${out}/main.js" "${out}/js/main.js"
cp "${core}/template/fonts/gamefont.css" "${out}/fonts/"
cp "${font}" "${out}/fonts/mplus-1m-regular.ttf"
cp "${here}/MkxpSmoke.js" "${out}/js/plugins/"

cat > "${out}/js/plugins.js" <<'JS'
var $plugins = [
{"name":"MkxpSmoke","status":true,"description":"Test scene","parameters":{}}
];
JS

# What the launcher shows as the title
printf '{"gameTitle":"MV smoke test"}\n' > "${out}/data/System.json"
printf '{"name":"mv-smoke","main":"index.html","window":{"title":"MV smoke test"}}\n' \
       > "${out}/package.json"
