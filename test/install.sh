#!/usr/bin/env bash
#
# The artifact table and everything that reads it, plus RS_ASIO, the PipeASIO
# config and the --reapply shortcut.

# The snippets handed to insh() are single-quoted on purpose: they are
# evaluated by the shell that sources the script, not by this one.
# shellcheck disable=SC2016

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT

# ---------------------------------------------------------- artifact table --

r=$(insh 'missing_artifacts /nonexistent | wc -l')
check 'an empty tree is missing all four required artifacts' 4 "$r"
r=$(insh 'missing_artifacts /nonexistent | grep -c "dll.so"')
check 'the legacy artifact is never demanded' 0 "$r"

h=$w/new
fixture_install "$h" new
r=$(HOME=$h insh 'missing_artifacts "$local_lib" | wc -l')
check 'a 1.7.0 install is complete' 0 "$r"
HOME=$h insh 'pipeasio_installed'
check 'pipeasio_installed agrees' 0 "$?"

rm "$h/.local/lib/wine/$arch-unix/pipeasio64.so"
r=$(HOME=$h insh 'missing_artifacts "$local_lib"')
check 'one deleted file is named' "$arch-unix/pipeasio64.so" "$r"
HOME=$h insh 'pipeasio_installed'
check 'a partial install is not an install' 1 "$?"

h=$w/old
fixture_install "$h" old
r=$(HOME=$h insh 'missing_artifacts "$local_lib" | wc -l')
check 'a pre-1.7.0 install lacks the modern 64-bit pair' 2 "$r"

# ------------------------------------------------------------ copy into Proton

h=$w/a
fixture_install "$h" new
fixture_proton_tree "$h"
v=$(proton_vars "$h")

out=$(HOME=$h insh "$v copy_into_proton; echo rc=\$?" 2>&1)
contains 'first copy reports a change' "$out" 'rc=0'
check 'four files land in the Proton tree' 4 "$(find "$h/p" -type f | wc -l)"

out=$(HOME=$h insh "$v copy_into_proton; echo rc=\$?" 2>&1)
contains 'a second copy is a no-op, rc 1' "$out" 'rc=1'

echo rebuilt > "$h/.local/lib/wine/$arch-windows/pipeasio64.dll"
out=$(HOME=$h insh "$v copy_into_proton; echo rc=\$?" 2>&1)
contains 'a rebuilt file is copied again' "$out" 'rc=0'
check 'and its content follows' rebuilt "$(cat "$h/p/lib64/wine/$arch-windows/pipeasio64.dll")"

h=$w/b
fixture_install "$h" old
fixture_proton_tree "$h"
v=$(proton_vars "$h")
HOME=$h insh "$v copy_into_proton" >/dev/null 2>&1
check 'a pre-1.7.0 install copies its three files' 3 "$(find "$h/p" -type f | wc -l)"
if [[ -f "$h/p/lib64/wine/$arch-unix/pipeasio64.dll.so" ]]; then
	ok 'including the legacy hybrid'
else
	nope 'including the legacy hybrid' 'not copied'
fi

h=$w/c
fixture_install "$h" none
fixture_proton_tree "$h"
v=$(proton_vars "$h")
out=$(HOME=$h insh "$v copy_into_proton; echo rc=\$?" 2>&1)
contains 'nothing installed means nothing to do' "$out" 'rc=1'
check 'and no file is invented' 0 "$(find "$h/p" -type f | wc -l)"

h=$w/d
fixture_install "$h" new
fixture_proton_tree "$h"
v=$(proton_vars "$h")
chmod 500 "$h/p/lib64/wine/$arch-windows"
out=$(HOME=$h insh "$v copy_into_proton; echo rc=\$?" 2>&1)
chmod 700 "$h/p/lib64/wine/$arch-windows"
contains 'an unwritable directory does not abort the copy' "$out" 'rc=0'
contains 'it warns about the file it could not write' "$out" 'it keeps the driver it already had'

# ------------------------------------------------------------------- runner --

mkdir -p "$w/bin"
printf '#!/bin/sh\n' > "$w/bin/umu-run"
chmod +x "$w/bin/umu-run"
r=$(PATH=$w/bin:$PATH insh 'proton=/nonexistent; find_runner')
check 'umu-run comes first' umu-run "$r"

h=$w/faugus
mkdir -p "$h/.local/share/faugus-launcher"
printf '#!/bin/sh\n' > "$h/.local/share/faugus-launcher/umu-run"
chmod +x "$h/.local/share/faugus-launcher/umu-run"
r=$(HOME=$h insh 'proton=/nonexistent; find_runner')
check "Faugus's bundled copy comes second" "$h/.local/share/faugus-launcher/umu-run" "$r"

p=$w/runner/files
fixture_proton_build "$p"
r=$(HOME=$w/empty insh 'proton=$1; find_runner' "$p")
check "Proton's own wine is the last resort" "$p/bin/wine" "$r"
HOME=$w/empty insh 'proton=/nonexistent; find_runner' >/dev/null
check 'no runner at all reports rc 1' 1 "$?"

out=$(insh 'proton=$1; prefix=/pfx; register_hint' "$p")
contains 'the hint points PROTONPATH at the runner directory, not files/' \
	"$out" "PROTONPATH=$w/runner "

# ------------------------------------------------------------------ RS_ASIO --

mkdir -p "$w/stub"
cat > "$w/stub/curl" <<'STUB'
#!/bin/sh
case "$*" in
	*api.github*) echo '"browser_download_url": "https://example/rs.zip"' ;;
	*) : ;;
esac
STUB
cat > "$w/stub/unzip" <<'STUB'
#!/bin/sh
for a in "$@"; do
	[ "$prev" = "-d" ] && d=$a
	prev=$a
done
mkdir -p "$d/docs"
if [ -n "$PLANT" ]; then
	mkdir -p "$d/bin"
	echo dll > "$d/bin/RS_ASIO.dll"
	echo txt > "$d/bin/README.txt"
fi
exit 0
STUB
chmod +x "$w/stub/curl" "$w/stub/unzip"

g=$w/game
mkdir -p "$g"
out=$(PATH=$w/stub:$PATH insh 'game_dir=$1; install_rs_asio' "$g" 2>&1)
check 'an archive without RS_ASIO.dll exits 1' 1 "$?"
contains 'and says the layout changed' "$out" 'its layout changed'
check 'and copies nothing into the game directory' 0 "$(find "$g" -mindepth 1 | wc -l)"

echo previous > "$g/RS_ASIO.ini"
PLANT=1 PATH=$w/stub:$PATH insh 'game_dir=$1; install_rs_asio' "$g" >/dev/null 2>&1
check 'a good archive installs cleanly' 0 "$?"
if [[ -f $g/RS_ASIO.dll && -f $g/README.txt ]]; then
	ok "the dll and its siblings are installed"
else
	nope 'the dll and its siblings are installed' "$(ls "$g")"
fi
if [[ -d $g/docs ]]; then
	nope 'only the directory holding the dll is copied' 'the archive root came too'
else
	ok 'only the directory holding the dll is copied'
fi
grep -q '^EnableAsio=1' "$g/RS_ASIO.ini"
check 'RS_ASIO.ini is written' 0 "$?"
grep -q '^\[Config\]' "$g/RS_ASIO.ini"
check 'its heredoc tabs are stripped' 0 "$?"
if [[ -n $(echo "$g"/RS_ASIO.ini.*.bak) ]]; then
	ok 'the previous RS_ASIO.ini is kept'
else
	nope 'the previous RS_ASIO.ini is kept' 'no backup'
fi

echo settings > "$g/Rocksmith.ini"
PLANT=1 PATH=$w/stub:$PATH insh 'game_dir=$1; install_rs_asio' "$g" >/dev/null 2>&1
if [[ -f $g/Rocksmith.ini ]]; then
	nope 'Rocksmith.ini is moved aside' 'still in place'
elif [[ -n $(echo "$g"/Rocksmith.ini.*.bak) ]]; then
	ok 'Rocksmith.ini is moved aside, not deleted'
else
	nope 'Rocksmith.ini is moved aside' 'gone without a backup'
fi

# ------------------------------------------------------------ PipeASIO cfg ---

mkdir -p "$w/pw"
cat > "$w/pw/pw-cli" <<'STUB'
#!/bin/sh
echo '		node.name = "alsa_input.usb-Focusrite-00.HiFi__Mic2__source"'
echo '		node.name = "alsa_input.usb-Rocksmith_USB_Guitar_Adapter-00.mono-fallback"'
STUB
chmod +x "$w/pw/pw-cli"

h=$w/cfg1
mkdir -p "$h"
HOME=$h PATH=$w/pw:$PATH insh 'write_pipeasio_config' >/dev/null 2>&1
cfg=$h/.config/pipeasio/config.ini
grep -q 'input_device = alsa_input.usb-Rocksmith_USB_Guitar_Adapter-00.mono-fallback' "$cfg"
check 'a Real Tone cable is matched by name, not by being first' 0 "$?"
grep -q '^inputs = 1' "$cfg"
check 'a mono node asks for one input' 0 "$?"
grep -q '^\[pipeasio\]' "$cfg"
check 'the config heredoc tabs are stripped' 0 "$?"

h=$w/cfg2
mkdir -p "$h/.config/pipeasio"
printf '[pipeasio]\ninput_device = chosen_by_hand\n' > "$h/.config/pipeasio/config.ini"
HOME=$h insh 'write_pipeasio_config' >/dev/null 2>&1
grep -q 'input_device = chosen_by_hand' "$h/.config/pipeasio/config.ini"
check 'a hand-set device survives a rerun' 0 "$?"

h=$w/cfg3
mkdir -p "$h"
out=$(HOME=$h insh 'write_pipeasio_config' 2>&1)
grep -q '^input_device = $' "$h/.config/pipeasio/config.ini"
check 'nothing detected leaves input_device empty' 0 "$?"
contains 'and says the default source will be followed' "$out" 'following the PipeWire default source'

# ----------------------------------------------------------------- reapply ---

out=$(HOME=$w/c insh 'reapply 0' 2>&1)
check 'reapply without an install exits 1' 1 "$?"
out=$(HOME=$w/c insh 'reapply 1' 2>&1)
check 'reapply while launching never blocks the game' 0 "$?"
contains 'and says it is skipping' "$out" 'launching without re-applying'

v=$(proton_vars "$w/a")
out=$(HOME=$w/a insh "$v reapply 0" 2>&1)
check 'reapply on a current tree exits 0' 0 "$?"
contains 'and says so' "$out" 'already current'

# ----------------------------------------------------------------- cleanup ---

d=$(insh 'trap cleanup EXIT; new_tmpdir; printf "%s" "$tmpdir"')
if [[ -d $d ]]; then
	nope 'temp directories are removed on exit' "$d survived"
else
	ok 'temp directories are removed on exit'
fi

summarize
