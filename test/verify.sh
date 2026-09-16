#!/usr/bin/env bash
#
# Reading the registration back out of the prefix, the Steam launch options,
# and --verify as a whole.

# The snippets handed to insh() are single-quoted on purpose: they are
# evaluated by the shell that sources the script, not by this one.
# shellcheck disable=SC2016

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT

# ------------------------------------------------------------ registration ---

h=$w/h
fixture_install "$h" new

for state in none 64 both; do
	pfx=$w/pfx-$state
	fixture_prefix "$pfx" "$state"
	HOME=$h insh 'prefix=$1; registered_64' "$pfx"
	rc64=$?
	HOME=$h insh 'prefix=$1; registered_32' "$pfx"
	rc32=$?
	case $state in
		none) check 'an untouched prefix has no 64-bit registration' 1 "$rc64"
		      check 'nor a 32-bit one' 1 "$rc32" ;;
		64)   check 'a 64-bit registration is seen' 0 "$rc64"
		      check 'and is not mistaken for a 32-bit one' 1 "$rc32" ;;
		both) check 'a full registration is seen, 64-bit' 0 "$rc64"
		      check 'and 32-bit' 0 "$rc32" ;;
	esac
done

# The key must be matched, not merely the staged DLL: a prefix can keep the
# file from an old install whose registry entry has since been wiped.
pfx=$w/pfx-nokey
fixture_prefix "$pfx" both
printf 'WINE REGISTRY Version 2\n' > "$pfx/system.reg"
HOME=$h insh 'prefix=$1; registered_64' "$pfx"
check 'a staged DLL without the registry key is not a registration' 1 "$?"

# ...and the reverse: the key without the file the loader needs.
pfx=$w/pfx-nodll
fixture_prefix "$pfx" both
rm "$pfx/drive_c/windows/syswow64/pipeasio32.dll"
HOME=$h insh 'prefix=$1; registered_32' "$pfx"
check 'a registry key without the staged DLL is not a registration' 1 "$?"

pfx=$w/pfx-stale
fixture_prefix "$pfx" both
HOME=$h insh 'prefix=$1; staged_is_current' "$pfx"
check 'freshly staged DLLs match the install' 0 "$?"
echo rebuilt > "$h/.local/lib/wine/$arch-windows/pipeasio64.dll"
HOME=$h insh 'prefix=$1; staged_is_current' "$pfx"
check 'a rebuild leaves the staged DLLs stale' 1 "$?"
echo w64 > "$h/.local/lib/wine/$arch-windows/pipeasio64.dll"

# ---------------------------------------------------------- launch options ---

root=$w/steamroot
mkdir -p "$root"
fixture_launch_options "$root" 12345678 'PROTON_USE_WOW64=1 %command%'
r=$(insh 'steam_root=$1; launch_options' "$root")
check 'the launch options are read back for the right app' 'PROTON_USE_WOW64=1 %command%' "$r"

fixture_launch_options "$root" 12345678 'gamemoderun %command%'
r=$(insh 'steam_root=$1; launch_options' "$root")
check 'a decoy app before it is not picked up' 'gamemoderun %command%' "$r"

rm -rf "$root/userdata"
r=$(insh 'steam_root=$1; launch_options' "$root")
check 'no localconfig at all reads as empty' '' "$r"

mkdir -p "$root/userdata/999/config"
cat > "$root/userdata/999/config/localconfig.vdf" <<'VDF'
"UserLocalConfigStore"
{
	"Software" { "Valve" { "Steam" { "apps"
	{
		"221680"
		{
			"name"		"Rocksmith 2014"
		}
	} } } }
}
VDF
r=$(insh 'steam_root=$1; launch_options' "$root")
check 'an app block without launch options reads as empty' '' "$r"

# ----------------------------------------------------------------- --verify --

# A complete, healthy setup, then one thing broken at a time.
h=$w/good
fixture_install "$h" new
fixture_proton_tree "$h"
pfx=$h/pfx
fixture_prefix "$pfx" both
g=$h/game
mkdir -p "$g" "$h/.config/pipeasio"
echo dll > "$g/RS_ASIO.dll"
printf '[Config]\nEnableAsio=1\n\n[Asio.Output]\nDriver=PipeASIO\n' > "$g/RS_ASIO.ini"
printf '[pipeasio]\ninput_device = my_guitar\n' > "$h/.config/pipeasio/config.ini"
root=$h/steam
fixture_launch_options "$root" 1 'PROTON_USE_WOW64=1 %command%'
v=$(proton_vars "$h")
env="$v prefix=\"$pfx\"; game_dir=\"$g\"; steam_root=\"$root\";"
HOME=$h insh "$v copy_into_proton" >/dev/null 2>&1

out=$(HOME=$h insh "$env verify" 2>&1)
check 'a healthy setup verifies clean' 0 "$?"
contains 'and says so' "$out" 'everything checks out'
contains 'it reports the input device' "$out" 'input_device = my_guitar'
contains 'it reports the launch options' "$out" 'PROTON_USE_WOW64=1 %command%'
if grep -q '\[!!\]' <<<"$out"; then
	nope 'a healthy setup flags nothing' "$out"
else
	ok 'a healthy setup flags nothing'
fi

echo drifted > "$h/p/lib64/wine/$arch-windows/pipeasio64.dll"
out=$(HOME=$h insh "$env verify" 2>&1)
check 'a Proton tree left behind by an update fails' 1 "$?"
contains 'and names the file' "$out" 'pipeasio64.dll in the Proton tree differs'
HOME=$h insh "$v copy_into_proton" >/dev/null 2>&1

fixture_prefix "$pfx" 64
out=$(HOME=$h insh "$env verify" 2>&1)
check 'a half registration fails' 1 "$?"
contains 'and says which half is missing' "$out" 'only the 64-bit half is registered'
fixture_prefix "$pfx" both

echo rebuilt > "$h/.local/lib/wine/$arch-windows/pipeasio64.dll"
out=$(HOME=$h insh "$env verify" 2>&1)
contains 'a rebuild that was never re-registered is caught' \
	"$out" 'staged in the prefix are not the ones installed now'
echo w64 > "$h/.local/lib/wine/$arch-windows/pipeasio64.dll"

mv "$g/RS_ASIO.dll" "$g/hidden"
out=$(HOME=$h insh "$env verify" 2>&1)
check 'a missing RS_ASIO.dll fails' 1 "$?"
contains 'and is named' "$out" 'no RS_ASIO.dll in'
mv "$g/hidden" "$g/RS_ASIO.dll"

fixture_launch_options "$root" 1 '%command%'
out=$(HOME=$h insh "$env verify" 2>&1)
check 'launch options without PROTON_USE_WOW64 fail' 1 "$?"
contains 'and say what is missing' "$out" 'PROTON_USE_WOW64=1 is missing'

rm -rf "$root/userdata"
out=$(HOME=$h insh "$env verify" 2>&1)
check 'unreadable launch options are a doubt, not a failure' 0 "$?"
contains 'and are reported as such' "$out" 'could not read the Steam launch options'

summarize
