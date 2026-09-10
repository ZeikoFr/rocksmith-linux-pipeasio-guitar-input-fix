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
#   PROTON=/path/to/proton/files ./rocksmith-pipeasio-setup.sh
#
# Steam launch options must be set by hand — printed at the end.
set -euo pipefail

APPID=221680
REAPPLY=0
[ "${1:-}" = "--reapply" ] && REAPPLY=1

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
copy_into_proton() {
  local S="$HOME/.local/lib/wine"
  [ -f "$S/x86_64-unix/pipeasio32.so" ] || die "PipeASIO not installed yet — run without --reapply."
  cp "$S/x86_64-unix/pipeasio32.so"     "$P_U64/"
  cp "$S/x86_64-unix/pipeasio64.dll.so" "$P_U64/"
  cp "$S/x86_64-windows/pipeasio64.dll" "$P_W64/"
  cp "$S/i386-windows/pipeasio32.dll"   "$P_W32/"
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
  copy_into_proton
  register_pipeasio
  say "re-apply done."
  exit 0
fi

# ---------- dependencies ----------
have_deps() {
  command -v cmake >/dev/null && command -v gcc >/dev/null && command -v unzip >/dev/null \
    && command -v winegcc >/dev/null && command -v winebuild >/dev/null \
    && pkg-config --exists libpipewire-0.3 \
    && ls /usr/bin/i686-w64-mingw32-gcc >/dev/null 2>&1
}

install_deps() {
  case "$FAMILY" in
    fedora)
      local wd="wine-devel"
      [ -d /opt/wine-staging ] && wd="wine-staging-devel"
      [ -d /opt/wine-stable ]  && wd="wine-stable-devel"
      sudo dnf install -y --skip-unavailable cmake ninja-build gcc gcc-c++ pkgconf unzip \
        pipewire-devel mingw32-gcc qt6-qtbase-devel "$wd" ;;
    arch)
      sudo pacman -S --needed --noconfirm cmake ninja gcc pkgconf unzip \
        libpipewire mingw-w64-gcc qt6-base wine ;;
    debian)
      sudo apt-get install -y cmake ninja-build gcc g++ pkg-config unzip \
        libpipewire-0.3-dev gcc-mingw-w64-i686 qt6-base-dev wine64-tools libwine-dev ;;
    *) return 1 ;;
  esac
}

if ! have_deps; then
  say "installing build dependencies (${FAMILY:-unknown distro})"
  install_deps || true
fi
have_deps || die "Dependencies still missing: need cmake, gcc, unzip, winegcc/winebuild (Wine SDK),
   libpipewire-0.3 dev headers, and an i686 MinGW cross-compiler. Install them and rerun."

# ---------- Wine lib root (for the 32-bit import libs) ----------
WLR=""
for c in $(find /usr/lib /usr/lib64 /usr/lib32 /opt -maxdepth 5 \
             -path '*i386-windows/libwinecrt0.a' 2>/dev/null); do
  WLR=$(dirname "$(dirname "$c")"); break
done
[ -n "$WLR" ] || die "Couldn't find i386-windows/libwinecrt0.a — install your Wine SDK's 32-bit part."
say "wine lib root: $WLR"

# ---------- build PipeASIO ----------
SRC=$(mktemp -d); trap 'rm -rf "$SRC"' EXIT
say "cloning PipeASIO"
git clone --depth 1 https://github.com/M0n7y5/pipeasio "$SRC/pipeasio" >/dev/null 2>&1
cd "$SRC/pipeasio"

say "building (32-bit WoW64 enabled)"
cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_WOW64_32=ON \
      -DWINE_LIB_ROOT="$WLR" >/dev/null
cmake --build build -j"$(nproc)" >/dev/null
[ -f build/pipeasio32.dll ] || ls build | grep -q pipeasio32 \
  || die "32-bit front end was not built — check the cmake output."

say "installing to \$HOME/.local"
cmake --install build --prefix "$HOME/.local" >/dev/null
[ -f "$HOME/.local/lib/wine/i386-windows/pipeasio32.dll" ] \
  || die "pipeasio32.dll missing after install."

cd /
copy_into_proton
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
