#!/usr/bin/env bash
#
# Shared harness for the suites in this directory. Sourced, never run.
#
# Every assertion runs the setup script in a fresh shell through insh(), which
# sources it and calls one function. That works because the script only calls
# main() when it is executed, not when it is sourced.

set -uo pipefail
shopt -s nullglob

script=${script:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rocksmith-pipeasio-setup.sh}
arch=$(uname -m)
pass=0
fail=0

ok() {
	pass=$((pass + 1))
	printf 'ok   %s\n' "$1"
}

nope() {
	fail=$((fail + 1))
	printf 'FAIL %s\n       got: %s\n' "$1" "$2"
}

check() { # name expected actual
	if [[ $2 == "$3" ]]; then
		ok "$1"
	else
		nope "$1" "$3 (want: $2)"
	fi
}

contains() { # name haystack needle
	case $2 in
		*"$3"*) ok "$1" ;;
		*) nope "$1" "$2" ;;
	esac
}

lacks() { # name haystack needle
	case $2 in
		*"$3"*) nope "$1" "$2" ;;
		*) ok "$1" ;;
	esac
}

# Sources the script in a fresh shell, then runs $1 with its functions in
# scope. Later arguments land as $1, $2... inside that code, so quote the code
# with single quotes at the call site.
insh() {
	local code=$1
	shift
	bash -c "source '$script' || exit 99
$code" harness "$@"
}

summarize() {
	printf -- '--- %s: %d passed, %d failed ---\n' "${0##*/}" "$pass" "$fail"
	(( fail == 0 ))
}

# ----------------------------------------------------------------- fixtures --

# A Steam root in $1/home with a second library in $1/lib2 holding the game.
fixture_steam() {
	local w=$1 root=$1/home/.steam/root
	mkdir -p "$root/steamapps" "$w/lib2/steamapps/common/Rocksmith2014" \
		"$w/lib2/steamapps/compatdata/221680/pfx"
	cat > "$root/steamapps/libraryfolders.vdf" <<-VDF
		"libraryfolders"
		{
			"0" { "path" "$root" }
			"1" { "path" "$w/lib2" }
		}
	VDF
	cat > "$w/lib2/steamapps/appmanifest_221680.acf" <<-ACF
		"AppState" { "appid" "221680" "installdir" "Rocksmith2014" }
	ACF
}

# A runnable Proton build at $1.
fixture_proton_build() {
	mkdir -p "$1/bin"
	printf '#!/bin/sh\n' > "$1/bin/wine"
	chmod +x "$1/bin/wine"
}

# The three wine dll directories a Proton tree must have, under $1/p.
fixture_proton_tree() {
	mkdir -p "$1/p/lib64/wine/$arch-unix" "$1/p/lib64/wine/$arch-windows" \
		"$1/p/lib64/wine/i386-windows"
}

# The assignments that point the script's globals at that tree. Meant to be
# pasted at the front of an insh() snippet.
proton_vars() {
	printf 'proton_u64=%s/p/lib64/wine/%s-unix; proton_w64=%s/p/lib64/wine/%s-windows; proton_w32=%s/p/lib64/wine/i386-windows;' \
		"$1" "$arch" "$1" "$arch" "$1"
}

# A PipeASIO install under $1/.local/lib/wine. $2 is the upstream era:
#   new  the 1.7.0 PE + unixlib layout
#   old  the pre-1.7.0 hybrid, which has no pipeasio64.so
#   none nothing installed at all
fixture_install() {
	local l=$1/.local/lib/wine
	mkdir -p "$l/$arch-unix" "$l/$arch-windows" "$l/i386-windows"
	case $2 in
		new)
			echo u32 > "$l/$arch-unix/pipeasio32.so"
			echo u64 > "$l/$arch-unix/pipeasio64.so"
			echo w64 > "$l/$arch-windows/pipeasio64.dll"
			echo w32 > "$l/i386-windows/pipeasio32.dll"
			;;
		old)
			echo u32 > "$l/$arch-unix/pipeasio32.so"
			echo hyb > "$l/$arch-unix/pipeasio64.dll.so"
			echo w32 > "$l/i386-windows/pipeasio32.dll"
			;;
	esac
}

# A game prefix at $1 registered to the degree given by $2: none, 64 or both.
# The registry text matches what pipeasio-register's reg add calls produce.
fixture_prefix() {
	local pfx=$1
	mkdir -p "$pfx/drive_c/windows/system32" "$pfx/drive_c/windows/syswow64"
	printf 'WINE REGISTRY Version 2\n;; All keys relative to \\\\Machine\n\n' > "$pfx/system.reg"
	[[ $2 == none ]] && return 0

	echo w64 > "$pfx/drive_c/windows/system32/pipeasio64.dll"
	cat >> "$pfx/system.reg" <<-'REG'
		[Software\\ASIO\\PipeASIO] 1758000000
		"CLSID"="{2D3CA9E2-1193-4C5D-B5FD-38798F3DC074}"
		"Description"="PipeASIO Driver"

	REG
	[[ $2 == 64 ]] && return 0

	echo w32 > "$pfx/drive_c/windows/syswow64/pipeasio32.dll"
	cat >> "$pfx/system.reg" <<-'REG'
		[Software\\Wow6432Node\\ASIO\\PipeASIO] 1758000000
		"CLSID"="{2D3CA9E2-1193-4C5D-B5FD-38798F3DC074}"
		"Description"="PipeASIO Driver"

	REG
	return 0
}

# A localconfig.vdf for account $2 under the Steam root $1, giving Rocksmith
# the launch options in $3. A decoy app comes first so the reader has to pick
# the right block.
fixture_launch_options() {
	local dir=$1/userdata/$2/config
	mkdir -p "$dir"
	cat > "$dir/localconfig.vdf" <<-VDF
		"UserLocalConfigStore"
		{
			"Software"
			{
				"Valve"
				{
					"Steam"
					{
						"apps"
						{
							"220"
							{
								"LaunchOptions"		"-novid -decoy"
							}
							"221680"
							{
								"name"		"Rocksmith 2014"
								"LaunchOptions"		"$3"
							}
						}
					}
				}
			}
		}
	VDF
}
