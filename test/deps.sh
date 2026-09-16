#!/usr/bin/env bash
#
# What the script claims to need, what it installs, and the flags it hands to
# cmake. Nothing here touches a package manager: sudo is stubbed, and so is
# command, so that missing_deps can be asked about a machine we do not have.

# The snippets handed to insh() are single-quoted on purpose: they are
# evaluated by the shell that sources the script, not by this one.
# shellcheck disable=SC2016

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT

# A shell where every tool but the named ones is on PATH, and pkg-config is
# happy. command is a regular builtin, so a function of that name shadows it.
have_all_but() {
	printf '%s\n' "command() {
		case \$2 in ${1:-@none@}) return 1 ;; esac
		return 0
	}
	pkg-config() { return 0; };"
}

# ------------------------------------------------------------ missing_deps --

r=$(insh "$(have_all_but) missing_deps; echo rc=\$?")
check 'a complete machine is missing nothing' 'rc=0' "$r"

r=$(insh "$(have_all_but ninja) missing_deps")
check 'ninja is a dependency now that cmake is driven with it' ninja "$r"

r=$(insh "$(have_all_but 'i686-w64-mingw32-g++|x86_64-w64-mingw32-g++') missing_deps")
contains 'the 32-bit mingw g++ is named' "$r" 'i686-w64-mingw32-g++'
contains 'and the 64-bit one too' "$r" 'x86_64-w64-mingw32-g++'

r=$(insh "$(have_all_but 'x86_64-w64-mingw32-gcc') missing_deps")
check 'the gcc halves are still checked' x86_64-w64-mingw32-gcc "$r"

r=$(insh "$(have_all_but pkg-config) missing_deps")
check 'a missing pkg-config is named as itself' pkg-config "$r"
lacks 'and is not reported as a missing PipeWire' "$r" libpipewire

r=$(insh "$(have_all_but) pkg-config() { return 1; }; missing_deps")
check 'old or absent PipeWire headers are reported' 'libpipewire-0.3 >= 1.4.2 headers' "$r"

r=$(insh "$(have_all_but 'cmake|gcc') missing_deps | wc -l")
check 'every missing tool is listed, not just the first' 2 "$r"

# ------------------------------------------------------------ install_deps --

# sudo is replaced by something that prints the command it was handed, one
# word per line, so a package name can be matched whole.
pkgs_for() {
	insh "family=$1; sudo() { printf '%s\n' \"\$@\"; }; install_deps"
}

for family in fedora arch debian; do
	r=$(pkgs_for "$family")
	check "$family installs ninja" 1 "$(grep -cxE 'ninja|ninja-build' <<< "$r")"
	check "$family pulls no Qt6" 0 "$(grep -ci qt6 <<< "$r")"
	check "$family pulls no native C++ compiler" 0 "$(grep -cxE 'gcc-c\+\+|g\+\+' <<< "$r")"
	check "$family still installs a C compiler" 1 "$(grep -cx gcc <<< "$r")"
done

r=$(pkgs_for fedora)
check 'Fedora asks for the package that owns /usr/bin/pkg-config' \
	1 "$(grep -cx pkgconf-pkg-config <<< "$r")"
check 'Fedora keeps both mingw C++ cross compilers' \
	2 "$(grep -cxE 'mingw(32|64)-gcc-c\+\+' <<< "$r")"

r=$(pkgs_for debian)
check 'Debian keeps all four mingw packages' 4 "$(grep -c mingw <<< "$r")"
contains 'Debian turns on the i386 architecture first' "$r" '--add-architecture'
check 'because the 32-bit Wine SDK is a foreign-arch package' \
	1 "$(grep -cx 'libwine-dev:i386' <<< "$r")"
contains 'and apt is refreshed before the install' "$r" update

r=$(pkgs_for arch)
check 'Arch gets both cross compilers from one package' 1 "$(grep -cx mingw-w64-gcc <<< "$r")"

insh 'family=nixos; install_deps'
check 'an unknown distro installs nothing and says so' 1 "$?"

# ------------------------------------------------------------------ cmake ---

# build_pipeasio truncates /tmp/pipeasio-build.log, which is a real path a real
# run writes to; put back whatever was there.
saved=
[[ -f /tmp/pipeasio-build.log ]] && saved=$w/saved.log && cp /tmp/pipeasio-build.log "$saved"

log=$w/cmake.args
h=$w/build
mkdir -p "$h"
HOME=$h insh "
	find_wine_lib_root() { printf '/usr/lib/wine\n'; }
	git() { mkdir -p \"\$4/pipeasio\"; }
	cmake() { printf '%s\n' \"\$@\" >> '$log'; }
	missing_artifacts() { :; }
	build_pipeasio" >/dev/null 2>&1

r=$(cat "$log" 2>/dev/null)
contains 'cmake is told to generate for Ninja' "$r" 'Ninja'
check 'because the default generator would need make' 1 "$(grep -cx -- '-G' <<< "$r")"
contains 'the Qt6 panel is skipped on purpose' "$r" '-DBUILD_SETTINGS_PANEL=OFF'
contains 'the test hosts too' "$r" '-DBUILD_TESTS=OFF'
contains 'the 32-bit front end is still asked for' "$r" '-DBUILD_WOW64_32=ON'
check 'configure, build and install are three calls' 3 "$(grep -cxE '\-S|--build|--install' <<< "$r")"

[[ -n $saved ]] && cp "$saved" /tmp/pipeasio-build.log

summarize
