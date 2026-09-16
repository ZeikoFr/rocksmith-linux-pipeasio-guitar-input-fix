#!/usr/bin/env bash
#
# Command line, Steam layout, Proton choice, Wine SDK root.

# The snippets handed to insh() are single-quoted on purpose: they are
# evaluated by the shell that sources the script, not by this one.
# shellcheck disable=SC2016

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT

# ------------------------------------------------------------- command line --

out=$(bash "$script" --help 2>&1)
check '--help exits 0' 0 "$?"
contains '--help prints usage' "$out" 'usage: rocksmith-pipeasio-setup.sh'
contains '--help lists --verify' "$out" '--verify'
if grep -q '^	' <<<"$out"; then
	nope '--help strips the heredoc tabs' 'a leading tab survived'
else
	ok '--help strips the heredoc tabs'
fi

out=$(bash "$script" --bogus 2>&1)
check 'unknown option exits 1' 1 "$?"
contains 'unknown option names itself' "$out" 'unknown argument: --bogus'

out=$(bash "$script" --launch 2>&1 </dev/null)
check '--launch with no command exits 1' 1 "$?"
contains '--launch says what it needs' "$out" '--launch needs the command to run'

# --------------------------------------------------------------- root guard --

out=$(insh 'refuse_root 0' 2>&1)
check 'root is refused' 1 "$?"
contains 'refusal explains itself' "$out" 'installs into your home directory'
insh 'refuse_root 1000' >/dev/null 2>&1
check 'a normal user passes' 0 "$?"
ALLOW_ROOT=1 insh 'refuse_root 0' >/dev/null 2>&1
check 'ALLOW_ROOT=1 overrides' 0 "$?"

# -------------------------------------------------------------------- Steam --

fixture_steam "$w"
h=$w/home
r=$(HOME=$h insh 'steam_root=$(find_steam_root); find_game')
check 'find_game picks the library holding the game' "$w/lib2	Rocksmith2014" "$r"

mv "$w/lib2/steamapps/appmanifest_221680.acf" "$w/acf"
HOME=$h insh 'steam_root=$(find_steam_root); find_game' >/dev/null 2>&1
check 'find_game fails when the game is absent' 1 "$?"
mv "$w/acf" "$w/lib2/steamapps/appmanifest_221680.acf"

# ------------------------------------------------------------------- Proton --

fixture_proton_build "$h/.steam/root/compatibilitytools.d/GE-Proton9-20/files"
fixture_proton_build "$h/.steam/root/compatibilitytools.d/GE-Proton11-1/files"
fixture_proton_build "$w/lib2/steamapps/common/Proton 9.0/dist"
fixture_proton_build "$w/lib2/steamapps/common/Proton Experimental/files"
mkdir -p "$w/lib2/steamapps/common/Proton Broken/files"

r=$(HOME=$h insh 'steam_root=$(find_steam_root); pick_proton')
check 'a GE build wins, newest first' \
	"$h/.steam/root/compatibilitytools.d/GE-Proton11-1/files" "$r"
HOME=$h insh 'steam_root=$(find_steam_root); pick_proton' >/dev/null
check 'a GE build reports rc 0' 0 "$?"

n=$(HOME=$h insh 'steam_root=$(find_steam_root); proton_candidates' | wc -l)
check 'only runnable builds are candidates' 4 "$n"
r=$(HOME=$h insh 'steam_root=$(find_steam_root); proton_candidates')
contains 'a path with a space survives' "$r" 'Proton Experimental/files'

rm -rf "$h/.steam/root/compatibilitytools.d"
r=$(HOME=$h insh 'steam_root=$(find_steam_root); pick_proton')
rc=$?
check 'no GE build reports rc 2' 2 "$rc"
contains 'and still returns the newest Valve build' "$r" 'Proton Experimental/files'
insh 'steam_root=/nonexistent; pick_proton' >/dev/null 2>&1
check 'no build at all reports rc 1' 1 "$?"

# ------------------------------------------------------- Proton dll mapping --

fixture_proton_tree "$w"
mkdir -p "$w/p/lib/wine/dxvk" "$w/p/lib64/wine/nvapi"
r=$(insh 'proton=$1; resolve_proton_dirs && printf "%s|%s|%s" "$proton_u64" "$proton_w64" "$proton_w32"' "$w/p")
check 'the three dll directories are mapped, dxvk ignored' \
	"$w/p/lib64/wine/$arch-unix|$w/p/lib64/wine/$arch-windows|$w/p/lib64/wine/i386-windows" "$r"
rm -rf "$w/p/lib64/wine/i386-windows"
insh 'proton=$1; resolve_proton_dirs' "$w/p" >/dev/null
check 'an incomplete tree is rejected' 1 "$?"

# ---------------------------------------------------------- Wine SDK root ----

both=$w/wl/usr/lib/wine
only32=$w/wl/usr/lib32/wine
mkdir -p "$both/i386-windows" "$both/$arch-windows" "$only32/i386-windows"
: > "$both/i386-windows/libwinecrt0.a"
: > "$both/$arch-windows/libwinecrt0.a"
: > "$only32/i386-windows/libwinecrt0.a"

# find is stubbed so the search can be aimed at the fixture instead of /usr.
stub="find() { printf '%s\n' '$only32/i386-windows/libwinecrt0.a' '$both/i386-windows/libwinecrt0.a'; };"
r=$(insh "$stub find_wine_lib_root")
rc=$?
check 'the 32-bit-only tree is skipped' "$both" "$r"
check 'a complete root reports rc 0' 0 "$rc"

stub32="find() { printf '%s\n' '$only32/i386-windows/libwinecrt0.a'; };"
r=$(insh "$stub32 find_wine_lib_root")
rc=$?
check 'a 32-bit-only root is a fallback, rc 2' 2 "$rc"
check 'and it is still returned' "$only32" "$r"
insh 'find() { :; }; find_wine_lib_root' >/dev/null
check 'no Wine SDK at all reports rc 1' 1 "$?"


# Debian multiarch: the 64-bit tree even carries an i386-windows directory, but
# the import library in it comes from the i386 tree, so only paths that end in
# libwinecrt0.a settle which root is which.
split64=$w/wl/usr/lib/$arch-linux-gnu/wine
split32=$w/wl/usr/lib/i386-linux-gnu/wine
mkdir -p "$split64/$arch-windows" "$split64/i386-windows" "$split32/i386-windows"
: > "$split64/$arch-windows/libwinecrt0.a"
: > "$split32/i386-windows/libwinecrt0.a"

stubsplit="find() { printf '%s\n' '$split32/i386-windows/libwinecrt0.a' \
	'$split64/$arch-windows/libwinecrt0.a'; };"
r=$(insh "$stubsplit find_wine_lib_root")
rc=$?
check 'two trees holding one half each report rc 3' 3 "$rc"
check 'the 32-bit root is printed first' "$split32" "$(head -1 <<< "$r")"
check 'the 64-bit root second' "$split64" "$(tail -1 <<< "$r")"

mkdir -p "$w/stitched"
insh "stitch_wine_lib_root '$w/stitched' '$split32' '$split64'"
check 'stitching the two returns cleanly' 0 "$?"
if [[ -f "$w/stitched/i386-windows/libwinecrt0.a" ]]; then
	ok 'the 32-bit import library is reachable through the stitched root'
else
	nope 'the 32-bit import library is reachable through the stitched root' 'not there'
fi
if [[ -f "$w/stitched/$arch-windows/libwinecrt0.a" ]]; then
	ok 'and the 64-bit one too'
else
	nope 'and the 64-bit one too' 'not there'
fi

summarize
