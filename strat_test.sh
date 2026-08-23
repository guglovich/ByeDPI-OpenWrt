#!/bin/sh
# ByeDPI strategy tester v3 (Zapret-style).
#
# Wide technique grid x site matrix, two-phase screening:
#   phase 1 - fast screen on key sites (youtube/instagram/discord/x)
#   phase 2 - full matrix only for strategies that passed the screen
#
# Usage:
#   sh strat_test.sh                 # default site set (~10 services)
#   sh strat_test.sh URL...          # custom site set (all become key sites)
#   TIMEOUT_S=6 sh strat_test.sh     # per-request timeout, default 8s
#
# Stop your routing service first (/etc/init.d/forkop stop), otherwise
# FakeIP resolution poisons the results - the script warns when detected.

set -u

CIADPI=/usr/bin/ciadpi
PORT=10810
TIMEOUT_S="${TIMEOUT_S:-8}"

DEFAULT_URLS="
https://www.youtube.com/generate_204
https://i.ytimg.com/favicon.ico
https://www.instagram.com
https://scontent.cdninstagram.com
https://www.facebook.com
https://discord.com
https://x.com
https://rutracker.org
https://github.com
https://ya.ru
"

KEY_URLS="https://www.youtube.com/generate_204 https://www.instagram.com https://discord.com https://x.com"

STRATEGIES="
split_1|-s1
split_sni|-s3+s
split_multi|-s1 -s3+s -s7+s
disorder_1|-d1
disorder_sni|-d3+s
disorder_deep|-d9+s
oob_sni|-o3+s
disoob_sni|-q3+s
fake_ttl4|--fake -1 --ttl 4
fake_ttl8|--fake -1 --ttl 8
fake_ttl12|--fake -1 --ttl 12
fake_rand|--fake -1 --fake-tls-mod rand --ttl 8
fake_md5sig|--fake -1 --md5sig
fake_sack|--fake -1 --ttl 8 -Y
tlsrec_1|--tlsrec 1
tlsrec_sni|--tlsrec 3+s
tlsrec_multi|--tlsrec 1 --tlsrec 5+s
sp1_d1|-s1 -d1
sp_d_sni|--split 3+s -d6+s
fake_disorder|--disorder 1 --fake -1 --ttl 8
ladder_full|-d1 -s1+s -d3+s -d6+s -d9+s -d12+s -d15+s -d20+s -d25+s -d30+s -a1
ladder_zm|-d1 -s1+s -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -a1
chain_ladder_fake|--timeout 2 --auto-mode s,n -d1 -s1+s -d3+s -d6+s -d9+s -d12+s -d15+s -d20+s -d25+s -d30+s -a1 --auto=torst --fake -1 --ttl 8
chain_light|--timeout 2 --auto-mode s,n -s1 -s3+s --auto=torst -d3+s --auto=ssl_err --fake -1 --fake-tls-mod rand --ttl 8
"

[ "$(id -u)" = "0" ] || { echo "err: run as root"; exit 1; }
[ -x "$CIADPI" ] || { echo "err: $CIADPI not found (is byedpi installed?)"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "err: curl missing"; exit 1; }

label() {
	printf '%s' "$1" |
		sed -e 's|^https\?://||' -e 's|^www\.||' -e 's|[/.].*||'
}

URLS="${*:-$DEFAULT_URLS}"
if [ $# -gt 0 ]; then
	KEY="$*"
else
	KEY=""
	for k in $KEY_URLS; do
		printf '%s\n' $URLS | grep -qxF "$k" && KEY="$KEY $k"
	done
fi

FIRST_HOST="$(printf '%s' "$URLS" | awk '{print $1}')"
if nslookup "$(label "$FIRST_HOST").com" 127.0.0.1 2>/dev/null | grep -q '198\.18\.'; then
	echo '!! ВНИМАНИЕ: системный DNS отдаёт FakeIP (198.18.x.x) - результаты будут ложными.'
	echo '   Остановите сервис маршрутизации: /etc/init.d/forkop stop (или podkop)'
	echo
fi

# --- process/result management -----------------------------------------------
WORK=/tmp/byedpi_strat.$$
mkdir -p "$WORK"
cleanup() {
	if [ -f "$WORK/pids" ]; then
		while read -r p; do kill "$p" 2>/dev/null; done <"$WORK/pids"
	fi
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

probe() {
	# probe <url> -> cell verdict; any HTTP status counts as success
	local out rc
	out="$(curl -sS -o /dev/null -w '%{http_code}' -m "$TIMEOUT_S" \
		--socks5-hostname "127.0.0.1:$PORT" "$1" 2>/dev/null)"
	rc=$?
	[ "$rc" -eq 0 ] && { printf '%s' "$out"; return; }
	case "$rc" in
		35) printf 'reset' ;;
		7)  printf 'noconn' ;;
		28) printf 'timeout' ;;
		*)  printf 'err%s' "$rc" ;;
	esac
}

run_phase() {
	# run_phase <phase-file-suffix> <urls...>
	local suffix="$1"; shift
	echo "$STRATEGIES" | while IFS='|' read -r name opts; do
		[ -n "$name" ] || continue
		"$CIADPI" -i 127.0.0.1 -p "$PORT" $opts >/dev/null 2>&1 &
		pid=$!
		echo "$pid" >>"$WORK/pids"
		sleep 1

		if ! kill -0 "$pid" 2>/dev/null; then
			printf '%-20s FAILED-TO-START\n' "$name"
			continue
		fi

		codes=""
		ok=0
		n=0
		for u in "$@"; do
			cell="$(probe "$u")"
			n=$((n + 1))
			case "$cell" in reset|noconn|timeout|err*) ;; *) ok=$((ok + 1)) ;; esac
			codes="$codes $(printf '%-11s' "$cell")"
		done
		printf '%-20s %s\n' "$name" "$codes"
		printf '%s %s %s\n' "$ok" "$n" "$codes" >"$WORK/$name$suffix"
		kill "$pid" 2>/dev/null
	done
}

row_of() {
	# row_of <strategy-name>: rebuild display row from saved phases
	local name="$1" f="$WORK/$name" ok=0 n=0 codes="" o c
	for sfx in .p1 .p2; do
		[ -f "${f}${sfx}" ] || continue
		read -r o c _rest <"${f}${sfx}"
		ok=$((ok + o))
		n=$((n + c))
		codes="$codes$(sed 's/^[0-9]* [0-9]* //' "${f}${sfx}")"
	done
	printf '%-20s %-8s %s\n' "$name" "$ok/$n" "$codes"
}

# --- header ------------------------------------------------------------------
HDR="$(printf '%-20s' STRATEGY)"
for u in $URLS; do HDR="$HDR $(printf '%-11s' "$(label "$u")")"; done
echo "$HDR"
echo "--------------------------------------------------------------------------------"

LINE="$(printf '%-20s' '(direct)')"
for u in $URLS; do
	R="$(curl -sS -o /dev/null -w '%{http_code}' -m 6 "$u" 2>/dev/null)"; rc=$?
	if [ "$rc" -ne 0 ]; then
		case $rc in 35) R=reset;; 7) R=noconn;; 28) R=timeout;; *) R="err$rc";; esac
	fi
	LINE="$LINE $(printf '%-11s' "$R")"
done
echo "$LINE"

# --- phase 1 -----------------------------------------------------------------
kn=$(printf '%s' "$KEY" | wc -w)
echo ">>> Фаза 1: скрининг по ключевым сайтам ($kn шт)"
run_phase ".p1" $KEY

SURVIVORS=""
for f in "$WORK"/*.p1; do
	[ -f "$f" ] || continue
	name=$(basename "$f"); name=${name%.p1}
	read -r o c _ <"$f"
	[ "$o" -eq "$kn" ] && SURVIVORS="$SURVIVORS $name"
done
[ -z "$(printf '%s' "$SURVIVORS" | tr -d ' ')" ] && {
	echo
	echo 'Ни одна стратегия не прошла ключевые сайты.'
	echo 'Проверьте: сервис маршрутизации остановлен? TSPU изменил поведение?'
	exit 0
}

# --- phase 2 -----------------------------------------------------------------
REST=""
for u in $URLS; do
	case " $KEY " in *" $u "*) ;; *) REST="$REST $u" ;; esac
done
if [ -n "$REST" ]; then
	echo ">>> Фаза 2: полная матрица для прошедших экран ($(printf '%s' "$SURVIVORS" | wc -w) стратегий)"
	run_phase ".p2" $REST
fi

# --- summary -----------------------------------------------------------------
echo "--------------------------------------------------------------------------------"
echo "=== Итоговая матрица (сортировка по покрытию) ==="
for f in "$WORK"/*.p1; do
	name=$(basename "$f"); name=${name%.p1}
	row_of "$name"
done | sort -t'|' -k2 -rn | awk -F'|' '{print}'

BEST=$(for f in "$WORK"/*.p1; do
	name=$(basename "$f"); name=${name%.p1}
	row_of "$name"
done | sort -t'|' -k2 -rn | head -1 | awk '{print $1}')

BOPT=$(echo "$STRATEGIES" | grep "^$BEST|" | cut -d'|' -f2-)
cat <<EOF

Рекомендация (максимальное покрытие): $BEST
  $BOPT

Применить:
  - Forkop: вставить строку в поле стратегии ByeDPI-секции, рестарт Forkop
  - или: uci set byedpi.main.cmd_opts='$BOPT'; uci commit byedpi; /etc/init.d/byedpi restart

Любой HTTP-код (даже 403/404) = TLS прошёл через ТСПУ, десинк работает.
reset = TLS сброшен; timeout = молчаливый дроп; noconn = инстанс не поднялся.
EOF
