#!/bin/sh
#
# tailscale-update.sh — iStoreOS / OpenWrt Tailscale updater
# ------------------------------------------------------------
# iStoreOS's iStore "Tailscale" app depends on the frozen feed packages
# tailscaled/tailscale, which are stuck at 1.80.3-1. This tool replaces
# those two binaries with the latest official *static* build from
# pkgs.tailscale.com, while leaving the OpenWrt init script and the
# /etc/config/tailscale UCI settings (and the logged-in node state)
# completely untouched.
#
# It is POSIX-sh / busybox compatible (ash on OpenWrt) and needs nothing
# beyond a downloader (curl/wget/uclient-fetch), tar, gzip and sha256.
#
# License: MIT
#
set -u

APP="tailscale-update"
PROG="$0"
BASE_URL_DEFAULT="https://pkgs.tailscale.com/stable"

# ---- paths (overridable for testing) ------------------------------------
BINDIR="${TS_BINDIR:-/usr/sbin}"
INITD="${TS_INITD:-/etc/init.d/tailscale}"
CONFDIR="${TS_CONFDIR:-/etc/tailscale}"
BACKUP_ROOT="$CONFDIR/.update-backup"
STATE_FILE="$CONFDIR/.update-state"
WORKDIR_OVERRIDE="${TS_WORKDIR:-}"
NO_SERVICE="${TS_NO_SERVICE:-0}"

# files used by the LuCI frontend (--start / --json)
LOG_FILE="${TS_LOG:-/tmp/tailscale-update.log}"
RC_FILE="${TS_RC:-/tmp/tailscale-update.rc}"
UI_STATUS_FILE="${TS_UI_STATUS:-/tmp/tailscale-update.status}"

# ---- options -------------------------------------------------------------
ARCH_OVERRIDE=""
TARGET_VERSION=""
MODE="update"          # update | check | rollback | list-backups
FORCE=0
DRY_RUN=0
ASSUME_YES=0
NO_HOLD=0
JSON_OUT=0
KEEP_BACKUPS=3
BASE_URL="$BASE_URL_DEFAULT"
CONNECT_TIMEOUT=20

# =========================================================================
# logging
# =========================================================================
if [ -t 1 ] && [ "${TS_NO_COLOR:-0}" != 1 ]; then
	C_R="$(printf '\033[31m')"; C_G="$(printf '\033[32m')"
	C_Y="$(printf '\033[33m')"; C_B="$(printf '\033[1m')"; C_0="$(printf '\033[0m')"
else
	C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi

# curl's progress meter is useful interactively but turns a redirected log
# (e.g. the LuCI background run) into garbage. Keep it only on a real tty.
if [ -t 2 ]; then CURL_QUIET=""; else CURL_QUIET="-sS"; fi

log()  { printf '%s\n' "$*"; }
info() { printf '%s[i]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
	cat <<EOF
$APP — update iStoreOS's iStore Tailscale beyond 1.80.3-1

Usage: $PROG [options]

Options:
  -c, --check             Only compare installed vs latest, change nothing.
  -v, --version <ver>     Install a specific Tailscale version (e.g. 1.102.4).
      --latest            Explicitly use the newest stable (default).
  -n, --dry-run           Show what would happen, download/install nothing.
  -f, --force             Reinstall even if already at/above target.
  -y, --yes               Do not prompt for confirmation.
  -a, --arch <arch>       Override detected arch (amd64|arm64|arm|mips|mipsle|
                          mips64|mips64le|riscv64|386).
      --base-url <url>    Alternate download mirror (must mirror the layout of
                          $BASE_URL_DEFAULT).
      --no-hold           Do not ask opkg to hold the tailscale package.
      --bindir <dir>      Binary dir (default $BINDIR).
      --workdir <dir>     Scratch dir (default: auto-picked writable dir).
      --rollback          Restore the most recent backup and restart.
      --list-backups      List available backups.
  -h, --help              This help.

Examples:
  $PROG --check
  $PROG
  $PROG -v 1.102.4
  $PROG --dry-run
  $PROG --rollback
EOF
}

# =========================================================================
# helpers
# =========================================================================
need_root() {
	# Writing to the real system dirs needs root. An overridden --bindir
	# means we are operating on a sandbox, so allow non-root there.
	[ "$BINDIR" = "/usr/sbin" ] || return 0
	[ "$(id -u 2>/dev/null || echo 1)" = "0" ] || die "must run as root (try: sudo $PROG)"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Print first line of a URL to stdout. Tries curl -> wget -> uclient-fetch.
fetch_stdout() {
	_url="$1"
	if have curl; then
		curl -fsSL --connect-timeout "$CONNECT_TIMEOUT" --retry 2 "$_url"
	elif have uclient-fetch; then
		uclient-fetch -q -O - "$_url"
	elif have wget; then
		wget -q -O - "$_url"
	else
		return 127
	fi
}

# Download URL to file. Returns non-zero on failure.
fetch_file() {
	_url="$1"; _out="$2"
	rm -f "$_out"
	if have curl; then
		curl -fSL $CURL_QUIET --connect-timeout "$CONNECT_TIMEOUT" --retry 3 -o "$_out" "$_url"
	elif have uclient-fetch; then
		uclient-fetch -q -O "$_out" "$_url"
	elif have wget; then
		wget -q -O "$_out" "$_url"
	else
		fetch_stdout "$_url" > "$_out" || { rm -f "$_out"; return 127; }
	fi
	[ -s "$_out" ]
}

# Map a package-manager arch string (preferred) or uname -m to Tailscale's.
detect_arch() {
	if [ -n "$ARCH_OVERRIDE" ]; then printf '%s\n' "$ARCH_OVERRIDE"; return 0; fi

	_owrt=""
	if have apk; then
		_owrt="$(apk --print-arch 2>/dev/null | head -n1)"
	fi
	if [ -z "$_owrt" ] && have opkg; then
		_owrt="$(opkg print-architecture 2>/dev/null | awk '/^arch /{print $2}' | tail -n1)"
	fi
	if [ -z "$_owrt" ] && have opkg-config; then
		_owrt="$(opkg-config --arch 2>/dev/null | head -n1)"
	fi

	_map() {
		case "$1" in
			x86_64|amd64)                echo amd64 ;;
			i386_*|i486_*|i586_*|i686_*|i386|i486|i586|i686) echo 386 ;;
			aarch64*)                    echo arm64 ;;
			arm*)                        echo arm ;;
			mips64el*|mips64le*)         echo mips64le ;;
			mips64*)                     echo mips64 ;;
			mipsel*)                     echo mipsle ;;
			mips_*|mips|mips32*)         echo mips ;;
			riscv64*)                    echo riscv64 ;;
			*)                           return 1 ;;
		esac
	}

	if [ -n "$_owrt" ]; then
		_arch="$(_map "$_owrt")" && { printf '%s\n' "$_arch"; return 0; }
	fi

	_arch="$(_map "$(uname -m)")" && { printf '%s\n' "$_arch"; return 0; }
	return 1
}

# latest stable version from pkgs.tailscale.com JSON
get_latest_version() {
	_j="$(fetch_stdout "$BASE_URL/?mode=json")" || return 1
	_v="$(printf '%s' "$_j" | sed -n 's/.*"TarballsVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
	[ -n "$_v" ] || return 1
	printf '%s\n' "$_v"
}

# installed version from the tailscale CLI (empty if not installed)
current_version() {
	_ts=""
	if [ -x "$BINDIR/tailscale" ]; then
		_ts="$BINDIR/tailscale"
	elif have tailscale; then
		_ts="$(command -v tailscale)"
	fi
	[ -n "$_ts" ] || return 1
	"$_ts" version 2>/dev/null | head -n1 | tr -d ' \r'
}

# is $1 strictly greater than $2 ? (dotted numeric, ignores suffixes)
version_gt() {
	awk -v a="$1" -v b="$2" 'BEGIN{
		n=split(a,x,"."); m=split(b,y,".");
		k=(n>m)?n:m;
		for(i=1;i<=k;i++){
			xi=x[i]+0; yi=y[i]+0;
			if(xi>yi){print "1"; exit}
			if(xi<yi){print "0"; exit}
		}
		print "0"
	}'
}

# pick a scratch dir with enough free space (needs ~140 MB peak)
prepare_workdir() {
	_need=150000            # KB
	if [ -n "$WORKDIR_OVERRIDE" ]; then
		mkdir -p "$WORKDIR_OVERRIDE" || die "cannot create $WORKDIR_OVERRIDE"
		printf '%s\n' "$WORKDIR_OVERRIDE"; return 0
	fi
	for d in /tmp /overlay /mnt /mnt/sda1 /etc/tailscale; do
		[ -d "$d" ] || continue
		avail="$(df -k "$d" 2>/dev/null | awk 'NR==2{print $4}')"
		[ -n "$avail" ] || continue
		if [ "$avail" -ge "$_need" ] 2>/dev/null; then
			_w="$d/tailscale-update.$$"
			mkdir -p "$_w" 2>/dev/null && { printf '%s\n' "$_w"; return 0; }
		fi
	done
	die "no scratch dir with >=150MB free (use --workdir to point at a data volume)"
}

# verify sha256 of $1 against "<base>.sha256"
verify_sha() {
	_file="$1"; _ver="$2"; _arch="$3"
	_want="$(fetch_stdout "$BASE_URL/tailscale_${_ver}_${_arch}.tgz.sha256" 2>/dev/null \
		| grep -oE '[0-9a-fA-F]{64}' | head -n1)"
	if [ -z "$_want" ]; then
		warn "no checksum published; skipping verification"
		return 0
	fi
	if have sha256sum; then
		_got="$(sha256sum "$_file" | awk '{print $1}')"
	elif have busybox; then
		_got="$(busybox sha256sum "$_file" | awk '{print $1}')"
	elif have openssl; then
		_got="$(openssl dgst -sha256 "$_file" | awk '{print $NF}')"
	else
		warn "no sha256 tool; skipping verification"
		return 0
	fi
	_want="$(printf '%s' "$_want" | tr 'A-F' 'a-f')"
	_got="$(printf '%s' "$_got" | tr 'A-F' 'a-f')"
	if [ "$_want" != "$_got" ]; then
		err "checksum mismatch!"
		err "  expected $_want"
		err "  got      $_got"
		return 1
	fi
	ok "checksum ok  sha256=$_got"
}

install_file() {
	# install_file <src> <dst> <mode>
	if have install; then
		install -m "$3" "$1" "$2"
	else
		cp -f "$1" "$2" && chmod "$3" "$2"
	fi
}

service_stop() {
	[ "$NO_SERVICE" = 1 ] && { info "skipping service stop (TS_NO_SERVICE=1)"; return 0; }
	if [ -x "$INITD" ]; then
		info "stopping tailscale service"
		"$INITD" stop >/dev/null 2>&1 || true
		# give procd a moment, then make sure nothing lingers on the old binary
		sleep 1
		if have pidof; then pidof tailscaled >/dev/null 2>&1 && { sleep 1; } ; fi
	fi
	return 0
}

service_start() {
	[ "$NO_SERVICE" = 1 ] && { info "skipping service start (TS_NO_SERVICE=1)"; return 0; }
	if [ -x "$INITD" ]; then
		info "starting tailscale service"
		"$INITD" start >/dev/null 2>&1 || "$INITD" restart >/dev/null 2>&1 || true
		sleep 2
	fi
	return 0
}

hold_package() {
	[ "$NO_HOLD" = 1 ] && return 0
	# Keep the package manager from clobbering our binaries on its next upgrade.
	if have opkg && opkg status tailscale >/dev/null 2>&1; then
		opkg flag hold tailscale tailscaled >/dev/null 2>&1 \
			&& info "opkg: tailscale/tailscaled flagged 'hold'" \
			|| warn "could not set opkg hold flag"
	fi
	# apk (OpenWrt 24.10+ / iStoreOS apk builds) has no simple hold; note it.
	if have apk && apk info -e tailscale >/dev/null 2>&1; then
		warn "apk build: 'apk upgrade' could reinstall the feed version; re-run this tool if it does"
	fi
}

# =========================================================================
# backup / restore
# =========================================================================
make_backup() {
	_cur="$1"
	_ts="$(date +%Y%m%d-%H%M%S)"
	BACKUP_DIR="$BACKUP_ROOT/$_ts"
	mkdir -p "$BACKUP_DIR" || die "cannot create backup dir $BACKUP_DIR"
	for b in tailscaled tailscale; do
		if [ -e "$BINDIR/$b" ]; then
			cp -pL "$BINDIR/$b" "$BACKUP_DIR/$b" || die "backup of $b failed"
		fi
	done
	printf 'version=%s\ndate=%s\nbindir=%s\n' "${_cur:-unknown}" "$_ts" "$BINDIR" > "$BACKUP_DIR/meta"
	ok "backup saved to $BACKUP_DIR (was ${_cur:-unknown})"
	prune_backups
}

prune_backups() {
	[ -d "$BACKUP_ROOT" ] || return 0
	_ls="$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort)"
	_n="$(printf '%s\n' "$_ls" | grep -c . )"
	[ "$_n" -le "$KEEP_BACKUPS" ] 2>/dev/null && return 0
	printf '%s\n' "$_ls" | head -n $(( _n - KEEP_BACKUPS )) | while read -r d; do
		[ -n "$d" ] && rm -rf "$d"
	done
}

latest_backup() {
	ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -n1
}

do_list_backups() {
	if [ ! -d "$BACKUP_ROOT" ] || [ -z "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]; then
		info "no backups yet"
		return 0
	fi
	log "Backups in $BACKUP_ROOT:"
	for d in "$BACKUP_ROOT"/*/; do
		[ -d "$d" ] || continue
		_v="$(sed -n 's/^version=//p' "$d/meta" 2>/dev/null)"
		printf '  %s  (%s)\n' "$(basename "$d")" "${_v:-unknown}"
	done
}

do_rollback() {
	need_root
	_b="$(latest_backup)"
	[ -n "$_b" ] || die "no backup to roll back to"
	info "rolling back from $_b"
	service_stop
	for f in tailscaled tailscale; do
		[ -f "$_b/$f" ] || continue
		install_file "$_b/$f" "$BINDIR/$f" 0755 || die "restore of $f failed"
	done
	service_start
	_v="$(current_version 2>/dev/null)"
	ok "rolled back to ${_v:-unknown}"
	if [ "$MODE" = "rollback" ]; then
		log ""
		"$BINDIR/tailscale" version 2>/dev/null || true
	fi
}

# =========================================================================
# check / update
# =========================================================================
do_check() {
	arch="$(detect_arch 2>/dev/null || true)"
	cur="$(current_version 2>/dev/null || true)"
	latest="$(get_latest_version 2>/dev/null || true)"

	if [ "$JSON_OUT" = 1 ]; then
		_upd=false
		if [ -n "$cur" ] && [ -n "$latest" ] && [ "$(version_gt "$latest" "$cur")" = "1" ]; then
			_upd=true
		fi
		printf '{"installed":"%s","latest":"%s","arch":"%s","kernel":"%s","ts_arch":"%s","update_available":%s}\n' \
			"$cur" "$latest" "$arch" "$(uname -m)" "$arch" "$_upd"
		return 0
	fi

	[ -n "$latest" ] || die "cannot reach $BASE_URL (network/DNS?)"
	log "arch          : $arch ($(uname -m))"
	log "installed     : ${cur:-not installed}"
	log "latest stable : $latest"
	if [ -z "$cur" ]; then
		info "Tailscale is not installed — nothing to update."
	elif [ "$(version_gt "$latest" "$cur")" = "1" ]; then
		ok "update available: $cur -> $latest"
	else
		ok "already up to date ($cur)"
	fi
}

do_update() {
	need_root
	arch="$(detect_arch)" || die "unsupported architecture: $(uname -m); use --arch"
	if [ -n "$TARGET_VERSION" ]; then
		latest="$TARGET_VERSION"
	else
		latest="$(get_latest_version)" || die "cannot reach $BASE_URL (network/DNS?)"
	fi
	case "$latest" in *[!0-9.]*|'') die "bad target version: '$latest'";; esac

	cur="$(current_version 2>/dev/null || true)"
	info "arch=$arch  installed=${cur:-none}  target=$latest"

	if [ -n "$cur" ] && [ "$FORCE" != 1 ] && [ "$(version_gt "$latest" "$cur")" != "1" ]; then
		ok "already up to date ($cur). use --force to reinstall."
		return 0
	fi

	tarball_name="tailscale_${latest}_${arch}.tgz"
	if [ "$DRY_RUN" = 1 ]; then
		log ""
		log "DRY RUN — would perform:"
		log "  1. download $BASE_URL/$tarball_name"
		log "  2. verify sha256 against $BASE_URL/${tarball_name}.sha256"
		log "  3. stop $INITD"
		log "  4. backup $BINDIR/{tailscale,tailscaled} -> $BACKUP_ROOT/<ts>/"
		log "  5. install both binaries"
		log "  6. start $INITD and verify"
		return 0
	fi

	if [ "$ASSUME_YES" != 1 ]; then
		printf 'Update Tailscale %s -> %s on %s? [y/N] ' "${cur:-none}" "$latest" "$arch"
		read -r _ans 2>/dev/null || _ans=n
		case "$_ans" in y|Y|yes|YES) ;; *) info "aborted"; return 0 ;; esac
	fi

	workdir="$(prepare_workdir)"
	trap 'rm -rf "$workdir"' EXIT INT TERM

	tarball="$workdir/$tarball_name"
	info "downloading $tarball_name"
	fetch_file "$BASE_URL/$tarball_name" "$tarball" || die "download failed ($tarball_name)"
	ok "downloaded $(wc -c < "$tarball" | tr -d ' ') bytes"

	verify_sha "$tarball" "$latest" "$arch" || die "refusing to install: checksum failed"

	info "extracting"
	( cd "$workdir" && tar xzf "$tarball" ) || die "extract failed"
	srcdir="$workdir/tailscale_${latest}_${arch}"
	[ -f "$srcdir/tailscaled" ] || die "tailscaled missing from archive"
	[ -f "$srcdir/tailscale" ]  || die "tailscale missing from archive"

	make_backup "$cur"

	service_stop

	# install with rollback-on-failure
	fail=0
	install_file "$srcdir/tailscaled" "$BINDIR/tailscaled" 0755 || fail=1
	[ "$fail" = 0 ] && { rm -f "$BINDIR/tailscale"; install_file "$srcdir/tailscale" "$BINDIR/tailscale" 0755 || fail=1; }
	if [ "$fail" != 0 ]; then
		err "install failed — rolling back"
		do_rollback
		die "update failed; previous version restored"
	fi
	ok "binaries installed to $BINDIR"

	service_start

	new="$(current_version 2>/dev/null || true)"
	if [ "$new" != "$latest" ]; then
		err "verification failed: '$new' != '$latest' — rolling back"
		do_rollback
		die "update failed; previous version restored"
	fi
	ok "now running Tailscale $new"

	hold_package

	mkdir -p "$CONFDIR"
	printf 'version=%s\ninstalled_at=%s\narch=%s\nbackup=%s\n' \
		"$new" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$arch" "$BACKUP_DIR" \
		> "$STATE_FILE"

	# best-effort status line
	if [ "$NO_SERVICE" != 1 ] && [ -x "$BINDIR/tailscale" ]; then
		# first meaningful (non "#" comment) line of `tailscale status`
		_st="$("$BINDIR/tailscale" status 2>&1 | awk 'NF && $0 !~ /^#/ {print; exit}')"
		[ -n "$_st" ] && info "status: $_st"
	fi
	log ""
	ok "Tailscale updated to $new  (rollback: $PROG --rollback)"
}

# =========================================================================
# background start (for the LuCI frontend)
# =========================================================================
do_start() {
	: > "$LOG_FILE"; rm -f "$RC_FILE"
	printf 'running\n' > "$UI_STATUS_FILE"
	printf '[i] %s started %s\n' "$APP" "$(date)" >> "$LOG_FILE"
	export TS_TARGET_FOR_BG="$TARGET_VERSION"
	export TS_WORKDIR_FOR_BG="$WORKDIR_OVERRIDE"
	# Detach completely so rpcd's file exec reaches pipe-EOF immediately; it
	# otherwise blocks until the whole update finishes and the browser XHR
	# times out. Prefer setsid; on OpenWrt busybox use start-stop-daemon -b
	# (its canonical "daemonize" flag), then a plain background job.
	_cmd="'$PROG' --yes --background >>'$LOG_FILE' 2>&1; echo \$? >'$RC_FILE'"
	if have setsid; then
		setsid sh -c "$_cmd" </dev/null >/dev/null 2>&1 &
	elif have start-stop-daemon; then
		start-stop-daemon -S -b -q -x /bin/sh -- -c "$_cmd" </dev/null >/dev/null 2>&1
	else
		sh -c "$_cmd" </dev/null >/dev/null 2>&1 &
	fi
	printf '{"started":true,"log":"%s"}\n' "$LOG_FILE"
}

do_background() {
	TARGET_VERSION="${TS_TARGET_FOR_BG:-$TARGET_VERSION}"
	WORKDIR_OVERRIDE="${TS_WORKDIR_FOR_BG:-$WORKDIR_OVERRIDE}"
	ASSUME_YES=1
	if ( do_update ); then
		printf 'done\n' > "$UI_STATUS_FILE"
	else
		printf 'failed\n' > "$UI_STATUS_FILE"
	fi
}

# =========================================================================
# arg parsing
# =========================================================================
parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			-c|--check)      MODE="check" ;;
			-v|--version)    shift; TARGET_VERSION="${1:-}"; [ -n "$TARGET_VERSION" ] || die "-v needs an argument" ;;
			--latest)        TARGET_VERSION="" ;;
			-n|--dry-run)    DRY_RUN=1 ;;
			-f|--force)      FORCE=1 ;;
			-y|--yes)        ASSUME_YES=1 ;;
			-a|--arch)       shift; ARCH_OVERRIDE="${1:-}"; [ -n "$ARCH_OVERRIDE" ] || die "-a needs an argument" ;;
			--base-url)      shift; BASE_URL="${1:-}"; [ -n "$BASE_URL" ] || die "--base-url needs an argument" ;;
			--no-hold)       NO_HOLD=1 ;;
			--bindir)        shift; BINDIR="${1:-}"; [ -n "$BINDIR" ] || die "--bindir needs an argument" ;;
			--workdir)       shift; WORKDIR_OVERRIDE="${1:-}" ;;
			--rollback)      MODE="rollback" ;;
			--list-backups)  MODE="list-backups" ;;
			--json)          JSON_OUT=1 ;;
			--start)         MODE="start" ;;
			--background)    MODE="background" ;;
			-h|--help)       usage; exit 0 ;;
			*)               die "unknown option: $1 (try --help)" ;;
		esac
		shift
	done
}

main() {
	parse_args "$@"
	case "$MODE" in
		check)         do_check ;;
		list-backups)  do_list_backups ;;
		rollback)      do_rollback ;;
		start)         do_start ;;
		background)    do_background ;;
		update)        do_update ;;
		*)             die "bad mode" ;;
	esac
}

main "$@"
