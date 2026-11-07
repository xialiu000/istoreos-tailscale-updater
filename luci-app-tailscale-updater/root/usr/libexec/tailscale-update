#!/bin/sh
#
# tailscale-update.sh — iStoreOS / OpenWrt Tailscale updater
# ------------------------------------------------------------
# Two install models are supported and auto-detected:
#
#   static  legacy iStore "Tailscale" app: frozen feed packages
#           tailscaled/tailscale (1.80.3-1). Replaces those two binaries with
#           the latest official *static* build from pkgs.tailscale.com and
#           pins the legacy packages with opkg "hold".
#
#   pkg     "Tailscale (community edition)" / feed package "tailscale".
#           The community build (GuNanOvO/openwrt-tailscale) ships ONE UPX
#           binary plus a "tailscale" symlink, and is built with
#           ts_omit_clientupdate, so "tailscale update" is unavailable.
#           The package manager owns the binaries, so this tool refreshes
#           the feed index and upgrades the package (opkg/apk) instead of
#           swapping files. No hold is set, otherwise it would block
#           future feed upgrades.
#
# In both modes the OpenWrt init script and the /etc/config/tailscale UCI
# settings (and the logged-in node state) are left untouched.
#
# POSIX-sh / busybox compatible (ash on OpenWrt).
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

# auto-update config (UCI package: tailscale-updater)
CONFIG_FILE="${TS_CONFIG:-/etc/config/tailscale-updater}"
AUTO_LOG="${TS_AUTO_LOG:-/tmp/tailscale-update-auto.log}"
CRON_FILE="${TS_CRON_FILE:-/etc/crontabs/root}"

# ---- options -------------------------------------------------------------
ARCH_OVERRIDE=""
TARGET_VERSION=""
MODE="update"          # update | check | rollback | list-backups
MODE_OVERRIDE="${TS_MODE:-auto}"   # auto | static | pkg
INSTALL_MODE="static"  # resolved: static | pkg
PKG_MGR=""             # opkg | apk | ""
PKG_NAME="tailscale"
LEGACY_MAX_VERSION="1.80.3"
LEGACY_DETECTED=1      # 1 = frozen legacy build / manual binaries
FORCE=0
DRY_RUN=0
ASSUME_YES=0
NO_HOLD=0
JSON_OUT=0
AUTO_SET=""
AUTO_TIME=""
SOURCE_SET=""
KEEP_BACKUPS=3
BASE_URL="$BASE_URL_DEFAULT"
CONNECT_TIMEOUT=20

# runtime guards
LOCKDIR="${TS_LOCK:-/tmp/tailscale-update.lock}"
LOCK_HELD=0
CLEANUP_DIRS=""

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
$APP — keep Tailscale up to date on iStoreOS / OpenWrt

Auto-detects how Tailscale was installed:
  static  legacy iStore "Tailscale" app (frozen 1.80.3-1) -> replace binaries
  pkg     "Tailscale (community edition)" feed package   -> upgrade package

Usage: $PROG [options]

Options:
  -c, --check             Only compare installed vs available, change nothing.
  -v, --version <ver>     Install a specific version (static mode only).
      --latest            Explicitly use the newest stable (default).
  -n, --dry-run           Show what would happen, download/install nothing.
  -f, --force             Reinstall even if already at/above target.
  -y, --yes               Do not prompt for confirmation.
  -a, --arch <arch>       Override detected arch (amd64|arm64|arm|mips|mipsle|
                          mips64|mips64le|riscv64|386).
      --mode <auto|static|pkg>
                          Override install-mode auto-detection.
      --static            Same as --mode static (binary replacement).
      --pkg               Same as --mode pkg (package manager upgrade).
      --official          Community install: use official Tailscale static
                          binaries instead of the community build.
      --set-source <feed|official>
                          Persist the update source for community installs.
      --base-url <url>    Alternate download mirror (must mirror the layout of
                          $BASE_URL_DEFAULT).
      --no-hold           Do not pin the legacy packages with opkg 'hold'.
      --bindir <dir>      Binary dir (default $BINDIR).
      --workdir <dir>     Scratch dir (default: auto-picked writable dir).
      --rollback          Restore the most recent backup and restart.
      --list-backups      List available backups.
      --auto              One automatic check+update (for the cron job).
      --set-auto <0|1> [HH:MM]
                          Enable/disable the daily auto-update job.
  -h, --help              This help.

Examples:
  $PROG --check
  $PROG                       # auto-detected update
  $PROG --mode pkg -y         # force package-manager upgrade
  $PROG --mode static -v 1.102.4
  $PROG --dry-run
  $PROG --rollback
EOF
}

# =========================================================================
# helpers
# =========================================================================
need_root() {
	[ "$BINDIR" = "/usr/sbin" ] || return 0
	[ "$(id -u 2>/dev/null || echo 1)" = "0" ] || die "must run as root (try: sudo $PROG)"
}

have() { command -v "$1" >/dev/null 2>&1; }

cleanup_run() {
	for _p in $CLEANUP_DIRS; do
		[ -n "$_p" ] && rm -rf "$_p"
	done
	rm -rf "$LOCKDIR"
}

# Single-instance guard: updates, auto-updates and rollbacks must not overlap.
acquire_lock() {
	[ "$LOCK_HELD" = 1 ] && return 0
	if mkdir "$LOCKDIR" 2>/dev/null; then
		printf '%s\n' "$$" > "$LOCKDIR/pid"
		LOCK_HELD=1
		trap 'cleanup_run' EXIT INT TERM
		return 0
	fi
	_pid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
	if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
		die "another update/rollback is already running (pid $_pid)"
	fi
	rm -rf "$LOCKDIR"
	mkdir "$LOCKDIR" 2>/dev/null || die "cannot create lock $LOCKDIR"
	printf '%s\n' "$$" > "$LOCKDIR/pid"
	LOCK_HELD=1
	trap 'cleanup_run' EXIT INT TERM
}

sha256_of_file() {
	_f="$1"
	if have sha256sum; then
		sha256sum "$_f" | awk '{print $1}'
	elif have busybox; then
		busybox sha256sum "$_f" | awk '{print $1}'
	elif have openssl; then
		openssl dgst -sha256 "$_f" | awk '{print $NF}'
	else
		return 1
	fi
}

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

get_latest_version() {
	_j="$(fetch_stdout "$BASE_URL/?mode=json")" || return 1
	_v="$(printf '%s' "$_j" | sed -n 's/.*"TarballsVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
	[ -n "$_v" ] || return 1
	printf '%s\n' "$_v"
}

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

# =========================================================================
# install-mode detection (legacy static build vs community feed package)
# =========================================================================
apk_pkg_version() {
	_n="$1"
	_v="$(apk info -v "$_n" 2>/dev/null | head -n1 | tr -d '\r')"
	case "$_v" in
		"$_n"-*) printf '%s\n' "${_v#$_n-}"; return 0 ;;
	esac
	_v="$(apk info "$_n" 2>/dev/null | head -n1 | awk '{print $1}')"
	case "$_v" in
		"$_n"-*) printf '%s\n' "${_v#$_n-}"; return 0 ;;
	esac
	return 1
}

pkg_installed_version() {
	_n="$1"
	if have opkg; then
		_v="$(opkg status "$_n" 2>/dev/null | sed -n 's/^Version:[[:space:]]*//p' | head -n1)"
		[ -n "$_v" ] && { printf '%s\n' "$_v"; return 0; }
	fi
	if have apk; then
		apk_pkg_version "$_n" && return 0
	fi
	return 1
}

pkg_mgr() {
	if have apk && { [ -f /lib/apk/db/installed ] || apk info -e "$PKG_NAME" >/dev/null 2>&1; }; then
		printf 'apk\n'; return 0
	fi
	if have opkg; then printf 'opkg\n'; return 0; fi
	if have apk; then printf 'apk\n'; return 0; fi
	return 1
}

pkg_candidate_version() {
	_n="$1"
	_best=""
	case "$PKG_MGR" in
		opkg)
			for _v in $(opkg list "$_n" 2>/dev/null | awk 'NF>=3 {print $3}'); do
				if [ -z "$_best" ] || [ "$(version_gt "$_v" "$_best")" = "1" ]; then _best="$_v"; fi
			done
			;;
		apk)
			for _v in $(apk list "$_n" 2>/dev/null | awk '{print $1}' | sed -n "s/^${_n}-//p"); do
				if [ -z "$_best" ] || [ "$(version_gt "$_v" "$_best")" = "1" ]; then _best="$_v"; fi
			done
			;;
	esac
	[ -n "$_best" ] && printf '%s\n' "$_best"
}

pkg_refresh() {
	case "$PKG_MGR" in
		opkg) opkg update >/dev/null 2>&1 ;;
		apk)  apk update  >/dev/null 2>&1 ;;
	esac
}

run_pkg_upgrade() {
	case "$PKG_MGR" in
		opkg) opkg install "$PKG_NAME" ;;
		apk)  apk add --upgrade "$PKG_NAME" ;;
		*)    return 1 ;;
	esac
}

detect_install_mode() {
	if [ "$MODE_OVERRIDE" != "auto" ]; then
		printf '%s\n' "$MODE_OVERRIDE"
		return 0
	fi

	_comm="$(pkg_installed_version "$PKG_NAME" 2>/dev/null || true)"
	_legacy="$(pkg_installed_version tailscaled 2>/dev/null || true)"

	if [ -n "$_legacy" ] && [ -z "$_comm" ]; then
		printf 'static\n'; return 0
	fi
	if [ -n "$_comm" ]; then
		if [ "$(version_gt "$_comm" "$LEGACY_MAX_VERSION")" = "1" ]; then
			_src="$(cfg_get update_source 2>/dev/null || true)"
			if [ "$_src" = "official" ]; then
				printf 'official\n'
			else
				printf 'pkg\n'
			fi
		else
			printf 'static\n'
		fi
		return 0
	fi
	printf 'static\n'
}

resolve_mode() {
	INSTALL_MODE="$(detect_install_mode)"
	PKG_MGR="$(pkg_mgr 2>/dev/null || true)"
	if [ "$INSTALL_MODE" = "pkg" ] && [ -z "$PKG_MGR" ]; then
		warn "package mode requested but no opkg/apk found; using static binaries"
		INSTALL_MODE="static"
	fi

	LEGACY_DETECTED=1
	_comm="$(pkg_installed_version "$PKG_NAME" 2>/dev/null || true)"
	_legacy="$(pkg_installed_version tailscaled 2>/dev/null || true)"
	if [ -z "$_legacy" ] && [ -n "$_comm" ] && [ "$(version_gt "$_comm" "$LEGACY_MAX_VERSION")" = "1" ]; then
		LEGACY_DETECTED=0
	fi
}

mode_label() {
	case "$INSTALL_MODE" in
		pkg)      printf 'package manager (%s, community edition)\n' "${PKG_MGR:-?}" ;;
		official) printf 'official static binaries (community package pinned)\n' ;;
		*)        printf 'static binaries (legacy 1.80.3-1 build)\n' ;;
	esac
}

# =========================================================================
# auto-update config / cron
# =========================================================================
cfg_get() {
	_k="$1"
	if have uci; then
		_v="$(uci -q get "tailscale-updater.settings.$_k" 2>/dev/null || true)"
		[ -n "$_v" ] && { printf '%s\n' "$_v"; return 0; }
	fi
	[ -f "$CONFIG_FILE" ] || return 1
	_v="$(sed -n "s/^[[:space:]]*option[[:space:]]*${_k}[[:space:]]*'\([^']*\)'.*/\1/p" "$CONFIG_FILE" | head -n1)"
	[ -n "$_v" ] || _v="$(sed -n "s/^[[:space:]]*option[[:space:]]*${_k}[[:space:]]*\([^[:space:]]*\).*/\1/p" "$CONFIG_FILE" | head -n1)"
	[ -n "$_v" ] || return 1
	printf '%s\n' "$_v"
}

is_auto_enabled() {
	[ "$(cfg_get auto_update 2>/dev/null || echo 0)" = "1" ]
}

auto_time() {
	_t="$(cfg_get auto_update_time 2>/dev/null || true)"
	[ -n "$_t" ] || _t="03:00"
	printf '%s\n' "$_t"
}

install_cron() {
	_t="$1"
	_hh="${_t%%:*}"
	_mm="${_t#*:}"
	_self="$PROG"
	case "$_self" in
		*/*) ;;
		*) _self="$(command -v "$PROG" 2>/dev/null || printf '%s' "$PROG")" ;;
	esac
	case "$_self" in
		/*) ;;
		*) _self="$(cd "$(dirname "$_self")" 2>/dev/null && pwd)/$(basename "$_self")" ;;
	esac
	_line="$_mm $_hh * * * $_self --auto >/dev/null 2>&1"
	mkdir -p "$(dirname "$CRON_FILE")" || die "cannot create $(dirname "$CRON_FILE")"
	[ -f "$CRON_FILE" ] || : > "$CRON_FILE"
	_tmp="$CRON_FILE.tsup.$$"
	grep -v 'tailscale-update --auto' "$CRON_FILE" | grep -v 'tailscale-updater auto-update' > "$_tmp" 2>/dev/null || true
	printf '%s\n# tailscale-updater auto-update\n' "$_line" >> "$_tmp"
	cat "$_tmp" > "$CRON_FILE"
	rm -f "$_tmp"
	[ -x /etc/init.d/cron ] && /etc/init.d/cron restart >/dev/null 2>&1 || true
	info "cron job installed: $_line"
}

remove_cron() {
	[ -f "$CRON_FILE" ] || return 0
	_tmp="$CRON_FILE.tsup.$$"
	grep -v 'tailscale-update --auto' "$CRON_FILE" | grep -v 'tailscale-updater auto-update' > "$_tmp" 2>/dev/null || true
	cat "$_tmp" > "$CRON_FILE"
	rm -f "$_tmp"
	[ -x /etc/init.d/cron ] && /etc/init.d/cron restart >/dev/null 2>&1 || true
	info "cron job removed"
}

set_auto() {
	_en="$1"; _t="$2"
	_src="$(cfg_get update_source 2>/dev/null || echo feed)"
	[ -n "$_t" ] || _t="$(auto_time)"
	case "$_t" in
		[0-2][0-9]:[0-5][0-9]) ;;
		*) die "bad time '$_t' (use HH:MM)" ;;
	esac
	case "$_en" in 0|1) ;; *) die "auto-update value must be 0 or 1" ;; esac

	if have uci; then
		mkdir -p "$(dirname "$CONFIG_FILE")"
		[ -f "$CONFIG_FILE" ] || : > "$CONFIG_FILE"
		uci -q get tailscale-updater.settings >/dev/null 2>&1 || uci set tailscale-updater.settings=settings 2>/dev/null
		uci set tailscale-updater.settings.auto_update="$_en" 2>/dev/null
		uci set tailscale-updater.settings.auto_update_time="$_t" 2>/dev/null
		uci commit tailscale-updater 2>/dev/null
		if [ "$(uci -q get tailscale-updater.settings.auto_update 2>/dev/null)" != "$_en" ]; then
			warn "uci write failed; writing config file directly"
			{
				echo "config settings 'settings'"
				echo "	option auto_update '$_en'"
				echo "	option auto_update_time '$_t'"
				echo "	option update_source '$_src'"
			} > "$CONFIG_FILE"
		fi
	else
		mkdir -p "$(dirname "$CONFIG_FILE")"
		{
			echo "config settings 'settings'"
			echo "	option auto_update '$_en'"
			echo "	option auto_update_time '$_t'"
			echo "	option update_source '$_src'"
		} > "$CONFIG_FILE"
	fi

	if [ "$_en" = "1" ]; then
		install_cron "$_t"
	else
		remove_cron
	fi
	ok "auto-update=$_en time=$_t"
}

set_source() {
	_src="$1"
	case "$_src" in feed|official) ;; *) die "source must be feed or official" ;; esac
	_en="$(cfg_get auto_update 2>/dev/null || echo 0)"
	_t="$(auto_time)"
	if have uci; then
		mkdir -p "$(dirname "$CONFIG_FILE")"
		[ -f "$CONFIG_FILE" ] || : > "$CONFIG_FILE"
		uci -q get tailscale-updater.settings >/dev/null 2>&1 || uci set tailscale-updater.settings=settings 2>/dev/null
		uci set tailscale-updater.settings.update_source="$_src" 2>/dev/null
		uci set tailscale-updater.settings.auto_update="$_en" 2>/dev/null
		uci set tailscale-updater.settings.auto_update_time="$_t" 2>/dev/null
		uci commit tailscale-updater 2>/dev/null
		if [ "$(uci -q get tailscale-updater.settings.update_source 2>/dev/null)" != "$_src" ]; then
			warn "uci write failed; writing config file directly"
			{
				echo "config settings 'settings'"
				echo "	option auto_update '$_en'"
				echo "	option auto_update_time '$_t'"
				echo "	option update_source '$_src'"
			} > "$CONFIG_FILE"
		fi
	else
		mkdir -p "$(dirname "$CONFIG_FILE")"
		{
			echo "config settings 'settings'"
			echo "	option auto_update '$_en'"
			echo "	option auto_update_time '$_t'"
			echo "	option update_source '$_src'"
		} > "$CONFIG_FILE"
	fi
	if [ "$_src" = "feed" ] && have opkg; then
		opkg flag ok "$PKG_NAME" tailscaled >/dev/null 2>&1 || true
		info "cleared opkg hold on $PKG_NAME"
	fi
	ok "update source=$_src"
}

do_auto() {
	if ! is_auto_enabled; then
		info "auto-update disabled; nothing to do"
		return 0
	fi
	mkdir -p "$(dirname "$AUTO_LOG")"
	printf '\n[%s] auto-update start\n' "$(date)" >> "$AUTO_LOG"
	ASSUME_YES=1
	if ( do_update ) >> "$AUTO_LOG" 2>&1; then
		printf '[%s] auto-update done\n' "$(date)" >> "$AUTO_LOG"
		if have logger; then logger -t tailscale-update "auto-update done"; fi
	else
		printf '[%s] auto-update failed\n' "$(date)" >> "$AUTO_LOG"
		if have logger; then logger -t tailscale-update "auto-update failed; see $AUTO_LOG"; fi
		return 1
	fi
}

# =========================================================================
# static-mode helpers
# =========================================================================
prepare_workdir() {
	_need=150000
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

service_health() {
	[ "$NO_SERVICE" = 1 ] && return 0
	[ -x "$INITD" ] || return 0
	if "$INITD" status 2>/dev/null | grep -q running; then
		info "service is running"
	else
		warn "service is not running; run '$INITD status' and check logs"
	fi
}

hold_package() {
	[ "$NO_HOLD" = 1 ] && return 0

	case "$INSTALL_MODE" in
		pkg)
			info "package-managed install detected; no hold set (feed upgrades stay enabled)"
			return 0
			;;
		official)
			if have opkg && opkg status "$PKG_NAME" >/dev/null 2>&1; then
				opkg flag hold "$PKG_NAME" >/dev/null 2>&1 \
					&& info "opkg: official binaries pinned; '$PKG_NAME' package held" \
					|| warn "could not set opkg hold flag"
			fi
			if have apk && apk info -e "$PKG_NAME" >/dev/null 2>&1; then
				warn "apk: cannot hold a package; '$PKG_MGR upgrade' may restore the community build"
			fi
			return 0
			;;
	esac

	if [ "$LEGACY_DETECTED" != 1 ]; then
		info "no package hold needed"
		return 0
	fi

	if have opkg && opkg status "$PKG_NAME" >/dev/null 2>&1; then
		opkg flag hold "$PKG_NAME" tailscaled >/dev/null 2>&1 \
			&& info "opkg: legacy tailscale/tailscaled pinned with 'hold'" \
			|| warn "could not set opkg hold flag"
	elif have opkg && opkg status tailscaled >/dev/null 2>&1; then
		opkg flag hold tailscaled >/dev/null 2>&1 \
			&& info "opkg: legacy tailscaled pinned with 'hold'" \
			|| warn "could not set opkg hold flag"
	fi
	if have apk && { apk info -e "$PKG_NAME" >/dev/null 2>&1 || apk info -e tailscaled >/dev/null 2>&1; }; then
		warn "apk: legacy mode has no hold; if 'apk upgrade' restores the feed build, re-run this tool"
	fi
}

# =========================================================================
# backup / restore
# =========================================================================
verify_backup_file() {
	_d="$1"; _f="$2"
	[ -f "$_d/$_f" ] || { err "backup missing $_f"; return 1; }
	_bwant="$(sed -n "s/^sha256_${_f}=//p" "$_d/meta" 2>/dev/null | head -n1)"
	[ -n "$_bwant" ] || { warn "no checksum recorded for $_f; skipping"; return 0; }
	_bgot="$(sha256_of_file "$_d/$_f" 2>/dev/null || true)"
	[ -n "$_bgot" ] || { warn "no sha256 tool; skipping"; return 0; }
	[ "$_bwant" = "$_bgot" ] || { err "backup $_f checksum mismatch"; return 1; }
	ok "backup $_f checksum ok"
}

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
	_sha_ts=""; _sha_cli=""
	[ -f "$BACKUP_DIR/tailscaled" ] && _sha_ts="$(sha256_of_file "$BACKUP_DIR/tailscaled" 2>/dev/null || true)"
	[ -f "$BACKUP_DIR/tailscale" ] && _sha_cli="$(sha256_of_file "$BACKUP_DIR/tailscale" 2>/dev/null || true)"
	printf 'mode=static\nversion=%s\ndate=%s\nbindir=%s\nsha256_tailscaled=%s\nsha256_tailscale=%s\n' \
		"${_cur:-unknown}" "$_ts" "$BINDIR" "$_sha_ts" "$_sha_cli" > "$BACKUP_DIR/meta"
	ok "backup saved to $BACKUP_DIR (was ${_cur:-unknown})"
	prune_backups
}

make_pkg_backup() {
	_pv="$1"; _bv="$2"
	_ts="$(date +%Y%m%d-%H%M%S)"
	BACKUP_DIR="$BACKUP_ROOT/$_ts"
	mkdir -p "$BACKUP_DIR" || die "cannot create backup dir $BACKUP_DIR"
	printf 'mode=pkg\ntype=meta\npkg_manager=%s\npkg_version=%s\nversion=%s\ndate=%s\n' \
		"$PKG_MGR" "$_pv" "${_bv:-unknown}" "$_ts" > "$BACKUP_DIR/meta"
	ok "package checkpoint saved (was ${_pv:-unknown})"
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

# Newest backup that actually contains binaries (skip package checkpoints).
rollback_target() {
	_cur="$(current_version 2>/dev/null || true)"
	for _d in $(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort -r); do
		[ -s "$_d/tailscaled" ] || continue
		_m="$(sed -n 's/^mode=//p' "$_d/meta" 2>/dev/null)"
		[ "$_m" = "pkg" ] && continue
		_v="$(sed -n 's/^version=//p' "$_d/meta" 2>/dev/null)"
		[ -n "$_v" ] || continue
		if [ -n "$_cur" ] && [ "$(version_gt "$_cur" "$_v")" != "1" ]; then
			continue
		fi
		printf '%s\n' "$_d"
		return 0
	done
	return 1
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
		_m="$(sed -n 's/^mode=//p' "$d/meta" 2>/dev/null)"
		printf '  %s  (%s, %s)\n' "$(basename "$d")" "${_v:-unknown}" "${_m:-static}"
	done
}

do_rollback() {
	need_root
	acquire_lock
	if have pgrep && pgrep -f 'tailscale-update --background' >/dev/null 2>&1; then
		die "an update is still running; wait for it to finish before rolling back"
	fi
	_b="$(rollback_target)"
	if [ -z "$_b" ]; then
		info "no older backup available (current $(current_version 2>/dev/null || echo unknown)); nothing to roll back"
		return 0
	fi
	_want="$(sed -n 's/^version=//p' "$_b/meta" 2>/dev/null)"
	info "rolling back from $_b (target ${_want:-unknown})"

	verify_backup_file "$_b" tailscaled || die "refusing to restore corrupt backup"
	if [ -f "$_b/tailscale" ]; then
		verify_backup_file "$_b" tailscale || die "refusing to restore corrupt backup"
	fi

	service_stop
	for f in tailscaled tailscale; do
		[ -f "$_b/$f" ] || continue
		install_file "$_b/$f" "$BINDIR/$f" 0755 || die "restore of $f failed"
	done
	service_start
	_v="$(current_version 2>/dev/null)"
	if [ -n "$_want" ] && [ "$_v" != "$_want" ]; then
		err "rollback verification failed: running '${_v:-unknown}' != backup '$_want'"
		service_health
		return 1
	fi
	ok "rolled back to ${_v:-unknown}"
	service_health
	if [ "$MODE" = "rollback" ]; then
		log ""
		"$BINDIR/tailscale" version 2>/dev/null || true
	fi
}

do_rollback_pkg() {
	_b="$1"
	_pm="$(sed -n 's/^pkg_manager=//p' "$_b/meta" 2>/dev/null)"
	_pv="$(sed -n 's/^pkg_version=//p' "$_b/meta" 2>/dev/null)"
	[ -n "$_pv" ] || die "package checkpoint has no version"
	[ -n "$_pm" ] || _pm="$PKG_MGR"
	info "package rollback: asking $_pm for tailscale $_pv"
	service_stop
	case "$_pm" in
		opkg) opkg install "tailscale=$_pv" ;;
		apk)  apk add "tailscale=$_pv" ;;
		*)    service_start; die "unknown package manager '$_pm'" ;;
	esac || {
		service_start
		die "package rollback failed (old version may no longer be in the feed); install the old .ipk manually"
	}
	service_start
	_v="$(current_version 2>/dev/null)"
	ok "rolled back to package $_pv (running ${_v:-unknown})"
}

# =========================================================================
# check / update
# =========================================================================
do_check() {
	resolve_mode
	arch="$(detect_arch 2>/dev/null || true)"
	cur="$(current_version 2>/dev/null || true)"
	latest=""
	pkg_cur=""
	pkg_cand=""
	cand_older=false

	if [ "$INSTALL_MODE" = "pkg" ]; then
		pkg_refresh || true
		pkg_cur="$(pkg_installed_version "$PKG_NAME" 2>/dev/null || true)"
		pkg_cand="$(pkg_candidate_version "$PKG_NAME" 2>/dev/null || true)"
		_base="$cur"
		[ -z "$_base" ] && _base="$pkg_cur"
		if [ -n "$pkg_cand" ] && [ -n "$_base" ] && [ "$(version_gt "$pkg_cand" "$_base")" = "1" ]; then
			latest="$pkg_cand"
		else
			latest="$_base"
			if [ -n "$pkg_cand" ] && [ -n "$_base" ] && [ "$(version_gt "$_base" "$pkg_cand")" = "1" ]; then
				cand_older=true
			fi
		fi
	else
		latest="$(get_latest_version 2>/dev/null || true)"
	fi

	if [ "$JSON_OUT" = 1 ]; then
		_upd=false
		_base="$cur"
		[ -z "$_base" ] && _base="$pkg_cur"
		if [ -n "$_base" ] && [ -n "$latest" ] && [ "$(version_gt "$latest" "$_base")" = "1" ]; then
			_upd=true
		fi
		case "$INSTALL_MODE" in
			pkg) _src="feed" ;;
			official) _src="official" ;;
			*) _src="static" ;;
		esac
		_pref="$(cfg_get update_source 2>/dev/null || echo feed)"
		_au=false; is_auto_enabled && _au=true
		_at="$(auto_time)"
		_cron=false
		if [ -f "$CRON_FILE" ] && grep -q 'tailscale-update --auto' "$CRON_FILE" 2>/dev/null; then
			_cron=true
		fi
		_rb="$(rollback_target 2>/dev/null || true)"
		_can=false; _rv=""
		if [ -n "$_rb" ]; then
			_can=true
			_rv="$(sed -n 's/^version=//p' "$_rb/meta" 2>/dev/null)"
		fi
		printf '{"mode":"%s","pkg_manager":"%s","installed":"%s","latest":"%s","candidate":"%s","candidate_is_older":%s,"arch":"%s","kernel":"%s","ts_arch":"%s","source":"%s","update_source":"%s","auto_update":%s,"auto_update_time":"%s","cron_installed":%s,"can_rollback":%s,"rollback_version":"%s","update_available":%s}\n' \
			"$INSTALL_MODE" "${PKG_MGR:-}" "$cur" "$latest" "$pkg_cand" "$cand_older" "$arch" "$(uname -m)" "$arch" "$_src" "$_pref" "$_au" "$_at" "$_cron" "$_can" "$_rv" "$_upd"
		return 0
	fi

	log "install mode  : $(mode_label)"
	if [ "$INSTALL_MODE" = "pkg" ]; then
		[ -n "$latest" ] || warn "cannot read a candidate version from the feed index"
		log "package       : ${pkg_cur:-not installed}"
	else
		[ -n "$latest" ] || die "cannot reach $BASE_URL (network/DNS?)"
	fi
	log "arch          : $arch ($(uname -m))"
	log "installed     : ${cur:-not installed}"
	if [ "$INSTALL_MODE" = "pkg" ]; then
		log "feed candidate: ${pkg_cand:-unknown}"
		if [ "$cand_older" = true ]; then
			warn "configured feeds only have $pkg_cand (< installed ${cur:-$pkg_cur}); add the community feed for newer versions"
		fi
	else
		log "latest stable : $latest"
	fi

	if [ -z "$cur" ] && [ -z "$pkg_cur" ]; then
		info "Tailscale is not installed — nothing to update."
	elif [ -n "$latest" ] && [ -n "${cur:-$pkg_cur}" ] && [ "$(version_gt "$latest" "${cur:-$pkg_cur}")" = "1" ]; then
		ok "update available: ${cur:-$pkg_cur} -> $latest"
	elif [ "$cand_older" = true ]; then
		ok "no newer version in configured feeds (installed ${cur:-$pkg_cur}, best candidate $pkg_cand)"
	else
		ok "already up to date (${cur:-$pkg_cur})"
	fi
}

do_update() {
	acquire_lock
	resolve_mode
	if [ "$INSTALL_MODE" = "pkg" ]; then
		do_update_pkg
	else
		do_update_static
	fi
}

do_update_pkg() {
	need_root
	[ -n "$PKG_MGR" ] || die "no supported package manager (opkg/apk) found"
	[ -z "$TARGET_VERSION" ] || die "-v/--version only works in static mode; try --mode static"

	pkg_cur="$(pkg_installed_version "$PKG_NAME" 2>/dev/null || true)"
	[ -n "$pkg_cur" ] || die "the 'tailscale' package is not installed; install the community edition from iStore first"

	info "mode=package ($PKG_MGR, community edition)  installed=$pkg_cur"
	info "this build omits clientupdate; upgrading through $PKG_MGR (feed), not 'tailscale update'"
	pkg_refresh || warn "package index refresh failed; using cached index"
	cand="$(pkg_candidate_version "$PKG_NAME" 2>/dev/null || true)"
	[ -n "$cand" ] || die "no candidate version for 'tailscale' in the configured feeds"

	if [ "$FORCE" != 1 ] && [ "$(version_gt "$cand" "$pkg_cur")" != "1" ]; then
		ok "no newer package in configured feeds (installed $pkg_cur, best candidate $cand)"
		info "add the GuNanOvO/community opkg feed to receive versions newer than $pkg_cur"
		return 0
	fi

	if [ "$DRY_RUN" = 1 ]; then
		log ""
		log "DRY RUN — would perform:"
		log "  1. $PKG_MGR update"
		if [ "$PKG_MGR" = "apk" ]; then
			log "  2. apk add --upgrade $PKG_NAME   ($pkg_cur -> $cand)"
		else
			log "  2. opkg install $PKG_NAME        ($pkg_cur -> $cand)"
		fi
		log "  3. restart $INITD"
		return 0
	fi

	if [ "$ASSUME_YES" != 1 ]; then
		printf 'Upgrade Tailscale package %s -> %s via %s? [y/N] ' "$pkg_cur" "$cand" "$PKG_MGR"
		read -r _ans 2>/dev/null || _ans=n
		case "$_ans" in y|Y|yes|YES) ;; *) info "aborted"; return 0 ;; esac
	fi

	if have opkg; then opkg flag ok "$PKG_NAME" tailscaled >/dev/null 2>&1 || true; fi
	make_pkg_backup "$pkg_cur" "$(current_version 2>/dev/null || true)"
	service_stop
	if ! run_pkg_upgrade; then
		service_start
		die "package upgrade failed; check $PKG_MGR output and reinstall if needed"
	fi
	service_start

	new="$(current_version 2>/dev/null || true)"
	newpkg="$(pkg_installed_version "$PKG_NAME" 2>/dev/null || true)"
	ok "package upgraded: $pkg_cur -> ${newpkg:-$cand}"

	mkdir -p "$CONFDIR"
	printf 'mode=pkg\nversion=%s\npkg_version=%s\npkg_manager=%s\ninstalled_at=%s\nbackup=%s\n' \
		"${new:-$cand}" "${newpkg:-$cand}" "$PKG_MGR" \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$BACKUP_DIR" \
		> "$STATE_FILE"

	if [ "$NO_SERVICE" != 1 ] && [ -x "$BINDIR/tailscale" ]; then
		_st="$("$BINDIR/tailscale" status 2>&1 | awk 'NF && $0 !~ /^#/ {print; exit}')"
		[ -n "$_st" ] && info "status: $_st"
	fi
	log ""
	ok "Tailscale updated to ${new:-$cand} (package mode; no hold, feed upgrades stay enabled)"
}

do_update_static() {
	need_root
	if [ "$INSTALL_MODE" = "official" ]; then
		info "source=official: replacing the community build with official static binaries"
		warn "the tailscale package will be held; switch back to feed to resume opkg upgrades"
	elif [ "$LEGACY_DETECTED" != 1 ]; then
		warn "community package detected; it ships one UPX binary + a symlink, and 'tailscale update' is disabled."
		warn "forced --mode static replaces package files and will be overwritten by '$PKG_MGR upgrade'."
	fi
	arch="$(detect_arch)" || die "unsupported architecture: $(uname -m); use --arch"
	if [ -n "$TARGET_VERSION" ]; then
		latest="$TARGET_VERSION"
	else
		latest="$(get_latest_version)" || die "cannot reach $BASE_URL (network/DNS?)"
	fi
	case "$latest" in *[!0-9.]*|'') die "bad target version: '$latest'";; esac

	cur="$(current_version 2>/dev/null || true)"
	info "mode=$INSTALL_MODE  arch=$arch  installed=${cur:-none}  target=$latest"

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
	CLEANUP_DIRS="$CLEANUP_DIRS $workdir"

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
	printf 'mode=static\nversion=%s\ninstalled_at=%s\narch=%s\nbackup=%s\n' \
		"$new" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$arch" "$BACKUP_DIR" \
		> "$STATE_FILE"

	if [ "$NO_SERVICE" != 1 ] && [ -x "$BINDIR/tailscale" ]; then
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
	export TS_MODE_FOR_BG="$MODE_OVERRIDE"
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
	MODE_OVERRIDE="${TS_MODE_FOR_BG:-$MODE_OVERRIDE}"
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
			--mode)          shift; MODE_OVERRIDE="${1:-}"; case "$MODE_OVERRIDE" in auto|static|pkg|official) ;; *) die "--mode must be auto, static, pkg or official" ;; esac ;;
			--static)        MODE_OVERRIDE="static" ;;
			--pkg)           MODE_OVERRIDE="pkg" ;;
			--official)      MODE_OVERRIDE="official" ;;
			--set-source)    shift; SOURCE_SET="${1:-}"; MODE="set-source" ;;
			--no-hold)       NO_HOLD=1 ;;
			--bindir)        shift; BINDIR="${1:-}"; [ -n "$BINDIR" ] || die "--bindir needs an argument" ;;
			--workdir)       shift; WORKDIR_OVERRIDE="${1:-}" ;;
			--rollback)      MODE="rollback" ;;
			--list-backups)  MODE="list-backups" ;;
			--auto)          MODE="auto" ;;
			--set-auto)
				shift
				AUTO_SET="${1:-}"
				AUTO_TIME=""
				if [ $# -gt 1 ]; then shift; AUTO_TIME="${1:-}"; fi
				MODE="set-auto" ;;
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
		auto)          do_auto ;;
		set-auto)      set_auto "$AUTO_SET" "$AUTO_TIME" ;;
		set-source)    set_source "$SOURCE_SET" ;;
		update)        do_update ;;
		*)             die "bad mode" ;;
	esac
}

main "$@"
