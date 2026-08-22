#!/bin/sh
# ByeDPI strategy tester v2: probes candidate ciadpi strategies against several URLs.
#
# Usage:
#   sh strat_test.sh [url1 url2 ...]
# Defaults: youtube generate_204 + instagram.
#
# Each strategy runs its own temporary ciadpi instance on ports 10810+,
# your current service (if any) is not touched.

set -u

CIADPI=/usr/bin/ciadpi
BASE_PORT=10810
URLS="${*:-https://www.youtube.com/generate_204 https://www.instagram.com}"

if [ "$(id -u)" != "0" ]; then echo "err: run as root"; exit 1; fi
[ -x "$CIADPI" ] || { echo "err: $CIADPI not found (is byedpi installed?)"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "err: curl missing, install it first"; exit 1; }

STRATEGIES="
default_pkg|--split 1 --disorder 3+s --mod-http=h,d --auto=torst --tlsrec 1+s
ladder_zapret_manager|-d1 -s1+s -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -a1
disorder_3sni|--disorder 3+s
disorder_1|--disorder 1
fake_md5sig|--fake -1 --md5sig
fake_ttl8|--fake -1 --ttl 8
oob_3sni|--oob 3+s
tlsrec_3sni|--tlsrec 3+s
multi_split|--split 1 --split 3+s --split 10+s --disorder 20+s
"

label() {
	printf '%s' "$1" |
		sed -e 's|^https\?://||' -e 's|^www\.||' -e 's|[/.].*||'
}

# --- FakeIP guard -----------------------------------------------------------
FIRST_HOST="$(printf '%s\n' $URLS | head -n1)"
if nslookup "$(label "$FIRST_HOST").com" 127.0.0.1 2>/dev/null | grep -q '198\.18\.'; then
	echo '!! ВНИМАНИЕ: системный DNS отдаёт FakeIP (198.18.x.x).'
	echo '   При работающем forkop/podkop результаты будут ложными.'
	echo '   Остановите сервис маршрутизации на время теста:'
	echo '     /etc/init.d/forkop stop   # или podkop'
	echo
fi

probe() {
	# probe <port> <url> -> "code" or "code/E<curl_rc>"
	local port="$1" url="$2" out rc
	out="$(curl -sS -o /dev/null -w '%{http_code}' -m 10 \
		--socks5-hostname "127.0.0.1:$port" "$url" 2>/dev/null)"
	rc=$?
	if [ "$rc" -ne 0 ]; then
		out="$out/E$rc"
	fi
	printf '%s' "$out"
}

cell() {
	# cell <raw> -> formatted verdict string
	case "$1" in
		2*|3*)  printf '%-13s' "OK($1)" ;;
		*/E35)  printf '%-13s' "reset" ;;
		*/E7)   printf '%-13s' "noconn" ;;
		*/E28)  printf '%-13s' "timeout" ;;
		*)      printf '%-13s' "$1" ;;
	esac
}

# --- header -----------------------------------------------------------------
HDR="$(printf '%-24s' STRATEGY)"
for u in $URLS; do HDR="$HDR $(printf '%-13s' "$(label "$u")")"; done
printf '%s\n' "$HDR"
printf '%s\n' "----------------------------------------------------------------------------"

# --- direct baseline --------------------------------------------------------
LINE="$(printf '%-24s' '(direct)')"
for u in $URLS; do
	R="$(curl -sS -o /dev/null -w '%{http_code}' -m 8 "$u" 2>/dev/null)"
	rc=$?
	[ "$rc" -ne 0 ] && R="$R/E$rc"
	LINE="$LINE $(cell "$R")"
done
printf '%s\n' "$LINE"

# --- strategies -------------------------------------------------------------
PORT=$BASE_PORT
echo "$STRATEGIES" | while IFS='|' read -r name opts; do
	[ -n "$name" ] || continue

	"$CIADPI" -i 127.0.0.1 -p "$PORT" $opts >/dev/null 2>&1 &
	PID=$!
	sleep 1

	LINE="$(printf '%-24s' "$name")"
	for u in $URLS; do
		LINE="$LINE $(cell "$(probe "$PORT" "$u")")"
	done
	printf '%s\n' "$LINE"

	kill "$PID" >/dev/null 2>&1
	wait "$PID" 2>/dev/null
	PORT=$((PORT + 1))
done

printf '%s\n' "----------------------------------------------------------------------------"
cat <<EOF
OK(nnn)  - работает, код ответа nnn
reset    - TLS сброшен DPI (curl rc=35)
noconn   - ciadpi не поднялся (rc=7)
timeout  - таймаут (rc=28)
Apply winner:
  uci set byedpi.main.cmd_opts='<opts of winning row>'
  uci commit byedpi && /etc/init.d/byedpi restart
EOF
