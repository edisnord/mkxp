#!/usr/bin/env bash
# Builds mkxp for Linux against Ubuntu's libraries and runs the smoke test
# game with Mesa's llvmpipe under Xvfb, once with a compatibility context
# and once with the OpenGL 3.3 core context the PS5 native title uses.
# Runs inside ubuntu:24.04 with the repository mounted read-only at /src.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential cmake pkg-config git ca-certificates autoconf automake libtool \
    libsigc++-2.0-dev libpixman-1-dev libphysfs-dev libboost-program-options-dev \
    libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev libopenal-dev libvorbis-dev \
    zlib1g-dev ruby ruby-dev xxd xvfb xauth libgl1-mesa-dri > /dev/null

# mkxp's SDL_sound fork, as in ps5/scripts/build-deps.sh
git clone -q https://github.com/Ancurio/SDL_sound.git /tmp/SDL_sound
(
    cd /tmp/SDL_sound
    git -c advice.detachedHead=false checkout -q 04798ba55dccd18b094c0f6a2630c2fe7b15aa86
    ./bootstrap > /dev/null 2>&1
    ./configure -q --disable-static > /dev/null
    make -s -j"$(nproc)" > /dev/null 2>&1
    make -s install > /dev/null
)
ldconfig

test_dir=/src/ps5/tests/gl-smoke
game=/tmp/game
mkdir -p "${game}/Data"
cp "${test_dir}/Game.ini" "${game}/"
printf 'rgssVersion=3\n' > "${game}/mkxp.conf"
ruby -rzlib -e 'File.binwrite(ARGV[1], Marshal.dump([[1, "Main", Zlib::Deflate.deflate(File.read(ARGV[0]))]]))' \
     "${test_dir}/main.rb" "${game}/Data/Scripts.rvdata2"

status=0
for profile in compat core; do
    echo "==> ${profile} profile"
    rm -rf /tmp/mkxp && cp -r /src /tmp/mkxp && rm -rf /tmp/mkxp/ps5/build /tmp/mkxp/ps5/out
    if [ "${profile}" = core ]; then
        # Request what MKXP_PS5_NATIVE requests
        sed -i 's|^\tSDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);|&\n\tSDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);\n\tSDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);\n\tSDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);|' \
            /tmp/mkxp/src/main.cpp
        grep -q SDL_GL_CONTEXT_PROFILE_CORE /tmp/mkxp/src/main.cpp
    fi
    cmake -S /tmp/mkxp -B /tmp/mkxp/build -DMRIVERSION=3.2 -DCMAKE_BUILD_TYPE=Release > /dev/null 2>&1
    cmake --build /tmp/mkxp/build -j"$(nproc)" > /tmp/build.log 2>&1 \
        || { tail -30 /tmp/build.log; exit 1; }

    cp /tmp/mkxp/build/mkxp.bin.x86_64 "${game}/"
    rm -f "${game}/result.txt"
    (
        cd "${game}"
        SDL_AUDIODRIVER=dummy ALSOFT_DRIVERS=null timeout 120 \
            xvfb-run -a -s "-screen 0 1024x768x24" ./mkxp.bin.x86_64 > log.txt 2>&1 || true
    )
    grep -E "GL Version" "${game}/log.txt" || true

    if [ -f "${game}/result.txt" ] \
       && diff <(grep -v '^text_pixels' "${game}/result.txt") "${test_dir}/expected.txt" > /dev/null \
       && [ "$(awk '/^text_pixels/ {print $2}' "${game}/result.txt")" -gt 100 ]; then
        echo "PASS"
    else
        echo "FAIL"
        cat "${game}/result.txt" 2>/dev/null || grep -v '^[0-9a-f]*-' "${game}/log.txt" | head -30
        status=1
    fi
done
exit "${status}"
