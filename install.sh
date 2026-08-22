#!/bin/sh
# ByeDPI-OpenWrt installer.
#
# Installs the byedpi package from project releases and adds a separate
# "ByeDPI" profile into Podkop (or NetShift) WITHOUT touching any existing
# profiles or settings - only adding/modifying its own UCI section.
#
# Usage:
#   sh install.sh
#
# Environment overrides:
#   BYEDPI_REPO    repo with releases   (default guglovich/byedpi-openwrt-riscv64)
#   BYEDPI_PORT    ciadpi SOCKS port    (default 1080)
#   BYEDPI_OPTS    ciadpi cmd_opts      (default: keep packaged strategy)
#   SKIP_PODKOP=1  skip Podkop integration

set -u

REPO="${BYEDPI_REPO:-guglovich/byedpi-openwrt-riscv64}"
PROFILE="${BYEDPI_PROFILE:-ByeDPI}"
PORT="${BYEDPI_PORT:-1080}"

if [ -t 1 ]; then
	R="\033[31m"; G="\033[32m"; Y="\033[33m"; C="\033[36m"; N="\033[0m"
else
	R=""; G=""; Y=""; C=""; N=""
fi

msg() { printf "${C}==>${N} %s\n" "$*"; }
ok()  { printf "${G} ok:${N} %s\n" "$*"; }
warn(){ printf "${Y} !! ${N}%s\n" "$*"; }
err() { printf "${R}err:${N} %s\n" "$*" >&2; }
die() { err "$*"; exit 1; }

[ "$(id -u)" = "0" ] || die "run as root"

command -v uci >/dev/null 2>&1 || die "uci not found - is this OpenWrt?"
[ -f /etc/openwrt_release ] || die "/etc/openwrt_release not found - is this OpenWrt?"

# ---------------------------------------------------------------- package mgr
PKG=""
command -v apk >/dev/null 2>&1 && PKG=apk
if [ -z "$PKG" ]; then
	command -v opkg >/dev/null 2>&1 && PKG=opkg
fi
[ -n "$PKG" ] || die "neither apk nor opkg found"

ARCH="$(awk -F\' '/DISTRIB_ARCH/ {print $2}' /etc/openwrt_release)"
msg "OpenWrt arch: $ARCH, package manager: $PKG"
if [ "$ARCH" != "riscv64_generic" ]; then
	warn "package is built for riscv64_generic, current device reports '$ARCH'"
	printf "%s" "continue anyway? [y/N]: "
	read -r ans
	case "$ans" in y|Y|д|Д) ;; *) exit 0 ;; esac
fi

# --------------------------------------------------------------- fetch & pkg
msg "Fetching latest release of $REPO"
JSON="$(wget -qO- "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null)" ||
	JSON="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null)" ||
	die "cannot download release info from api.github.com"

URL="$(printf '%s\n' "$JSON" |
	grep -o '"browser_download_url": *"[^"]*"' |
	cut -d'"' -f4 |
	grep "\.$PKG\$" | head -n1)"
[ -n "$URL" ] || die "no .$PKG asset in latest release (repo publishes $(printf '%s' "$JSON" | grep -o '"name": *"[^"]*\.\(apk\|ipk\)"' | head -n2 | tr '\n' ' '))"

FILE="/tmp/$(basename "$URL")"
rm -f "$FILE"
msg "Downloading $(basename "$URL")"
wget -qO"$FILE" "$URL" 2>/dev/null || curl -fsSLo"$FILE" "$URL" 2>/dev/null ||
	die "download failed: $URL"
[ -s "$FILE" ] || die "downloaded file is empty"

msg "Installing package ($PKG)"
if [ "$PKG" = apk ]; then
	apk add --allow-untrusted "$FILE" || die "apk install failed"
else
	opkg install --force-reinstall "$FILE" || opkg install "$FILE" || die "opkg install failed"
fi
rm -f "$FILE"

# ------------------------------------------------------------------- service
if [ -n "${BYEDPI_OPTS:-}" ]; then
	msg "Applying custom strategy (BYEDPI_OPTS)"
	uci set byedpi.main.cmd_opts="$BYEDPI_OPTS"
	uci commit byedpi
fi
if [ "$PORT" != "1080" ]; then
	msg "Setting listen port $PORT"
	uci set byedpi.main.port="$PORT"
	uci commit byedpi
fi

msg "Starting byedpi service"
/etc/init.d/byedpi enable >/dev/null 2>&1
/etc/init.d/byedpi restart >/dev/null 2>&1 || /etc/init.d/byedpi start >/dev/null 2>&1
ok "byedpi is running, socks5://127.0.0.1:$PORT"

# ------------------------------------------------- Podkop integration (add-only)
CFG=""
[ -f /etc/config/podkop ]   && CFG=podkop
[ -z "$CFG" ] && [ -f /etc/config/netshift ] && CFG=netshift

if [ "${SKIP_PODKOP:-0}" = "1" ]; then
	CFG=""
	warn "SKIP_PODKOP=1 - integration skipped"
fi

if [ -n "$CFG" ]; then
	CONF="/etc/config/$CFG"
	BAK="$CONF.bak-byedpi"
	msg "Integrating into $CFG (add-only)"

	# one-time backup, never overwritten by later runs
	if [ ! -f "$BAK" ]; then
		cp "$CONF" "$BAK" &&
			ok "backup saved: $BAK"
	fi

	# create our own named section only if absent; never touch other sections
	if uci -q get "$CFG.$PROFILE" >/dev/null 2>&1; then
		ok "profile '$PROFILE' already exists in $CFG - updating only its options"
	else
		SID="$(uci add "$CFG" section)" || die "uci add failed"
		uci rename "$CFG.$SID=$PROFILE" >/dev/null ||
			die "uci rename failed"
		ok "new profile '$PROFILE' added (other profiles untouched)"
	fi

	OUT="{\"type\":\"socks\",\"server\":\"127.0.0.1\",\"server_port\":$PORT}"
	uci set "$CFG.$PROFILE.connection_type=proxy"
	uci set "$CFG.$PROFILE.proxy_config_type=outbound"
	uci set "$CFG.$PROFILE.outbound_json=$OUT"
	uci set "$CFG.$PROFILE.enable_udp_over_tcp=0"
	uci commit "$CFG"

	/etc/init.d/byedpi restart >/dev/null 2>&1 || true
	if [ -f "/etc/init.d/$CFG" ]; then
		msg "Restarting $CFG service"
		"/etc/init.d/$CFG" restart >/dev/null 2>&1 || true
	fi
	ok "'$PROFILE' profile points at socks5://127.0.0.1:$PORT"
else
	warn "Podkop/NetShift config not found - integration skipped"
fi

cat <<EOF

${G}Done.${N}
Next steps:
  - open LuCI -> Services -> Podkop -> profile '${PROFILE}'
  - attach community/domain lists you need (russia_inside, youtube, ...)
  - traffic for those lists goes through ByeDPI, everything else stays direct
EOF
