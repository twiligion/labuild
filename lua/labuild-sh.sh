#!/bin/sh
# labuild-sh.sh — Shell execution bridge for labuild (APKBUILD environment & runner)
set -e

action="$1"
[ $# -gt 0 ] && shift

# Load configuration files in order
load_configs() {
	if [ -f "/etc/abuild.conf" ]; then
		. "/etc/abuild.conf"
	fi
	if [ -n "$ABUILD_SHAREDIR" ] && [ -f "$ABUILD_SHAREDIR/default.conf" ]; then
		. "$ABUILD_SHAREDIR/default.conf"
	fi
	if [ -n "$HOME" ]; then
		if [ -f "$HOME/.config/abuild/abuild.conf" ]; then
			. "$HOME/.config/abuild/abuild.conf"
		elif [ -f "$HOME/.abuild/abuild.conf" ]; then
			. "$HOME/.abuild/abuild.conf"
		fi
	fi
}

case "$action" in
	dump)
		apkbuild="${1:-APKBUILD}"
		[ $# -gt 0 ] && shift
		load_configs
		if [ ! -f "$apkbuild" ]; then
			echo "ERROR: APKBUILD not found at $apkbuild" >&2
			exit 1
		fi

		# Default variable state
		startdir="$(CDPATH= cd -- "$(dirname -- "$apkbuild")" && pwd)"
		srcdir="${SRCDEST:-$startdir}/src"
		pkgbasedir="${PKGDEST:-$startdir}/pkg"

		# Source the APKBUILD
		cd "$startdir"
		. "$startdir/$(basename -- "$apkbuild")"

		# Print metadata
		printf "VAR\tpkgname\t%s\n" "$pkgname"
		printf "VAR\tpkgver\t%s\n" "$pkgver"
		printf "VAR\tpkgrel\t%s\n" "$pkgrel"
		printf "VAR\tpkgdesc\t%s\n" "$pkgdesc"
		printf "VAR\turl\t%s\n" "$url"
		printf "VAR\tarch\t%s\n" "$arch"
		printf "VAR\tlicense\t%s\n" "$license"
		printf "VAR\tdepends\t%s\n" "$depends"
		printf "VAR\tmakedepends\t%s\n" "$makedepends"
		printf "VAR\tcheckdepends\t%s\n" "$checkdepends"
		printf "VAR\tsubpackages\t%s\n" "$subpackages"
		printf "VAR\tsource\t%s\n" "$source"
		printf "VAR\toptions\t%s\n" "$options"
		printf "VAR\tinstall\t%s\n" "$install"
		printf "VAR\ttriggers\t%s\n" "$triggers"
		printf "VAR\tprovider_priority\t%s\n" "$provider_priority"
		printf "VAR\treplaces_priority\t%s\n" "$replaces_priority"
		printf "VAR\tinstall_if\t%s\n" "$install_if"
		printf "VAR\treplaces\t%s\n" "$replaces"
		printf "VAR\tprovides\t%s\n" "$provides"
		printf "VAR\tbuilddir\t%s\n" "${builddir:-$srcdir/$pkgname-$pkgver}"
		printf "VAR\tstartdir\t%s\n" "$startdir"
		printf "VAR\tsrcdir\t%s\n" "$srcdir"
		printf "VAR\tpkgbasedir\t%s\n" "$pkgbasedir"
		printf "VAR\tCARCH\t%s\n" "${CARCH:-$(uname -m)}"
		printf "VAR\tCHOST\t%s\n" "${CHOST:-${CARCH:-$(uname -m)}-alpine-linux-musl}"
		printf "VAR\tPACKAGER\t%s\n" "$PACKAGER"
		printf "VAR\tPACKAGER_PRIVKEY\t%s\n" "$PACKAGER_PRIVKEY"
		printf "VAR\tAPK_COMPRESSION\t%s\n" "${APK_COMPRESSION:-zstd}"
		printf "VAR\tAPK_INDEX_FILE\t%s\n" "${APK_INDEX_FILE:-Packages.adb}"
		printf "VAR\tDOC_COMPRESSION\t%s\n" "${DOC_COMPRESSION:-zstd}"

		# Check available functions
		for fn in prepare build check package; do
			if type "$fn" 2>/dev/null | grep -q 'function'; then
				printf "FUNC\t%s\n" "$fn"
			fi
		done
		for sp in $subpackages; do
			# subpackage can be "subpkg:func" or "subpkg"
			sname="${sp%%:*}"
			sfunc="${sp#*:}"
			[ "$sfunc" = "$sp" ] && sfunc=""
			if [ -n "$sfunc" ] && type "$sfunc" 2>/dev/null | grep -q 'function'; then
				printf "FUNC\t%s\n" "$sfunc"
			fi
		done
		;;

	run)
		# labuild-sh.sh run <step> <apkbuild> [subpkgdir]
		step="$1"
		[ $# -gt 0 ] && shift
		apkbuild="${1:-APKBUILD}"
		[ $# -gt 0 ] && shift
		subpkgdir_arg="$1"
		[ $# -gt 0 ] && shift

		load_configs
		startdir="$(CDPATH= cd -- "$(dirname -- "$apkbuild")" && pwd)"
		cd "$startdir"
		. "$startdir/$(basename -- "$apkbuild")"

		srcdir="${SRCDEST:-$startdir}/src"
		pkgbasedir="${PKGDEST:-$startdir}/pkg"
		pkgdir="$pkgbasedir/$pkgname"
		subpkgdir="${subpkgdir_arg:-$pkgdir}"
		builddir="${builddir:-$srcdir/$pkgname-$pkgver}"

		export startdir srcdir pkgbasedir pkgdir subpkgdir builddir
		export CARCH CHOST PACKAGER

		if [ -d "$builddir" ]; then
			cd "$builddir"
		else
			cd "$startdir"
		fi

		# Execute requested function
		if type "$step" 2>/dev/null | grep -q 'function'; then
			"$step"
		else
			case "$step" in
				default_prepare)
					if [ -d "$builddir" ]; then
						cd "$builddir"
						for i in $source; do
							case "$i" in
								*.patch)
									patch -p1 -i "$srcdir/$i" ;;
							esac
						done
					fi
					;;
				*)
					echo "Step $step is not defined or is a no-op"
					;;
			esac
		fi
		;;

	*)
		echo "Usage: labuild-sh.sh dump|run <args...>" >&2
		exit 1
		;;
esac
