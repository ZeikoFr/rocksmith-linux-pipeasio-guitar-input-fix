#!/usr/bin/env bash
# Rocksmith 2014 on Linux — PipeASIO setup, one shot.
#
# Builds PipeASIO with 32-bit WoW64 support, installs it, copies it into the
# Proton tree, registers it in the game prefix, installs RS_ASIO, and writes
# both config files. Detects distro family, Steam library, game, prefix,
# Proton build, Wine lib root, and the guitar adapter.
#
#   ./rocksmith-pipeasio-setup.sh              full run
#   ./rocksmith-pipeasio-setup.sh --reapply    just re-copy + re-register
#                                              (after a Proton update)
#   ./rocksmith-pipeasio-setup.sh --launch CMD reapply if stale, then exec CMD
#                                              (for Steam launch options)
#   PROTON=/path/to/proton/files ./rocksmith-pipeasio-setup.sh
#
# Steam launch options must be set by hand — printed at the end.
set -euo pipefail

APPID=221680
UARCH=$(uname -m)
BUILDLOG=/tmp/pipeasio-build.log
REAPPLY=0
LAUNCH=0
case "${1:-}" in
  --reapply) REAPPLY=1 ;;
  --launch)  REAPPLY=1; LAUNCH=1; shift ;;
esac

say() { printf '\n>> %s\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

# ---------- distro family ----------
FAMILY=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *" fedora "*) FAMILY=fedora ;;
    *" arch "*)   FAMILY=arch ;;
    *" debian "*) FAMILY=debian ;;
  esac
fi

# ---------- locate Steam / game / prefix ----------
STEAMROOT=""
for c in "$HOME/.steam/root" "$HOME/.steam/steam" "$HOME/.local/share/Steam" \
         "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"; do
  [ -f "$c/steamapps/libraryfolders.vdf" ] && { STEAMROOT=$(readlink -f "$c"); break; }
done
[ -n "$STEAMROOT" ] || die "Steam not found."

mapfile -t LIBS < <(grep -oP '"path"\s*"\K[^"]+' "$STEAMROOT/steamapps/libraryfolders.vdf")
LIBS+=("$STEAMROOT")

LIB="" INSTALLDIR=""
for l in "${LIBS[@]}"; do
  acf="$l/steamapps/appmanifest_$APPID.acf"
  [ -f "$acf" ] && { LIB="$l"; INSTALLDIR=$(grep -oP '"installdir"\s*"\K[^"]+' "$acf"); break; }
done
[ -n "$LIB" ] || die "Rocksmith (appid $APPID) not found in any Steam library."

GAME="$LIB/steamapps/common/$INSTALLDIR"
PFX="$LIB/steamapps/compatdata/$APPID/pfx"
[ -d "$GAME" ] || die "Game folder missing: $GAME"
[ -d "$PFX" ]  || die "Prefix missing — launch the game once from Steam, quit, rerun."
say "game:   $GAME"

# ---------- Proton: prefer newest GE (Valve builds ignore PROTON_USE_WOW64) ----------
if [ -z "${PROTON:-}" ]; then
  mapfile -t CAND < <( { ls -d "$STEAMROOT"/compatibilitytools.d/*/files 2>/dev/null
      for l in "${LIBS[@]}"; do
        ls -d "$l"/steamapps/common/Proton*/files "$l"/steamapps/common/Proton*/dist 2>/dev/null
      done; } | while read -r d; do [ -x "$d/bin/wine" ] && echo "$d"; done )
  [ "${#CAND[@]}" -gt 0 ] || die "No Proton found. Set PROTON=... and rerun."
  GE=$(printf '%s\n' "${CAND[@]}" | grep -i -E 'GE-Proton|Proton-GE|CachyOS' | sort -V | tail -1 || true)
  PROTON="${GE:-$(printf '%s\n' "${CAND[@]}" | sort -V | tail -1)}"
  [ -n "$GE" ] || cat <<'WARN'

   WARNING: no GE-Proton / Proton-CachyOS build found.
   Valve's Proton silently ignores PROTON_USE_WOW64=1, which PipeASIO's
   32-bit front end requires. Install GE-Proton 11.x (ProtonPlus) and rerun.

WARN
fi
[ -x "$PROTON/bin/wine" ] || die "PROTON invalid: $PROTON"
say "proton: $PROTON"

# ---------- Proton wine dll dirs (layout varies: lib/wine vs lib64/wine) ----------
find_dir() {  # $1 root, $2 dirname — must be wine's own dir, not dxvk/vkd3d/d7vk/nvapi/icu
  find "$1"/lib "$1"/lib64 "$1"/lib32 -maxdepth 3 -type d -path "*/wine/$2" -print -quit 2>/dev/null
}
P_U64=$(find_dir "$PROTON" x86_64-unix)
P_W64=$(find_dir "$PROTON" x86_64-windows)
P_W32=$(find_dir "$PROTON" i386-windows)
[ -n "$P_U64" ] && [ -n "$P_W64" ] && [ -n "$P_W32" ] \
  || die "Couldn't map Proton wine dll dirs under $PROTON"

# ---------- re-apply shortcut ----------
installed_in_local() { [ -f "$HOME/.local/lib/wine/$UARCH-unix/pipeasio32.so" ]; }

copy_into_proton() {  # returns 1 if the Proton tree was already current
  local S="$HOME/.local/lib/wine" changed=0 rel src dst
  # PipeASIO 1.7.0 split the 64-bit driver into a real PE plus a unixlib:
  # pipeasio64.dll + pipeasio64.so. Older installs ship pipeasio64.dll.so
  # instead, so copy whichever of the two is actually there.
  for rel in "$UARCH-unix/pipeasio32.so:$P_U64" \
             "$UARCH-unix/pipeasio64.so:$P_U64" \
             "$UARCH-unix/pipeasio64.dll.so:$P_U64" \
             "$UARCH-windows/pipeasio64.dll:$P_W64" \
             "i386-windows/pipeasio32.dll:$P_W32"; do
    src="$S/${rel%%:*}"
    [ -f "$src" ] || continue
    dst="${rel#*:}/$(basename "$src")"
    cmp -s "$src" "$dst" || { cp "$src" "$dst"; changed=1; }
  done
  [ "$changed" -eq 1 ] || return 1
  say "copied PipeASIO into the Proton tree"
}

register_pipeasio() {
  say "registering in the game prefix (cancel any Wine Mono prompt)"
  WINEPREFIX="$PFX" "$HOME/.local/bin/pipeasio-register" >/tmp/pipeasio-reg.log 2>&1 || true
  WINEPREFIX="$PFX" wineserver -k >/dev/null 2>&1 || true
  if grep -q "32-bit WoW64 front end registered" /tmp/pipeasio-reg.log; then
    say "registered (64-bit + 32-bit)"
  else
    printf '   !! 32-bit registration not confirmed. See /tmp/pipeasio-reg.log\n'
  fi
}

if [ "$REAPPLY" -eq 1 ]; then
  # --launch must never stop the game starting, so failures here are advisory
  if ! installed_in_local; then
    [ "$LAUNCH" -eq 1 ] || die "PipeASIO not installed yet — run without --reapply."
    printf '\n   !! PipeASIO is not installed — launching without re-applying.\n'
  elif copy_into_proton; then
    register_pipeasio
    say "re-apply done."
  else
    say "Proton tree already current — nothing to do."
  fi
  [ "$LAUNCH" -eq 0 ] && exit 0
  exec "$@"
fi

# ---------- dependencies ----------
# Since PipeASIO 1.7.0 both front ends are PE modules, so the x86_64 MinGW
# cross-compiler is needed as well, not just the i686 one. cmake wants
# libpipewire-0.3 >= 1.4.2 and stops hard below it.
have_deps() {
  command -v cmake >/dev/null && command -v gcc >/dev/null && command -v unzip >/dev/null \
    && command -v git >/dev/null && command -v curl >/dev/null \
    && command -v winegcc >/dev/null && command -v winebuild >/dev/null \
    && pkg-config --atleast-version=1.4.2 libpipewire-0.3 \
    && command -v i686-w64-mingw32-gcc >/dev/null \
    && command -v x86_64-w64-mingw32-gcc >/dev/null
}

install_deps() {
  case "$FAMILY" in
    fedora)
      local wd="wine-devel"
      [ -d /opt/wine-staging ] && wd="wine-staging-devel"
      [ -d /opt/wine-stable ]  && wd="wine-stable-devel"
      sudo dnf install -y --skip-unavailable cmake ninja-build gcc gcc-c++ pkgconf unzip \
        git curl pipewire-devel qt6-qtbase-devel "$wd" \
        mingw32-gcc mingw32-gcc-c++ mingw64-gcc mingw64-gcc-c++ ;;
    arch)
      sudo pacman -S --needed --noconfirm cmake ninja gcc pkgconf unzip \
        git curl libpipewire mingw-w64-gcc qt6-base wine ;;
    debian)
      sudo apt-get install -y cmake ninja-build gcc g++ pkg-config unzip \
        git curl libpipewire-0.3-dev qt6-base-dev wine64-tools libwine-dev \
        gcc-mingw-w64-i686 g++-mingw-w64-i686 \
        gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 ;;
    *) return 1 ;;
  esac
}

if ! have_deps; then
  say "installing build dependencies (${FAMILY:-unknown distro})"
  install_deps || true
fi
have_deps || die "Dependencies still missing: need cmake, gcc, git, curl, unzip,
   winegcc/winebuild (Wine SDK), libpipewire-0.3 >= 1.4.2 dev headers, and the i686 and
   x86_64 MinGW cross-compilers. Install them and rerun."

# ---------- Wine lib root (holds the <arch>-windows import libs) ----------
# cmake takes one root and builds both front ends out of it, so an i386-only
# root is no good: Arch keeps a 32-bit-only tree in /usr/lib32/wine beside the
# real one in /usr/lib/wine, and picking that one stops cmake on the missing
# x86_64 import libraries. Prefer a root carrying both.
WLR="" WLR32=""
while read -r c; do
  r=$(dirname "$(dirname "$c")")
  [ -n "$WLR32" ] || WLR32="$r"
  [ -f "$r/$UARCH-windows/libwinecrt0.a" ] || continue
  WLR="$r"; break
done < <(find /usr/lib /usr/lib64 /usr/lib32 /opt -maxdepth 5 \
           -path '*/i386-windows/libwinecrt0.a' 2>/dev/null | sort)
[ -n "$WLR32" ] || die "Couldn't find i386-windows/libwinecrt0.a — install your Wine SDK's 32-bit part."
if [ -z "$WLR" ]; then
  WLR="$WLR32"
  printf '   !! %s has no %s-windows import libraries; cmake may refuse it.\n' "$WLR" "$UARCH"
fi
say "wine lib root: $WLR"

# ---------- build PipeASIO ----------
SRC=$(mktemp -d); trap 'rm -rf "$SRC"' EXIT
: > "$BUILDLOG"
say "cloning PipeASIO  (build log: $BUILDLOG)"
git clone --depth 1 https://github.com/M0n7y5/pipeasio "$SRC/pipeasio" >>"$BUILDLOG" 2>&1 \
  || die "git clone failed — see $BUILDLOG"
cd "$SRC/pipeasio"

# BUILD_TESTS=OFF: the test hosts and unit tests are never installed and only
# add ways for the setup to stop on something the game does not use.
say "building (32-bit WoW64 enabled)"
cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_WOW64_32=ON -DBUILD_TESTS=OFF \
      -DWINE_LIB_ROOT="$WLR" >>"$BUILDLOG" 2>&1 \
  || die "cmake configure failed — see $BUILDLOG"
cmake --build build -j"$(nproc)" >>"$BUILDLOG" 2>&1 \
  || die "cmake build failed — see $BUILDLOG"

# PipeASIO lays its build tree out the way Wine does — <arch>-windows for the
# PE front ends, <host>-unix for the unixlib — not flat in build/.
[ -f "build/i386-windows/pipeasio32.dll" ] && [ -f "build/$UARCH-unix/pipeasio32.so" ] \
  || die "32-bit front end was not built — see $BUILDLOG"

say "installing to \$HOME/.local"
cmake --install build --prefix "$HOME/.local" >>"$BUILDLOG" 2>&1 \
  || die "cmake install failed — see $BUILDLOG"
for f in "i386-windows/pipeasio32.dll" "$UARCH-unix/pipeasio32.so" \
         "$UARCH-windows/pipeasio64.dll" "$UARCH-unix/pipeasio64.so"; do
  [ -f "$HOME/.local/lib/wine/$f" ] || die "missing after install: ~/.local/lib/wine/$f"
done

cd /
copy_into_proton || true
register_pipeasio

# ---------- RS_ASIO (0.7.5+ required for Proton 11 / WoW64) ----------
say "installing RS_ASIO"
RS_URL=$(curl -fsSL https://api.github.com/repos/mdias/rs_asio/releases/latest \
  | grep -oP '"browser_download_url":\s*"\K[^"]+\.zip')
[ -n "$RS_URL" ] || die "Could not resolve the RS_ASIO download URL."
RSTMP=$(mktemp -d)
curl -fsSL "$RS_URL" -o "$RSTMP/rs.zip"
unzip -oq "$RSTMP/rs.zip" -d "$RSTMP/x"
cp -rf "$(dirname "$(find "$RSTMP/x" -name RS_ASIO.dll | head -1)")"/. "$GAME"/
rm -rf "$RSTMP"

cat > "$GAME/RS_ASIO.ini" <<'INI'
[Config]
EnableWasapiOutputs=0
EnableWasapiInputs=0
EnableAsio=1

[Asio]
BufferSizeMode=driver
CustomBufferSize=

[Asio.Output]
Driver=PipeASIO
BaseChannel=0

[Asio.Input.0]
Driver=PipeASIO
Channel=0
INI
rm -f "$GAME/Rocksmith.ini"

# ---------- PipeASIO config: detect the adapter, mono vs stereo ----------
say "detecting guitar input"
NODE=$(pw-cli ls Node 2>/dev/null \
  | grep -oP 'node\.name = "\K[^"]+' \
  | grep -i -E 'guitar|rocksmith|real.?tone' | head -1 || true)
NIN=1
if [ -z "$NODE" ]; then
  NODE=$(pw-cli ls Node 2>/dev/null | grep -oP 'node\.name = "\K[^"]+' \
    | grep -i '^alsa_input' | grep -vi -E 'webcam|hdmi' | head -1 || true)
fi
case "$NODE" in *mono*) NIN=1 ;; *) [ -n "$NODE" ] && NIN=2 ;; esac

mkdir -p "$HOME/.config/pipeasio"
cat > "$HOME/.config/pipeasio/config.ini" <<INI
[pipeasio]
sample_rate = 48000
buffer_size = 256
inputs = $NIN
outputs = 2
input_device = $NODE
INI

if [ -n "$NODE" ]; then
  say "input device: $NODE  (inputs = $NIN)"
else
  printf '   !! No input device detected. Plug the cable in, then set input_device in\n'
  printf '      ~/.config/pipeasio/config.ini (find it with: pw-cli ls Node | grep node.name)\n'
fi

# ---------- done ----------
cat <<EOM

============================================================
Setup complete. One manual step left.

In Steam: right-click Rocksmith > Properties > General >
Launch Options, paste exactly this (one line):

    PROTON_USE_WOW64=1 %command%

And under Properties > Compatibility, force:

    $(basename "$(dirname "$PROTON")")

Then hit Play. Verify with:

    grep -E "PipeASIO|ASIO Error|unixlib" "$GAME/RS_ASIO-log.txt" | head

"bufferSwitch" lines mean audio is streaming.

Tune inputs/device/latency with:  pipeasio-settings
or edit ~/.config/pipeasio/config.ini (buffer_size) live.
After a Proton update, rerun:  $0 --reapply
============================================================

EOM
