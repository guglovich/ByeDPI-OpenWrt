#!/bin/sh
# ByeDPI strategy tester: probes candidate ciadpi strategies against a target URL.
#
# Usage:
#   sh strat_test.sh [url]
# Default url: https://www.youtube.com/generate_204
#
# Each strategy runs its own temporary ciadpi instance on ports 10810+,
# your current service (if any) is not touched.

set -u

URL="${1:-https://www.youtube.com/generate_204}"
CIADPI=/usr/bin/ciadpi
BASE_PORT=10810

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

printf '%-24s %-6s %s\n' "STRATEGY" "CODE" "VERDICT"
printf '%s\n' "--------------------------------------------------------------"

printf '%-24s ' "(direct, no proxy)"
DIRECT="$(curl -sS -o /dev/null -w '%{http_code}' -m 8 "$URL" 2>/dev/null || printf '%s' "$?")"
case "$DIRECT" in 000) echo "$DIRECT FAIL/reset" ;; 2*|3*) echo "$DIRECT OK" ;; *) echo "$DIRECT ?" ;; esac

PORT=$BASE_PORT
echo "$STRATEGIES" | while IFS='|' read -r name opts; do
	[ -n "$name" ] || continue
	"$CIADPI" -i 127.0.0.1 -p "$PORT" $opts >/dev/null 2>&1 &
	PID=$!
	sleep 1

	CODE="$(curl -sS -o /dev/null -w '%{http_code}' -m 10 \
		--socks5-hostname "127.0.0.1:$PORT" "$URL" 2>/dev/null || printf '%s' "$?")"

	case "$CODE" in
		2*|3*) verdict="OK -> use: option cmd_opts '$opts'" ;;
		000)   verdict="FAIL (reset/timeout)" ;;
		*)     verdict="HTTP $CODE" ;;
	esac
	printf '%-24s %-6s %s\n' "$name" "$CODE" "$verdict"

	kill "$PID" >/dev/null 2>&1
	wait "$PID" 2>/dev/null
	PORT=$((PORT + 1))
done

printf '%s\n' "--------------------------------------------------------------"
echo "Apply winner:"
echo "  uci set byedpi.main.cmd_opts='<opts>'"
echo "  uci commit byedpi && /etc/init.d/byedpi restart"
