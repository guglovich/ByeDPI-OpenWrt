#!/bin/sh
# ByeDPI strategy tester v3.1 (Zapret-style).
#
# Wide technique grid x site matrix, two-phase screening:
#   phase 1 - fast screen on key sites (youtube/instagram/discord/x)
#   phase 2 - full matrix only for strategies that passed the screen
# Final verdict is given PER SERVICE: ByeDPI (with best strategy) or AWG.
#
# Usage:
#   sh strat_test.sh                 # default site set
#   sh strat_test.sh URL...          # custom site set (all become key sites)
#   TIMEOUT_S=6 sh strat_test.sh     # per-request timeout, default 8s
#
# Stop your routing service first (/etc/init.d/forkop stop), otherwise
# FakeIP resolution poisons the results - the script warns when detected.

set -u

CIADPI=/usr/bin/ciadpi
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
https://nnmclub.to
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

PORT=""
for p in $(seq 10810 10830); do
	netstat -tln 2>/dev/null | grep -q ":$p " || { PORT=$p; break; }
done
[ -n "$PORT" ] || { echo "err: нет свободного порта в диапазоне 10810-10830"; exit 1; }
echo ">>> Тестовый порт: $PORT"

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

is_ok() {
	case "$1" in
		reset|noconn|timeout|err*) return 1 ;;
		*) [ -n "$1" ] && return 0 || return 1 ;;
	esac
}

fmt_cell() {
	case "$1" in
		reset)   printf 'reset' ;;
		noconn)  printf 'noconn' ;;
		timeout) printf 'timeout' ;;
		err*)    printf '%s' "$1" ;;
		*)       printf 'OK(%s)' "$1" ;;
	esac
}

run_phase() {
	# run_phase <suffix> <urls...>: probes every strategy against urls,
	# saves per-strategy "ok n token token ..." into $WORK/<name><suffix>
	# and the url order into $WORK/urls<suffix>
	local suffix="$1"; shift
	printf '%s\n' "$@" >"$WORK/urls$suffix"
	echo "$STRATEGIES" | while IFS='|' read -r name opts; do
		[ -n "$name" ] || continue
		ERRLOG="$WORK/ciadpi.err"
		"$CIADPI" -i 127.0.0.1 -p "$PORT" $opts >/dev/null 2>"$ERRLOG" &
		pid=$!
		echo "$pid" >>"$WORK/pids"
		sleep 1

		if ! kill -0 "$pid" 2>/dev/null; then
			printf '%-20s FAILED-TO-START: %s\n' "$name" "$(head -1 "$ERRLOG")"
			continue
		fi

		tokens=""
		ok=0
		n=0
		for u in "$@"; do
			cell="$(probe "$u")"
			n=$((n + 1))
			is_ok "$cell" && ok=$((ok + 1))
			tokens="$tokens$cell "
		done
		printf '%-20s ' "$name"
		for t in $tokens; do printf '%-12s' "$(fmt_cell "$t")"; done
		printf '\n'
		printf '%s %s %s\n' "$ok" "$n" "$tokens" >"$WORK/$name$suffix"
		kill "$pid" 2>/dev/null
	done
}

col_token() {
	# col_token <strategy> <url> -> raw token for that url across phases
	local name="$1" url="$2" ph f idx tok rest
	for ph in p1 p2; do
		f="$WORK/urls$ph"
		[ -f "$f" ] || continue
		idx=0
		found=""
		for u in $(cat "$f"); do
			idx=$((idx + 1))
			[ "$u" = "$url" ] && { found=$idx; break; }
		done
		[ -n "$found" ] || continue
		sf="$WORK/$name.$ph"
		[ -f "$sf" ] || return
		read -r _ _ rest <"$sf"
		set -- $rest
		eval "shift \$((found - 1))"
		printf '%s' "$1"
		return
	done
}

row_of() {
	local name="$1" u t line
	line="$(printf '%-20s' "$name")"
	for u in $URLS; do
		t="$(col_token "$name" "$u")"
		[ -z "$t" ] && t="-"
		line="$line $(printf '%-12s' "$(fmt_cell "$t")")"
	done
	printf '%-20s %-7s %s\n' "$name" "$(ok_count "$name")/$(printf '%s' "$URLS" | wc -w)" "${line#* }"
}

ok_count() {
	local name="$1" total=0 u t
	for u in $URLS; do
		t="$(col_token "$name" "$u")"
		is_ok "$t" && total=$((total + 1))
	done
	printf '%s' "$total"
}

# --- header ------------------------------------------------------------------
HDR="$(printf '%-20s' STRATEGY)"
for u in $URLS; do HDR="$HDR $(printf '%-12s' "$(label "$u")")"; done
echo "$HDR"
echo "--------------------------------------------------------------------------------"

LINE="$(printf '%-20s' '(direct)')"
for u in $URLS; do
	R="$(curl -sS -o /dev/null -w '%{http_code}' -m 6 "$u" 2>/dev/null)"; rc=$?
	if [ "$rc" -ne 0 ]; then
		case $rc in 35) R=reset;; 7) R=noconn;; 28) R=timeout;; *) R="err$rc";; esac
	fi
	LINE="$LINE $(printf '%-12s' "$R")"
done
echo "$LINE"

# --- phase 1 -----------------------------------------------------------------
kn=$(printf '%s' "$KEY" | wc -w)
echo ">>> Фаза 1: скрининг по ключевым сайтам ($kn шт)"
run_phase ".p1" $KEY

# --- phase 2: strategies that passed ALL keys --------------------------------
SURVIVORS=""
for f in "$WORK"/*.p1; do
	[ -f "$f" ] || continue
	name=$(basename "$f"); name=${name%.p1}
	read -r o c _ <"$f"
	[ "$o" -eq "$kn" ] && SURVIVORS="$SURVIVORS $name"
done

REST=""
for u in $URLS; do
	case " $KEY " in *" $u "*) ;; *) REST="$REST $u" ;; esac
done
if [ -n "$(printf '%s' "$SURVIVORS" | tr -d ' ')" ] && [ -n "$REST" ]; then
	echo ">>> Фаза 2: полная матрица для прошедших все ключи ($(printf '%s' "$SURVIVORS" | wc -w) стратегий)"
	run_phase ".p2" $REST
else
	echo ">>> Фаза 2 пропущена: ни одна стратегия не прошла все ключи (см. вердикты ниже)"
fi

# --- per-service verdicts ----------------------------------------------------
echo "--------------------------------------------------------------------------------"
echo "=== Вердикты по сервисам ==="
for u in $URLS; do
	L="$(label "$u")"
	PASSERS=""
	for f in "$WORK"/*.p1; do
		name=$(basename "$f"); name=${name%.p1}
		t="$(col_token "$name" "$u")"
		is_ok "$t" && PASSERS="$PASSERS $name"
	done
	cnt=$(printf '%s' "$PASSERS" | wc -w)
	if [ "$cnt" -gt 0 ]; then
		TOP=$(printf '%s' "$PASSERS" | tr ' ' '\n' | head -4 | tr '\n' ',')
		printf '%-14s ByeDPI (%d/%d стратегий, напр.: %s)\n' "$L" "$cnt" \
			$(echo "$STRATEGIES" | grep -c '^') "${TOP%,}"
	else
		printf '%-14s -> AWG (ни одна стратегия не пробила; вероятно IP-блок краёв)\n' "$L"
	fi
done

# --- global recommendation ---------------------------------------------------
BEST=""
BESTOK=-1
for f in "$WORK"/*.p1; do
	name=$(basename "$f"); name=${name%.p1}
	c="$(ok_count "$name")"
	[ "$c" -gt "$BESTOK" ] && { BESTOK=$c; BEST=$name; }
done

cat <<EOF
--------------------------------------------------------------------------------
Лучшая по общему покрытию ($BESTOK из $(printf '%s' "$URLS" | wc -w)): $BEST
EOF
if [ -n "$BEST" ]; then
	grep "^$BEST|" <<EOFSTRAT >/dev/null 2>&1
$STRATEGIES
EOFSTRAT
	BOPT=$(echo "$STRATEGIES" | grep "^$BEST|" | cut -d'|' -f2-)
	echo "  $BOPT"
	cat <<EOF

Применить:
  - Forkop: вставить строку в поле стратегии ByeDPI-секции, рестарт Forkop
  - или: uci set byedpi.main.cmd_opts='$BOPT'; uci commit byedpi; /etc/init.d/byedpi restart

Сервисы с вердиктом "-> AWG" добавьте в списки AWG-секции.
Любой HTTP-код (включая 403/404) = TLS прошёл ТСПУ. reset = RST, timeout = тихий дроп.
EOF
fi
