#!/usr/bin/env bash
#
# Rocksmith 2014 on Linux — guitar input through PipeASIO.
#
# Builds PipeASIO with its 32-bit WoW64 front end, installs it, copies it into
# the Proton tree, registers it in the game prefix, installs RS_ASIO and writes
# both config files. Steam library, game, prefix, Proton build, Wine SDK and
# the guitar input are all discovered.
#
#   rocksmith-pipeasio-setup.sh               full run
#   rocksmith-pipeasio-setup.sh --reapply     re-copy and re-register only
#   rocksmith-pipeasio-setup.sh --launch CMD  reapply if stale, then run CMD
#   rocksmith-pipeasio-setup.sh --verify      report on the install, change nothing
#   rocksmith-pipeasio-setup.sh --help
#
# Environment:
#   PROTON=/path/to/runner/files   pin the Proton build instead of picking one
#   PIPEASIO_REF=v1.7.0            pin the PipeASIO checkout instead of HEAD
#
# The Steam launch options are the one step left to the user; they are printed
# at the end.
#
# No errexit: it is silent about where it stopped and it does not fire inside
# the && chains and command substitutions this script is made of. Every command
# that matters is checked where it runs instead, so a failure comes out as a
# sentence naming what broke.

set -uo pipefail
shopt -s nullglob

readonly appid=221680
readonly pipeasio_url='https://github.com/M0n7y5/pipeasio'
readonly rs_asio_api='https://api.github.com/repos/mdias/rs_asio/releases/latest'
readonly build_log=/tmp/pipeasio-build.log
readonly reg_log=/tmp/pipeasio-reg.log
readonly local_lib=$HOME/.local/lib/wine
readonly pipeasio_cfg=$HOME/.config/pipeasio/config.ini

arch=$(uname -m)
readonly arch

# The one place that knows what PipeASIO builds, what cmake installs, and which
# Proton directory each piece belongs in. The build check, the install check,
# the copy into Proton and --verify all read this table, so the next upstream
# rename is one line here instead of four scattered lists — which is precisely
# what let the 1.7.0 rename slip through.
#
# Fields: <path under a wine lib root> <proton slot> <required|legacy>
#   legacy: pre-1.7.0 installs ship pipeasio64.dll.so instead of the
#           pipeasio64.dll + pipeasio64.so pair. Copied when present, never
#           demanded, so an old install still survives a --reapply.
readonly artifacts=(
	"i386-windows/pipeasio32.dll  w32  required"
	"$arch-windows/pipeasio64.dll w64  required"
	"$arch-unix/pipeasio32.so     u64  required"
	"$arch-unix/pipeasio64.so     u64  required"
	"$arch-unix/pipeasio64.dll.so u64  legacy"
)

# What pipeasio-register leaves in the prefix, as written by its reg add calls:
# on a 64-bit prefix the /reg:32 view lands under Wow6432Node.
readonly asio_key='[Software\\ASIO\\PipeASIO]'
readonly asio_key32='[Software\\Wow6432Node\\ASIO\\PipeASIO]'

# Discovered by main() in order, then read by the phase functions below.
family=''      # fedora | arch | debian, empty when the distro is unknown
steam_root=''
game_dir=''
prefix=''
proton=''      # the files/ (or dist/) directory holding bin/wine
proton_u64=''  # the three wine dll directories inside that tree
proton_w64=''
proton_w32=''
tmpdir=''      # the last directory handed out by new_tmpdir
tmpdirs=()     # every one of them, removed on exit whatever the exit is
verify_bad=0   # problems counted by --verify

# ---------------------------------------------------------------- output ----

say()  { printf '\n>> %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }
die()  { warn "$@"; exit 1; }

usage() {
	cat <<-EOF
		usage: ${0##*/} [--reapply | --launch CMD... | --verify | --help]

		  (no option)     build, install, register and configure everything
		  --reapply       re-copy PipeASIO into Proton and re-register it,
		                  which is what a Proton update calls for
		  --launch CMD    same, then run CMD — for Steam launch options
		  --verify        report on the current install without changing
		                  anything; exits non-zero when something is wrong
	EOF
}

# --------------------------------------------------------------- cleanup ----

cleanup() {
	(( ${#tmpdirs[@]} )) && rm -rf -- "${tmpdirs[@]}"
	return 0
}

# Creates a temp directory in $tmpdir and registers it for cleanup. It cannot
# print the path instead: a command substitution runs in a subshell, and the
# list of directories to remove would not survive it.
new_tmpdir() {
	tmpdir=$(mktemp -d) || return 1
	tmpdirs+=("$tmpdir")
}

# --------------------------------------------------------------- discovery --

# fedora, arch or debian; empty when os-release names none of them. Sourced in
# a subshell: os-release sets NAME, VERSION and friends, which we do not want.
detect_family() {
	local ids
	[[ -r /etc/os-release ]] || return 0
	ids=$(
		# shellcheck source=/dev/null
		. /etc/os-release && printf ' %s %s ' "${ID-}" "${ID_LIKE-}"
	)
	case $ids in
		*' fedora '*) printf 'fedora\n' ;;
		*' arch '*)   printf 'arch\n' ;;
		*' debian '*) printf 'debian\n' ;;
	esac
}

find_steam_root() {
	local c
	for c in "$HOME/.steam/root" "$HOME/.steam/steam" "$HOME/.local/share/Steam" \
		"$HOME/.var/app/com.valvesoftware.Steam/data/Steam"; do
		[[ -f "$c/steamapps/libraryfolders.vdf" ]] || continue
		readlink -f "$c"
		return 0
	done
	return 1
}

# Every library path, one per line, the root included.
steam_libraries() {
	grep -oP '"path"\s*"\K[^"]+' "$steam_root/steamapps/libraryfolders.vdf"
	printf '%s\n' "$steam_root"
}

# "<library>\t<installdir>" for the library actually holding the game.
find_game() {
	local lib acf installdir
	while IFS= read -r lib; do
		acf=$lib/steamapps/appmanifest_$appid.acf
		[[ -f $acf ]] || continue
		installdir=$(grep -oP '"installdir"\s*"\K[^"]+' "$acf") || return 1
		printf '%s\t%s\n' "$lib" "$installdir"
		return 0
	done < <(steam_libraries)
	return 1
}

# Every Proton build that can actually run, one per line. Globs rather than ls:
# a path with a space in it survives, and nullglob drops the empty patterns.
proton_candidates() {
	local d lib
	for d in "$steam_root"/compatibilitytools.d/*/files; do
		[[ -x $d/bin/wine ]] && printf '%s\n' "$d"
	done
	while IFS= read -r lib; do
		for d in "$lib"/steamapps/common/Proton*/files "$lib"/steamapps/common/Proton*/dist; do
			[[ -x $d/bin/wine ]] && printf '%s\n' "$d"
		done
	done < <(steam_libraries)
	return 0
}

# Prints the chosen build. Returns 2 when it is not a GE-style one: Valve's
# Proton silently ignores PROTON_USE_WOW64=1, which the 32-bit front end needs.
pick_proton() {
	local -a cands=()
	local ge
	mapfile -t cands < <(proton_candidates)
	(( ${#cands[@]} )) || return 1
	ge=$(printf '%s\n' "${cands[@]}" | grep -iE 'GE-Proton|Proton-GE|CachyOS' | sort -V | tail -1)
	if [[ -n $ge ]]; then
		printf '%s\n' "$ge"
		return 0
	fi
	printf '%s\n' "${cands[@]}" | sort -V | tail -1
	return 2
}

# $1 is a wine dll directory name. Matched under */wine/ only, so the dxvk,
# vkd3d and nvapi directories sitting next to it are not mistaken for it.
proton_dll_dir() {
	find "$proton"/lib "$proton"/lib64 "$proton"/lib32 \
		-maxdepth 3 -type d -path "*/wine/$1" -print -quit 2>/dev/null
}

resolve_proton_dirs() {
	proton_u64=$(proton_dll_dir "$arch-unix")
	proton_w64=$(proton_dll_dir "$arch-windows")
	proton_w32=$(proton_dll_dir i386-windows)
	[[ -n $proton_u64 && -n $proton_w64 && -n $proton_w32 ]]
}

# Every <arch>-windows directory that really holds the import libraries. The
# directory name alone does not settle it: Debian's amd64 Wine package ships an
# i386-windows directory with no libwinecrt0.a in it, and the real one comes
# from libwine-dev:i386 in the i386 multiarch tree.
wine_crt0_dirs() {
	find /usr/lib /usr/lib64 /usr/lib32 /opt -maxdepth 5 \
		-path '*-windows/libwinecrt0.a' 2>/dev/null | sort
}

# Where the two front ends get their import libraries. cmake takes one root and
# builds both out of it, so the interesting answers are:
#   rc 0  one tree carries both -- Arch, Fedora, WineHQ. Prints it.
#   rc 2  only i386, nothing 64-bit anywhere. Prints it; cmake will likely
#         refuse it, but naming the tree beats guessing. Arch keeps such a
#         decoy in /usr/lib32/wine beside the real /usr/lib/wine.
#   rc 3  both halves exist in two trees -- Debian multiarch. Prints the
#         32-bit root, then the 64-bit one; stitch_wine_lib_root joins them.
#   rc 1  no i386 half at all. Nothing to build the 32-bit front end from.
find_wine_lib_root() {
	local crt0 root r32='' r64=''
	while IFS= read -r crt0; do
		case $crt0 in
			*/i386-windows/libwinecrt0.a)
				root=${crt0%/i386-windows/libwinecrt0.a}
				[[ -n $r32 ]] || r32=$root ;;
			*/"$arch"-windows/libwinecrt0.a)
				root=${crt0%/"$arch"-windows/libwinecrt0.a}
				[[ -n $r64 ]] || r64=$root ;;
			*) continue ;;
		esac
		[[ -f "$root/i386-windows/libwinecrt0.a" ]] || continue
		[[ -f "$root/$arch-windows/libwinecrt0.a" ]] || continue
		printf '%s\n' "$root"
		return 0
	done < <(wine_crt0_dirs)
	[[ -n $r32 ]] || return 1
	if [[ -z $r64 ]]; then
		printf '%s\n' "$r32"
		return 2
	fi
	printf '%s\n%s\n' "$r32" "$r64"
	return 3
}

# One root out of two trees, by symlink. Only the two <arch>-windows
# directories are ever read from it (cmake/PeDriver.cmake), so there is nothing
# else to bring along.
stitch_wine_lib_root() { # dir root32 root64
	ln -s "$2/i386-windows" "$1/i386-windows" \
		&& ln -s "$3/$arch-windows" "$1/$arch-windows"
}

# ---------------------------------------------------------- dependencies ----

# Prints what is missing, one per line. Since PipeASIO 1.7.0 both front ends
# are PE modules, so the x86_64 cross-compiler is needed too, not just i686 --
# and in both languages: the driver is C, but winegcc looks for <triple>-g++
# alongside <triple>-gcc and fails the link without it.
missing_deps() {
	local cmd
	local -a missing=()
	for cmd in cmake ninja gcc pkg-config unzip git curl winegcc winebuild \
		i686-w64-mingw32-gcc i686-w64-mingw32-g++ \
		x86_64-w64-mingw32-gcc x86_64-w64-mingw32-g++; do
		command -v "$cmd" >/dev/null || missing+=("$cmd")
	done
	# Only worth asking once pkg-config exists: Fedora's pkgconf package ships
	# /usr/bin/pkgconf and nothing else -- the pkg-config name comes from
	# pkgconf-pkg-config -- so a machine missing that one would otherwise look
	# like a machine missing PipeWire.
	if command -v pkg-config >/dev/null; then
		pkg-config --atleast-version=1.4.2 libpipewire-0.3 2>/dev/null \
			|| missing+=('libpipewire-0.3 >= 1.4.2 headers')
	fi
	(( ${#missing[@]} )) || return 0
	printf '%s\n' "${missing[@]}"
	return 1
}

# The Qt6 settings panel is deliberately not built (see build_pipeasio), so
# neither Qt6 nor a native C++ compiler belongs in these sets.
install_deps() {
	local wine_devel
	local -a pkgs
	case $family in
		fedora)
			wine_devel=wine-devel
			[[ -d /opt/wine-staging ]] && wine_devel=wine-staging-devel
			[[ -d /opt/wine-stable ]] && wine_devel=wine-stable-devel
			pkgs=(
				cmake ninja-build gcc pkgconf-pkg-config unzip git curl
				pipewire-devel "$wine_devel"
				mingw32-gcc mingw32-gcc-c++ mingw64-gcc mingw64-gcc-c++
			)
			sudo dnf install -y --skip-unavailable "${pkgs[@]}"
			;;
		arch)
			pkgs=(
				cmake ninja gcc pkgconf unzip git curl
				libpipewire mingw-w64-gcc wine
			)
			sudo pacman -S --needed --noconfirm "${pkgs[@]}"
			;;
		debian)
			# The 32-bit import libraries the WoW64 front end links against only
			# exist as a foreign-architecture package here, and apt cannot even
			# see libwine-dev:i386 until dpkg has been told about i386.
			sudo dpkg --add-architecture i386
			sudo apt-get update
			pkgs=(
				cmake ninja-build gcc pkg-config unzip git curl
				libpipewire-0.3-dev wine64-tools libwine-dev libwine-dev:i386
				gcc-mingw-w64-i686 g++-mingw-w64-i686
				gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64
			)
			sudo apt-get install -y "${pkgs[@]}"
			;;
		*)
			return 1
			;;
	esac
}

ensure_deps() {
	local -a missing=()
	mapfile -t missing < <(missing_deps)
	(( ${#missing[@]} )) || return 0

	say "installing build dependencies (${family:-unknown distro})"
	install_deps || warn "the package install did not go through cleanly"

	mapfile -t missing < <(missing_deps)
	(( ${#missing[@]} )) || return 0
	printf '\n!! Still missing after the install:\n' >&2
	printf '     %s\n' "${missing[@]}" >&2
	die 'Install those and rerun.'
}

# umu-run reproduces the container Steam itself uses, which is what makes it a
# reliable way into a Proton prefix (see register_pipeasio). Deliberately kept
# out of the transaction above: it is packaged on Arch only, a missing target
# would take the whole install down with it, and registration still has the
# runner's own wine to fall back on.
install_umu() {
	case $family in
		arch)   sudo pacman -S --needed --noconfirm umu-launcher ;;
		fedora) sudo dnf install -y --skip-unavailable umu-launcher ;;
		debian) sudo apt-get install -y umu-launcher ;;
		*)      return 1 ;;
	esac
}

ensure_umu() {
	command -v umu-run >/dev/null && return 0

	say 'installing umu-launcher (the runner used to register in the prefix)'
	install_umu || warn 'umu-launcher could not be installed'

	command -v umu-run >/dev/null && return 0
	cat <<-EOF
		   !! umu-run is not available — registration falls back to Proton's own
		      wine, which runs outside its steamrt container and may fail.
		      Arch: enable [multilib] in /etc/pacman.conf. Elsewhere: .deb, .rpm
		      and a zipapp at
		      https://github.com/Open-Wine-Components/umu-launcher/releases
	EOF
}

# ------------------------------------------------------------- artifacts ----

# The Proton directory a table slot stands for.
proton_dir_for() {
	case $1 in
		u64) printf '%s\n' "$proton_u64" ;;
		w64) printf '%s\n' "$proton_w64" ;;
		w32) printf '%s\n' "$proton_w32" ;;
	esac
}

# Every required artifact absent from the tree rooted at $1, one per line.
# Feeds the build check, the install check and pipeasio_installed alike.
missing_artifacts() {
	local entry path slot kind
	for entry in "${artifacts[@]}"; do
		read -r path slot kind <<< "$entry"
		[[ $kind == required ]] || continue
		[[ -f "$1/$path" ]] || printf '%s\n' "$path"
	done
}

# ----------------------------------------------------------------- build ----

build_pipeasio() {
	local src wine_lib_root rc
	local -a clone=(--depth 1) gone=()

	wine_lib_root=$(find_wine_lib_root)
	rc=$?
	case $rc in
		1) die "No i386-windows/libwinecrt0.a anywhere — install the 32-bit half of your Wine SDK." ;;
		2) warn "$wine_lib_root carries no $arch-windows import libraries; cmake may refuse it." ;;
		3)
			new_tmpdir || die 'mktemp failed'
			stitch_wine_lib_root "$tmpdir" "${wine_lib_root%%$'\n'*}" \
				"${wine_lib_root##*$'\n'}" \
				|| die 'cannot bring the two halves of the Wine SDK together'
			say 'the Wine SDK is split across two trees here; stitched them into one'
			wine_lib_root=$tmpdir
			;;
	esac
	say "wine lib root: $wine_lib_root"

	new_tmpdir || die 'mktemp failed'
	src=$tmpdir
	: > "$build_log" || die "cannot write $build_log"

	[[ -n ${PIPEASIO_REF:-} ]] && clone+=(--branch "$PIPEASIO_REF")
	say "cloning PipeASIO ${PIPEASIO_REF:+($PIPEASIO_REF) }(build log: $build_log)"
	git clone "${clone[@]}" "$pipeasio_url" "$src/pipeasio" >>"$build_log" 2>&1 \
		|| die "git clone failed — see $build_log"

	# -G Ninja: cmake's default generator is Unix Makefiles and make is in none of
	# the package sets above, while ninja is in all three -- it is also what
	# upstream builds with. BUILD_TESTS=OFF: the test hosts are never installed
	# and only add ways for the setup to stop on something the game does not use.
	# BUILD_SETTINGS_PANEL=OFF: the Qt6 panel is a native Linux app that never
	# runs inside Proton, and building it costs Qt6 plus a C++ compiler.
	say 'building (32-bit WoW64 enabled)'
	cmake -S "$src/pipeasio" -B "$src/pipeasio/build" -G Ninja \
		-DCMAKE_BUILD_TYPE=Release -DBUILD_WOW64_32=ON -DBUILD_TESTS=OFF \
		-DBUILD_SETTINGS_PANEL=OFF -DWINE_LIB_ROOT="$wine_lib_root" \
		>>"$build_log" 2>&1 || die "cmake configure failed — see $build_log"
	cmake --build "$src/pipeasio/build" -j"$(nproc 2>/dev/null || echo 1)" \
		>>"$build_log" 2>&1 || die "cmake build failed — see $build_log"

	# PipeASIO lays its build tree out the way Wine does — <arch>-windows for
	# the PE front ends, <host>-unix for the unixlibs — not flat in build/.
	mapfile -t gone < <(missing_artifacts "$src/pipeasio/build")
	if (( ${#gone[@]} )); then
		printf '\n!! The build produced none of these — see %s\n' "$build_log" >&2
		printf '     build/%s\n' "${gone[@]}" >&2
		exit 1
	fi

	say "installing to $HOME/.local"
	cmake --install "$src/pipeasio/build" --prefix "$HOME/.local" >>"$build_log" 2>&1 \
		|| die "cmake install failed — see $build_log"
	mapfile -t gone < <(missing_artifacts "$local_lib")
	if (( ${#gone[@]} )); then
		printf '\n!! Missing under %s after the install:\n' "$local_lib" >&2
		printf '     %s\n' "${gone[@]}" >&2
		exit 1
	fi
}

pipeasio_installed() {
	local -a gone=()
	mapfile -t gone < <(missing_artifacts "$local_lib")
	(( ${#gone[@]} == 0 ))
}

# Returns 1 when the Proton tree was already current, so callers can tell a
# no-op from real work. Anything the table lists but the install does not have
# is skipped, which is how a legacy artifact costs nothing here.
copy_into_proton() {
	local entry path slot kind src dst changed=0
	for entry in "${artifacts[@]}"; do
		read -r path slot kind <<< "$entry"
		src=$local_lib/$path
		[[ -f $src ]] || continue
		dst=$(proton_dir_for "$slot")/${path##*/}
		cmp -s "$src" "$dst" && continue
		if ! cp -- "$src" "$dst"; then
			# Not fatal: --launch must never keep the game from starting, and
			# the worst case is a Proton tree still holding the old driver.
			warn "cannot write $dst — it keeps the driver it already had"
			continue
		fi
		changed=1
	done
	(( changed )) || return 1
	say 'copied PipeASIO into the Proton tree'
}

# ------------------------------------------------------------ registering ---

# pipeasio-register refuses a Proton prefix unless WINE names the runner: the
# first host-wine process in such a prefix runs Wine's prefix update, which
# rewrites the registry and system32 for the host build (pipeasio issue #22).
# umu-run is upstream's own recipe; the runner's wine is the build that owns
# the prefix already, so it stands in when umu-launcher is not installed.
find_runner() {
	local faugus=$HOME/.local/share/faugus-launcher/umu-run
	if command -v umu-run >/dev/null; then
		printf 'umu-run\n'
		return 0
	fi
	if [[ -x $faugus ]]; then
		printf '%s\n' "$faugus"
		return 0
	fi
	[[ -x "$proton/bin/wine" ]] || return 1
	printf '%s\n' "$proton/bin/wine"
}

# Registration is read back from the prefix rather than grepped out of the
# register script's log: an upstream reword or a different locale would turn a
# working setup into a scary message, and a half-done registration into a
# claimed success. Both halves leave the same two traces — the PE staged where
# the loader finds it, and the ASIO driver key in the matching registry view.
registered_64() {
	[[ -f "$prefix/drive_c/windows/system32/pipeasio64.dll" ]] \
		&& grep -qiF "$asio_key" "$prefix/system.reg" 2>/dev/null
}

registered_32() {
	[[ -f "$prefix/drive_c/windows/syswow64/pipeasio32.dll" ]] \
		&& grep -qiF "$asio_key32" "$prefix/system.reg" 2>/dev/null
}

# The staged copies are what the game loads. A rebuild that is not re-registered
# leaves them behind, and the symptom is a driver that behaves like the old one.
staged_is_current() {
	cmp -s "$local_lib/$arch-windows/pipeasio64.dll" \
		"$prefix/drive_c/windows/system32/pipeasio64.dll" \
		&& cmp -s "$local_lib/i386-windows/pipeasio32.dll" \
			"$prefix/drive_c/windows/syswow64/pipeasio32.dll"
}

register_hint() {
	printf '      WINE=umu-run PROTONPATH=%s \\\n' "${proton%/*}"
	printf '          GAMEID=umu-%s WINEPREFIX=%s \\\n' "$appid" "$prefix"
	printf '          %s\n' "$HOME/.local/bin/pipeasio-register"
}

register_pipeasio() {
	local runner
	runner=$(find_runner)
	if [[ -z $runner ]]; then
		warn 'No runner to register through — PipeASIO stays unregistered.'
		note 'Install umu-launcher, then run:'
		register_hint
		return 1
	fi

	say "registering through $runner (cancel any Wine Mono prompt)"
	# PROTONPATH is the runner directory, the parent of the files/ we copied into.
	WINEPREFIX=$prefix WINE=$runner PROTONPATH=${proton%/*} GAMEID=umu-$appid \
		"$HOME/.local/bin/pipeasio-register" >"$reg_log" 2>&1
	WINEPREFIX=$prefix "$proton/bin/wineserver" -k >/dev/null 2>&1

	if registered_32; then
		say 'registered (64-bit + 32-bit)'
		return 0
	fi
	if registered_64; then
		warn "Only the 64-bit half registered — the game is 32-bit and needs both."
	else
		warn 'Registration did not take: the prefix carries no PipeASIO ASIO key.'
	fi
	note "See $reg_log, then retry by hand through the runner:"
	register_hint
	return 1
}

# ---------------------------------------------------------------- RS_ASIO ---

# Keeps a dated copy of a file the setup is about to replace.
backup() {
	local stamp
	[[ -f $1 ]] || return 0
	stamp=$(date +%Y%m%d-%H%M%S)
	mv -- "$1" "$1.$stamp.bak" || return 1
	note "kept your previous ${1##*/} as ${1##*/}.$stamp.bak"
}

install_rs_asio() {
	local url tmp dll
	say 'installing RS_ASIO'
	url=$(curl -fsSL "$rs_asio_api" | grep -oP '"browser_download_url":\s*"\K[^"]+\.zip')
	[[ -n $url ]] || die 'Could not resolve the RS_ASIO download URL.'

	new_tmpdir || die 'mktemp failed'
	tmp=$tmpdir
	curl -fsSL "$url" -o "$tmp/rs.zip" || die "download failed: $url"
	unzip -oq "$tmp/rs.zip" -d "$tmp/x" || die 'the RS_ASIO archive would not unpack'

	# Guarded because the failure is silent and destructive: with no match
	# dirname is fed an empty string, answers ".", and the unguarded copy then
	# puts the whole current directory into the game folder.
	dll=$(find "$tmp/x" -name RS_ASIO.dll -print -quit)
	[[ -n $dll ]] || die "No RS_ASIO.dll in the archive from $url — its layout changed."
	cp -rf "${dll%/*}"/. "$game_dir"/ || die "cannot write into $game_dir"

	backup "$game_dir/RS_ASIO.ini"
	cat > "$game_dir/RS_ASIO.ini" <<-'INI' || die "cannot write $game_dir/RS_ASIO.ini"
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
	# The game rewrites Rocksmith.ini on the next start; the stale one would
	# keep pointing at the audio device from before.
	backup "$game_dir/Rocksmith.ini"
}

# ------------------------------------------------------------ PipeASIO cfg --

# A Real Tone cable names itself, so matching on the name is safe. Anything
# else would be a guess, and guessing wrong is silent: the game starts, the log
# stays clean, no signal ever arrives. Taking the first alsa_input node was
# exactly that guess — a UCM profile splits one interface into several sources
# (HiFi__Mic1__source, HiFi__Mic2__source...) and the first is not the one the
# desktop records from. An empty input_device is documented upstream as "follow
# the PipeWire default source", which is the one the user has already tested.
find_guitar_node() {
	pw-cli ls Node 2>/dev/null \
		| grep -oP 'node\.name = "\K[^"]+' \
		| grep -iE 'guitar|rocksmith|real.?tone' \
		| head -1
}

write_pipeasio_config() {
	local node inputs=2 default
	say 'detecting guitar input'
	node=$(find_guitar_node)

	# A device set by hand outlives a rerun; only autodetection overrides it.
	if [[ -z $node && -f $pipeasio_cfg ]]; then
		node=$(grep -oP '^\s*input_device\s*=\s*\K\S.*' "$pipeasio_cfg" | head -1)
		[[ -n $node ]] && say "keeping the input_device already in $pipeasio_cfg"
	fi
	[[ $node == *mono* ]] && inputs=1

	mkdir -p "${pipeasio_cfg%/*}" || die "cannot create ${pipeasio_cfg%/*}"
	cat > "$pipeasio_cfg" <<-INI || die "cannot write $pipeasio_cfg"
		[pipeasio]
		sample_rate = 48000
		buffer_size = 256
		inputs = $inputs
		outputs = 2
		input_device = $node
	INI

	if [[ -n $node ]]; then
		say "input device: $node  (inputs = $inputs)"
		return 0
	fi
	default=$(pactl get-default-source 2>/dev/null)
	say 'no Real Tone cable found — following the PipeWire default source'
	note "currently: ${default:-unknown, check with: wpctl status}"
	note 'If that is not the input your instrument is plugged into, set'
	note "input_device in $pipeasio_cfg; it is re-read live, so you can fix it"
	note 'without leaving the game. List the candidates with:'
	note '    pw-cli ls Node | grep node.name'
}

summary() {
	local runner_dir=${proton%/*}
	cat <<-EOF

		============================================================
		Setup complete. One manual step left.

		In Steam: right-click Rocksmith > Properties > General >
		Launch Options, paste exactly this (one line):

		    PROTON_USE_WOW64=1 %command%

		And under Properties > Compatibility, force:

		    ${runner_dir##*/}

		Then hit Play. Verify with:

		    grep -E "PipeASIO|ASIO Error|unixlib" "$game_dir/RS_ASIO-log.txt" | head

		"bufferSwitch" lines mean audio is streaming.

		Tune device, inputs and latency in $pipeasio_cfg; it is re-read
		live, so you can fix it without leaving the game. PipeASIO also
		has a Qt6 panel for that, not built here because it needs Qt6
		and never runs inside Proton (-DBUILD_SETTINGS_PANEL=ON).
		After a Proton update, rerun:  $0 --reapply
		============================================================

	EOF
}

# ---------------------------------------------------------------- verify ----

# Steam keeps the per-app launch options in each account's localconfig.vdf,
# under Software/Valve/Steam/apps/<appid>. That is where the one step this
# script cannot do for you lives, so --verify reads it back instead of taking
# the user's word for it.
launch_options() {
	local f
	for f in "$steam_root"/userdata/*/config/localconfig.vdf; do
		awk -v app="\"$appid\"" '
			$1 == app && !inapp { inapp = 1; depth = 0; next }
			inapp {
				depth += gsub(/{/, "{")
				depth -= gsub(/}/, "}")
				if ($1 == "\"LaunchOptions\"") {
					sub(/^[^"]*"LaunchOptions"[ \t]*"/, "")
					sub(/"[ \t]*$/, "")
					print
					exit
				}
				if (depth <= 0) inapp = 0
			}
		' "$f" 2>/dev/null
	done
}

vok()  { printf '   [ok] %s\n' "$*"; }
vbad() { printf '   [!!] %s\n' "$*"; verify_bad=$((verify_bad + 1)); }
vhuh() { printf '   [??] %s\n' "$*"; }

# Answers "is this install still good?" without starting the game. Everything
# it looks at is on disk, so it is fast and changes nothing.
verify() {
	local entry path slot kind src dst opts device
	local -a gone=()

	say 'PipeASIO build'
	mapfile -t gone < <(missing_artifacts "$local_lib")
	if (( ${#gone[@]} )); then
		vbad "not installed under $local_lib: ${gone[*]}"
	else
		vok "installed in $local_lib"
	fi

	say 'Proton tree'
	for entry in "${artifacts[@]}"; do
		read -r path slot kind <<< "$entry"
		src=$local_lib/$path
		[[ -f $src ]] || continue
		dst=$(proton_dir_for "$slot")/${path##*/}
		if [[ ! -f $dst ]]; then
			vbad "${path##*/} missing from ${dst%/*}"
		elif cmp -s "$src" "$dst"; then
			vok "${path##*/} current in ${dst%/*}"
		else
			vbad "${path##*/} in the Proton tree differs from the installed one"
		fi
	done

	say 'game prefix'
	if registered_32; then
		vok 'registered, 64-bit and 32-bit'
	elif registered_64; then
		vbad 'only the 64-bit half is registered, and the game is 32-bit'
	else
		vbad 'PipeASIO is not registered in this prefix'
	fi
	if registered_64 && ! staged_is_current; then
		vbad 'the DLLs staged in the prefix are not the ones installed now'
	fi

	say 'game directory'
	if [[ -f "$game_dir/RS_ASIO.dll" ]]; then
		vok 'RS_ASIO.dll is in place'
	else
		vbad "no RS_ASIO.dll in $game_dir"
	fi
	if [[ -f "$game_dir/RS_ASIO.ini" ]] \
		&& grep -q '^EnableAsio=1' "$game_dir/RS_ASIO.ini" \
		&& grep -q '^Driver=PipeASIO' "$game_dir/RS_ASIO.ini"; then
		vok 'RS_ASIO.ini points at PipeASIO'
	else
		vbad 'RS_ASIO.ini does not enable the PipeASIO driver'
	fi

	say 'configuration'
	if [[ -f $pipeasio_cfg ]]; then
		device=$(grep -oP '^\s*input_device\s*=\s*\K\S.*' "$pipeasio_cfg" | head -1)
		vok "input_device = ${device:-<the PipeWire default source>}"
	else
		vbad "no $pipeasio_cfg"
	fi

	opts=$(launch_options | head -1)
	if [[ -z $opts ]]; then
		vhuh 'could not read the Steam launch options for this app'
		note 'they have to contain:  PROTON_USE_WOW64=1 %command%'
	elif [[ $opts == *PROTON_USE_WOW64=1* ]]; then
		vok "launch options: $opts"
	else
		vbad "launch options are \"$opts\" — PROTON_USE_WOW64=1 is missing"
	fi

	if (( verify_bad == 0 )); then
		say 'everything checks out.'
		return 0
	fi
	warn "$verify_bad problem(s) above. A full run fixes everything but the launch options."
	return 1
}

# ------------------------------------------------------------------ main ----

# Takes the uid rather than reading $EUID so it can be tested. Under sudo the
# build would land in /root/.local and register in root's prefix, while the
# game runs as you and sees none of it. The package installs call sudo
# themselves, which is where it belongs.
refuse_root() {
	[[ $1 -eq 0 && ${ALLOW_ROOT:-0} != 1 ]] || return 0
	die 'Do not run this as root — it installs into your home directory and the
   game does not run as root either. Set ALLOW_ROOT=1 if you really mean it.'
}

# Everything the modes share: where Steam, the game and Proton are.
discover() {
	local lib installdir rc

	family=$(detect_family)

	steam_root=$(find_steam_root) || die 'Steam not found.'
	IFS=$'\t' read -r lib installdir < <(find_game) \
		|| die "Rocksmith (appid $appid) is not in any Steam library."

	game_dir=$lib/steamapps/common/$installdir
	prefix=$lib/steamapps/compatdata/$appid/pfx
	[[ -d $game_dir ]] || die "Game folder missing: $game_dir"
	[[ -d $prefix ]] || die 'Prefix missing — start the game once from Steam, quit, rerun.'
	say "game:   $game_dir"

	if [[ -n ${PROTON:-} ]]; then
		proton=$PROTON
	else
		proton=$(pick_proton)
		rc=$?
		case $rc in
			1) die 'No Proton build found. Set PROTON=... and rerun.' ;;
			2) warn "No GE-Proton or Proton-CachyOS build found. Valve's Proton silently
   ignores PROTON_USE_WOW64=1, which PipeASIO's 32-bit front end needs.
   Install GE-Proton 11.x (ProtonPlus) and rerun." ;;
		esac
	fi
	[[ -x "$proton/bin/wine" ]] || die "Not a Proton build: $proton"
	say "proton: $proton"

	# The layout moves around between builds: lib/wine here, lib64/wine there.
	resolve_proton_dirs || die "Cannot map the wine dll directories under $proton"
}

# --reapply and --launch. Under --launch nothing may stop the game starting,
# so every failure there is advisory.
reapply() {
	local launching=$1

	if ! pipeasio_installed; then
		(( launching )) || die 'PipeASIO is not installed yet — run without --reapply.'
		warn 'PipeASIO is not installed — launching without re-applying.'
		return 0
	fi
	if ! copy_into_proton; then
		say 'Proton tree already current — nothing to do.'
		return 0
	fi
	register_pipeasio
	say 're-apply done.'
	return 0
}

install_all() {
	ensure_deps
	ensure_umu
	build_pipeasio
	copy_into_proton
	register_pipeasio
	install_rs_asio
	write_pipeasio_config
	summary
}

main() {
	local mode=install

	case ${1-} in
		--reapply)    mode=reapply; shift ;;
		--verify)     mode=verify; shift ;;
		--launch)     mode=launch; shift; (( $# )) || die '--launch needs the command to run.' ;;
		-h|--help)    usage; return 0 ;;
		'')           ;;
		*)            usage >&2; die "unknown argument: $1" ;;
	esac

	refuse_root "$EUID"

	trap cleanup EXIT
	discover

	case $mode in
		reapply) reapply 0 ;;
		verify)  verify ;;
		launch)
			reapply 1
			exec "$@"
			;;
		install) install_all ;;
	esac
}

# Only when executed: sourcing the file gives a test harness the functions
# above without running any of them.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
