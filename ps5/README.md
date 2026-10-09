# mkxp for the PlayStation 5

This directory cross-compiles mkxp for the PS5 with the
[ps5-payload-dev SDK](https://github.com/ps5-payload-dev/sdk). The PS5 runs a
modified FreeBSD kernel on x86_64, and the SDK targets it as
`x86_64-sie-ps5` with Clang 18. The whole toolchain runs in a Docker image,
and every upstream revision is pinned, so a rebuild on another machine
produces the same toolchain.

There are two ways to run mkxp on the console. The build produces both:

| | **Payload** (`mkxp.elf`) | **Native title** (`PPSA77001/`) |
|---|---|---|
| Rendering | Software OpenGL (Mesa llvmpipe through OSMesa) | **GPU** OpenGL through [ps5-opengl](https://github.com/blackbearreloaded/ps5-opengl) (Mesa on the PS5's AGC driver) |
| Launch | Send to an ELF loader such as [elfldr](https://github.com/ps5-payload-dev/elfldr) | Install the folder as a title, e.g. with [ShadowMountPlus](https://github.com/drakmor/ShadowMountPlus) and start it from the home screen |
| Game location | Anywhere on the console's file system | Inside the title folder (read-only); saves go to the title's download data |

## Quick start

Requirements: Docker (BuildKit), about 25 GB of free disk space and an
internet connection. The first run builds the toolchain image. This takes
roughly an hour on 4 cores, and most of that is LLVM and Mesa for the payload.
Later runs reuse the cached image and only rebuild mkxp.

```console
$ ./ps5/build.sh                              # or, with more cores:
$ ./ps5/build.sh --build-arg MAKEFLAGS=-j16
$ TARGET=native ./ps5/build.sh                # only one of the two
```

Output in `ps5/out/`:

| File | Purpose |
|------|---------|
| `mkxp.elf` | The payload (statically links everything except PS5 system libraries) |
| `libOSMesa.so.8` | Software OpenGL for the payload, loaded at runtime |
| `PPSA77001/` | The native title folder: `eboot.bin`, `sce_module/libc.prx`, `sce_sys/` |
| `mkxp.conf.sample` | Configuration template |

Any arguments to `build.sh` are passed to `docker build`. The script then runs
`scripts/build-mkxp.sh` in the image, with the repository mounted at `/src`.
Environment variables for `build.sh`:

| Variable | Default | Meaning |
|----------|---------|---------|
| `TARGET` | `all` | `payload`, `native` or `all` |
| `MKXP_TITLE_ID` | `PPSA77001` | Title ID of the native title. Give each game its own ID if you install several |
| `MKXP_TITLE_NAME` | `mkxp` | Name on the home screen |
| `MKXP_SCE_SYS` | | A directory inside this repository with replacement `icon0.png` (512×512), `pic0.dds`, `pic1.dds` and `snd0.at9` |

## What gets built

`Dockerfile` has four expensive layers. Each one is cached on its own:

1. **SDK and libraries from [pacbrew-repo](https://github.com/ps5-payload-dev/pacbrew-repo)**
   (`scripts/build-pacbrew.sh`, using upstream's PKGBUILDs through `makepkg`):
   the SDK, libc++, zlib, bzip2, libpng, libjpeg-turbo, libwebp, freetype,
   libogg, libvorbis, libsamplerate, SDL2 (the
   [PS5 port](https://github.com/ps5-payload-dev/SDL)), SDL2_image, SDL2_ttf
   and OpenAL Soft.
2. **LLVM and Mesa** (also from pacbrew-repo), for the payload only. The PS5
   SDL port gets OpenGL by `dlopen()`ing `libOSMesa.so.8`, which renders in
   software with llvmpipe. See `WITH_MESA` below.
3. **mkxp dependencies that pacbrew lacks** (`scripts/build-deps.sh`):

   | Component | Version | Notes |
   |-----------|---------|-------|
   | libps5compat | in-tree (`compat/`) | `execl`, `execle` and `endpwent`, which the SDK's libc lacks and Ruby needs |
   | libsigc++ | 2.12.1 | |
   | pixman | 0.42.2 | |
   | PhysFS | 3.2.0 | |
   | Boost | 1.86.0 | `unordered` headers, `program_options` |
   | SDL_sound | [Ancurio's fork](https://github.com/Ancurio/SDL_sound) @ `04798ba` | WAV, VOC, AIFF, AU, RAW, SHN, Ogg |
   | Ruby (MRI) | 3.1.7 | static, no stdlib extensions, `Zlib` compiled into the core like in RGSS (`patches/ruby-3.1-ps5.patch`) |

4. **Native title toolchain** (`native/setup-native.sh`), for the native title only:

   | Component | Version | Notes |
   |-----------|---------|-------|
   | [ps5-opengl](https://github.com/blackbearreloaded/ps5-opengl) SDK | 1.0.1 (release archive, sha256-pinned) | OpenGL 4.6 / EGL on the GPU, statically linked |
   | [ps5-native-app-boilerplate](https://github.com/blackbearreloaded/ps5-native-app-boilerplate) | `4f531c4`, the revision ps5-opengl 1.0.1 pins | FSELF converter and signer, startup code, and the clean-room `libc.prx` loader module (verified against its published hash) |
   | SDL2 with ps5-opengl's EGL video driver | ps5-payload-dev/SDL `8c56053`, as ps5-opengl's `integration/SDL2` builds it | With two changes: SDL audio stays enabled (upstream's bridge turns it off; mkxp's OpenAL plays through it), and `native/sdl-g19-render-thread.patch` lets the GL context live on mkxp's render thread |

Pinned upstream revisions, set as `ARG`s in the `Dockerfile`:

| ARG | Repository |
|-----|------------|
| `PS5_SDK_COMMIT` | ps5-payload-dev/sdk |
| `PS5_PACBREW_COMMIT` | ps5-payload-dev/pacbrew-repo (fixes the versions of every pacbrew package) |
| `PS5_SDL_COMMIT` | ps5-payload-dev/SDL (the payload's SDL) |

The native toolchain's revisions are pinned at the top of
`native/setup-native.sh`. Tarballs are verified by sha256 (in the PKGBUILDs,
`build-deps.sh` or `setup-native.sh`). Git checkouts and archives are verified
by commit hash.

### Build arguments

| Argument | Default | Meaning |
|----------|---------|---------|
| `MAKEFLAGS` | `-j4` | Parallelism for the toolchain build |
| `WITH_MESA` | `1` | `0` skips LLVM and Mesa, which saves most of the build time. The payload then needs a `libOSMesa.so.8` from another source on the console. The native title doesn't need it |
| `WITH_NATIVE` | `1` | `0` skips the native title toolchain |
| `BASE_IMAGE` | `ubuntu:24.04` | Override this to use a derived image, e.g. one that trusts a corporate proxy CA |
| `PS5_*_COMMIT` | see above | Bump these deliberately to update the toolchain |

### Offline or mirrored sources

Any file placed in `ps5/sources/` is copied into the image as makepkg's
`SRCDEST` and as the download cache of `build-deps.sh` and `setup-native.sh`.
Files are still checked against their pinned sha256, so a file from a mirror
works only if it is identical to the upstream one. Missing files are
downloaded as usual. File names must match what would be downloaded, which is
usually the basename of the URL, e.g. `v0.8.6.tar.gz` for openlibm.

## How the native title is built

mkxp is compiled with the same toolchain and libraries as the payload, with
`-DPS5_NATIVE=ON` and SDL resolved to the ps5-opengl build
(`native/native-pkg-config`). Only the final link differs.
`native/native-link.sh` takes CMake's place as the linker. It puts mkxp's
objects and libraries, the ps5-opengl runtime, libc++ and the payload SDK's
libc into one linker group. It then runs the boilerplate's builder, the same
way ps5-opengl's `integration/SDL2/folder.py` does: link with the native
startup code and ps5-opengl's allocator (`app_heap.c`), convert to an FSELF
`eboot.bin`, and assemble the title folder. The title metadata starts from
ps5-opengl's `native-app/param.json`, which sets the GPU memory budgets.
`native/mkxp_native.c` sends mkxp's output to `/download0/mkxp.log`, raises the
allocator's budget to 1 GiB (it falls back to less if the mapping fails), and
stubs one symbol the GL runtime expects.

ps5-opengl 1.0.1's SDL driver creates OpenGL 3.3 *core* profile contexts. That
is also the configuration it has a conformance run for. mkxp's shaders are
written in GLSL 1.10, so on core profile contexts mkxp now compiles them as
GLSL 3.30 through a small preamble (`src/shader.cpp`). The rest of its GL code
already avoided removed functionality.

## Working in the image by hand

```console
$ docker run --rm -it -v "$PWD:/src" --user "$(id -u):$(id -g)" mkxp-ps5-dev bash
$ /src/ps5/scripts/build-mkxp.sh native      # same as build.sh's last step
$ source $PS5_PAYLOAD_SDK/toolchain/prospero.sh
$ $CMAKE --build /src/ps5/build/payload      # incremental rebuild
```

`build-deps.sh` also takes component names, e.g. `build-deps.sh ruby`. This
helps when you change one dependency in a derived image.

## Testing without a console

`tests/gl-smoke.sh` builds mkxp for Linux in Docker and runs a generated
RGSS3 test game (`tests/gl-smoke/main.rb`) on Mesa llvmpipe under Xvfb, once
with a compatibility context and once with the 3.3 core context the native
title requests. The game draws sprites through mkxp's sprite, hue, text and
transition paths, reads the frame back and compares pixels against
`tests/gl-smoke/expected.txt`:

```console
$ ./ps5/tests/gl-smoke.sh
==> compat profile
GL Version   : 4.5 (Compatibility Profile) Mesa 25.2.8
PASS
==> core profile
GL Version   : 4.5 (Core Profile) Mesa 25.2.8
PASS
```

## Running the payload

You need a PS5 that runs an ELF loader such as
[elfldr](https://github.com/ps5-payload-dev/elfldr), which listens on port
9021.

1. Copy `libOSMesa.so.8` to `/user/homebrew/lib/` on the console, e.g. with
   ftpsrv. The payload loader also searches the working directory, so a copy
   next to the game works too.
2. Copy the game (the folder with `Game.ini`), `mkxp.conf` and optionally
   `mkxp.elf` to the console, e.g. `/data/mkxp/`.
3. mkxp switches to the directory of its own executable before it reads
   `mkxp.conf`. If the loader does not pass a path in `argv[0]` (for example,
   when the ELF is sent straight to port 9021), the PS5 SDL port reports
   `/data/` instead. In that case, put a `mkxp.conf` in `/data/` that points
   at the game:

   ```ini
   gameFolder=/data/mkxp/MyGame
   ```

4. Send the payload:

   ```console
   $ docker run --rm --network host -v "$PWD/ps5/out:/out" mkxp-ps5-dev \
         /opt/ps5-payload-sdk/bin/prospero-deploy -h <ps5-ip> /out/mkxp.elf
   ```

   (`socat -t 99999999 - TCP:<ps5-ip>:9021 < ps5/out/mkxp.elf` also works.)

## Running the native title

1. Copy the game's files (`Game.ini`, `Data/`, `Graphics/`, `Audio/`, …) into
   `ps5/out/PPSA77001/`, next to `eboot.bin`. Optionally add a `mkxp.conf`
   there too. If the game sits in a subfolder, point `gameFolder=` at it,
   relative to the title folder. RTPs can be added the same way with `RTP=`.
2. Upload the whole `PPSA77001/` folder to `/data/homebrew/` on the console and
   register it with a compatible loader such as ShadowMountPlus.
   `eboot.bin` can't be deployed by itself.
3. Start it from the home screen.

The title folder is mounted read-only as `/app0`, so mkxp reads the game from
there but runs Ruby with `/download0` (the title's persistent download data)
as its working directory. Save files therefore end up in `/download0`, and so
does the log, `/download0/mkxp.log`. Keep a title ID per game, so that their
saves stay apart.

## Display and controls

The window always covers the whole 1920×1080 display. The payload's video
driver centers smaller windows instead of scaling them, and the native title's
driver only accepts the display size. mkxp scales the game itself, so set
`fixedAspectRatio` and `smoothScaling` in `mkxp.conf` to taste. Keep
`winResizable` off. The native title's driver rejects resizable windows.

Default DualSense mapping. To change it, edit `src/keybindings.cpp`, or plug
in a USB keyboard and use mkxp's F1 menu:

| DualSense | RGSS button |
|-----------|-------------|
| Cross     | C (confirm) |
| Circle, Options | B (cancel / menu) |
| Square    | A |
| Triangle  | X |
| L1 / R1   | L / R |
| L2 / R2   | Y / Z |
| D-pad, left stick | directions |

## Changes to mkxp for this port

- `CMakeLists.txt`: name the binary `mkxp.elf` when built with the PS5
  toolchain. Add a stand-in for the SDL2 target that the static OpenAL Soft
  package references. Add the `PS5_NATIVE` option (defines `MKXP_PS5_NATIVE`).
- `src/main.cpp` on `__PROSPERO__`: create the window at desktop size, and call
  `SDL_SetMainReady`.
- `src/keybindings.cpp`: DualSense default bindings on `__PROSPERO__`.
- With `MKXP_PS5_NATIVE`: request an OpenGL 3.3 core context. Start in `/app0`.
  Mount the game folder by absolute path, then switch to `/download0` for
  Ruby's file I/O (`src/main.cpp`, `src/sharedstate.cpp`).
- Fixes that help any modern toolchain:
  - `binding-mri.cpp`: since Ruby 2.7, parts of the core library
    (`Kernel#class`, `Marshal.load`, …) are Ruby code that is only loaded
    during option processing. mkxp only called `ruby_setup()`, so with Ruby
    ≥ 2.7, loading the game's scripts crashed. It now also runs
    `ruby_options()` on an empty script.
  - `binding-util.h`: Ruby version checks that also hold for Ruby 3.x, and an
    `rb_data_type_t` initializer that stays valid since Ruby 2.7 changed the
    struct.
  - `shader.cpp`, `gl-fun.cpp`: run the GLSL 1.10 shaders on core profile
    contexts.
  - `eventthread.cpp`: no duplicate `ALC_SOFT_pause_device` typedefs with new
    OpenAL Soft headers.
  - `fluid-fun.cpp`: recognize FreeBSD.

## Known limitations

- **Neither variant has been run on a console yet.** The builds are verified to
  produce a payload that links only against PS5 system libraries, and a title
  folder whose FSELF and `libc.prx` pass the boilerplate's integrity checks.
  The native title also passes the generic checks of ps5-opengl's
  `verify-native-test-app.sh`: segment alignment, allocator wraps, AGC/VideoOut
  imports, no forbidden unresolved symbols. The core profile rendering path is
  verified on Mesa llvmpipe (`tests/gl-smoke.sh`), but not on the PS5 GPU.
- Native title specifics that are outside what ps5-opengl has validated:
  - SDL audio in the native title.
  - Rendering from a thread other than the one that initialized video.
  - A 1 GiB allocator budget.
  - Using the payload SDK's libc for functions the native libc lacks.
- The payload renders in software (llvmpipe). RGSS resolutions are small, but
  expect it to be slower than on a PC.
- No MIDI: mkxp would `dlopen()` fluidsynth, and no PS5 build of it is
  bundled. No MP3: SDL_sound is built without mpg123.
- Ruby is 3.1, not the 1.8/1.9 that RPG Maker used, and has no stdlib
  extensions. Scripts that rely on old syntax or on `require` of stdlib
  libraries need changes, as on any modern mkxp build.
