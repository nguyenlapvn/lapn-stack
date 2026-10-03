#!/usr/bin/env bash
# modules/05-dashboard.sh — live overview: resource history + per-site status.
#
# Three parts:
#   metrics:sample  one raw sample, run by lapn-metrics.timer every minute
#   ring buffer     /var/lib/lapn/metrics/*.csv, trimmed to ~24h, no database
#   dashboard       reads the buffer, derives rates, draws sparklines
# Samples store RAW kernel counters, never percentages: rates are derived at render
# time, so a missed sample or a clock change cannot corrupt the stored series.

MODULE_NAME="Dashboard"
MODULE_ORDER=5
MODULE_COMMANDS=("dashboard")
MODULE_MENU="dashboard_menu"

dashboard_menu() { cmd_dashboard; }

_metrics_dir()  { printf '%s' "${LAPN_METRICS_DIR:-/var/lib/lapn/metrics}"; }
_metrics_sys()  { printf '%s/system.csv' "$(_metrics_dir)"; }
_metrics_site() { printf '%s/site-%s.csv' "$(_metrics_dir)" "$1"; }

# ============ COLLECTOR ============

# Append a line and keep the file near LAPN_METRICS_KEEP rows. Trimming lazily (only
# once the overshoot is worth it) avoids rewriting the whole file every single minute.
_metrics_append() {
  local file="$1" line="$2" keep="${LAPN_METRICS_KEEP:-1440}" n
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$line" >>"$file" 2>/dev/null || return 0
  n="$(wc -l <"$file" 2>/dev/null || echo 0)"
  if (( n > keep + 120 )); then
    tail -n "$keep" "$file" >"${file}.tmp" 2>/dev/null \
      && mv -f "${file}.tmp" "$file" 2>/dev/null || rm -f "${file}.tmp"
  fi
}

# cmd_metrics_sample — one sample of the whole box plus one per site. Deliberately
# cheap: /proc reads and a single systemctl call per site.
cmd_metrics_sample() {
  local ts; ts="$(date +%s)"
  local cpu_total cpu_idle mem_total mem_avail disk_pct net_rx net_tx

  # /proc/stat: user nice system idle iowait irq softirq steal
  local _k u n s i w irq sirq steal
  read -r _k u n s i w irq sirq steal _ </proc/stat
  cpu_total=$(( u + n + s + i + w + irq + sirq + steal ))
  cpu_idle=$(( i + w ))

  # `print`, not `printf`: it appends the newline that `read` needs to return 0.
  # Without it `read` hits EOF, returns 1, and `set -e` kills the whole sampler.
  read -r mem_total mem_avail < <(
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo) || true
  disk_pct="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5+0}')"
  read -r net_rx net_tx < <(
    awk 'NR>2 {gsub(":","",$1); if ($1!="lo") {rx+=$2; tx+=$10}} END{print rx+0, tx+0}' \
      /proc/net/dev) || true

  _metrics_append "$(_metrics_sys)" \
    "${ts},${cpu_total},${cpu_idle},${mem_total},${mem_avail},${disk_pct:-0},${net_rx},${net_tx}"

  # Per site: the unit's own cgroup accounting, so these are kernel numbers, not guesses.
  local domain name mem cpu
  while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    name="$(state_site_get "$domain" name)"
    [[ -z "$name" ]] && continue
    read -r mem cpu < <(_metrics_unit_usage "$name") || true
    _metrics_append "$(_metrics_site "$name")" "${ts},${mem},${cpu}"
  done < <(state_sites_list 2>/dev/null)
}

# _metrics_unit_usage <name> -> "<mem_bytes> <cpu_nsec>", 0 0 when the unit is not running.
# systemd reports "[not set]" for an inactive unit, which must not reach the CSV.
_metrics_unit_usage() {
  local name="$1" mem cpu out
  out="$(systemctl show "lapn-${name}.service" -p MemoryCurrent -p CPUUsageNSec 2>/dev/null || true)"
  mem="$(printf '%s\n' "$out" | sed -n 's/^MemoryCurrent=//p')"
  cpu="$(printf '%s\n' "$out" | sed -n 's/^CPUUsageNSec=//p')"
  [[ "$mem" =~ ^[0-9]+$ ]] || mem=0
  [[ "$cpu" =~ ^[0-9]+$ ]] || cpu=0
  # Trailing newline is required: the callers use `read`, which returns 1 on EOF
  # without a delimiter — fatal under `set -e`.
  printf '%s %s\n' "$mem" "$cpu"
}

# Install (and start) the sampling timer. Safe to call repeatedly.
metrics_ensure_timer() {
  (( EUID == 0 )) || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  local svc=/etc/systemd/system/lapn-metrics.service
  local tmr=/etc/systemd/system/lapn-metrics.timer
  local changed=""
  if [[ ! -f "$svc" ]]; then
    cp -f "$LAPN_HOME/templates/systemd/lapn-metrics.service" "$svc"; changed=1
  fi
  if [[ ! -f "$tmr" ]]; then
    cp -f "$LAPN_HOME/templates/systemd/lapn-metrics.timer" "$tmr"; changed=1
  fi
  [[ -n "$changed" ]] && systemctl daemon-reload 2>/dev/null
  systemctl is-enabled --quiet lapn-metrics.timer 2>/dev/null \
    || systemctl enable --now lapn-metrics.timer 2>/dev/null || true
  mkdir -p -m 750 "$(_metrics_dir)" 2>/dev/null || true
}

# ============ SERIES ============

# _metrics_series <window-minutes> <columns>
# Prints three lines — "cpu ...", "mem ...", "disk ..." — each with <columns> averaged
# buckets of 0-100 values derived from the raw counters.
_metrics_series() {
  local window="$1" cols="$2" file; file="$(_metrics_sys)"
  [[ -f "$file" ]] || return 1
  awk -F, -v want="$window" -v W="$cols" '
    { ts[NR]=$1; ct[NR]=$2; ci[NR]=$3; mt[NR]=$4; ma[NR]=$5; du[NR]=$6; n=NR }
    END{
      if (n < 2) exit 1
      m = 0
      for (i = 2; i <= n; i++) {
        dt = ct[i] - ct[i-1]; di = ci[i] - ci[i-1]
        # A counter that went backwards means a reboot: drop that interval.
        if (dt <= 0 || di < 0) continue
        c = (1 - di/dt) * 100; if (c < 0) c = 0; if (c > 100) c = 100
        mu = (mt[i] > 0) ? (1 - ma[i]/mt[i]) * 100 : 0
        m++; CPU[m]=c; MEM[m]=mu; DSK[m]=du[i]
      }
      if (m < 1) exit 1
      start = m - want + 1; if (start < 1) start = 1
      avail = m - start + 1
      sc = ""; sm = ""; sd = ""
      for (b = 0; b < W; b++) {
        lo = start + int(b * avail / W)
        hi = start + int((b+1) * avail / W) - 1
        if (hi < lo) hi = lo
        a1 = a2 = a3 = 0; k = 0
        for (j = lo; j <= hi && j <= m; j++) { a1+=CPU[j]; a2+=MEM[j]; a3+=DSK[j]; k++ }
        if (k == 0) { k = 1; a1 = CPU[m]; a2 = MEM[m]; a3 = DSK[m] }
        sc = sc " " int(a1/k + 0.5); sm = sm " " int(a2/k + 0.5); sd = sd " " int(a3/k + 0.5)
      }
      print "cpu" sc; print "mem" sm; print "disk" sd
    }' "$file"
}

# ============ RENDERING ============

# Block characters need a UTF-8 terminal; fall back so the panel is never mojibake.
_dash_init_blocks() {
  local cs="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  if [[ "$cs" == *[Uu][Tt][Ff]* ]]; then
    _DASH_BLOCKS=('▁' '▂' '▃' '▄' '▅' '▆' '▇' '█')
  else
    _DASH_BLOCKS=('_' '.' '-' '~' '=' '+' '*' '#')
  fi
}

_dash_spark() {
  local v idx out=""
  for v in "$@"; do
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    (( v > 100 )) && v=100
    idx=$(( v * 7 / 100 ))
    out+="${_DASH_BLOCKS[$idx]}"
  done
  printf '%s' "$out"
}

# Colour a percentage: green under 70, yellow under 90, red above.
_dash_pct_color() {
  local v="$1"
  if   (( v >= 90 )); then printf '%s' "$C_RED"
  elif (( v >= 70 )); then printf '%s' "$C_YELLOW"
  else printf '%s' "$C_GREEN"; fi
}

_dash_human_bytes() {
  local b="${1:-0}"
  if   (( b >= 1073741824 )); then awk -v b="$b" 'BEGIN{printf "%.1fG", b/1073741824}'
  elif (( b >= 1048576 ));    then awk -v b="$b" 'BEGIN{printf "%dM", b/1048576}'
  elif (( b > 0 ));           then awk -v b="$b" 'BEGIN{printf "%dK", b/1024}'
  else printf '-'; fi   # ASCII: printf pads %-Ns by bytes, so a multi-byte dash misaligns the column
}

_dash_uptime() {
  local s; s="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"
  printf '%dd %dh' $(( s / 86400 )) $(( (s % 86400) / 3600 ))
}

# Cert days left, cached for the lifetime of one dashboard run (openssl per site per
# refresh would be the most expensive thing on the screen).
declare -gA _DASH_CERT_DAYS=()
_dash_cert_days() {
  local domain="$1"
  [[ -n "${_DASH_CERT_DAYS[$domain]:-}" ]] && { printf '%s' "${_DASH_CERT_DAYS[$domain]}"; return 0; }
  local f end days out="-"
  for f in "/etc/letsencrypt/live/$domain/cert.pem" "${LAPN_ETC}/ssl/$domain/origin.pem"; do
    [[ -f "$f" ]] || continue
    end="$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)"
    [[ -z "$end" ]] && continue
    days=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    out="${days}d"
    break
  done
  _DASH_CERT_DAYS[$domain]="$out"
  printf '%s' "$out"
}

# Per-site CPU% needs two readings; the previous one is kept across refreshes.
declare -gA _DASH_PREV_CPU=()
declare -g  _DASH_PREV_TS=0

_dash_render() {
  local cols="${1:-40}" window="${2:-1440}"
  local now; now="$(date +%s)"

  printf '%s%sLapN%s · dashboard   %s   up %s\n\n' \
    "$C_BOLD" "$C_BLUE" "$C_RESET" "$(date '+%Y-%m-%d %H:%M:%S')" "$(_dash_uptime)"

  # --- resource history ---
  local cpu_line mem_line disk_line
  if ! { read -r cpu_line; read -r mem_line; read -r disk_line; } < <(_metrics_series "$window" "$cols"); then
    log_dim "  Collecting samples… the first sparkline appears after 2 minutes."
    log_dim "  (timer: $(systemctl is-active lapn-metrics.timer 2>/dev/null || echo 'not installed'))"
    printf '\n'
  else
    local -a c=(${cpu_line#cpu }) m=(${mem_line#mem }) d=(${disk_line#disk })
    local cnow="${c[-1]}" mnow="${m[-1]}" dnow="${d[-1]}"
    local load; load="$(awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null)"
    local memt mema
    read -r memt mema < <(
      awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo) || true
    local dfline; dfline="$(df -Ph / 2>/dev/null | awk 'NR==2{print $3" / "$2}')"

    printf ' CPU   %s%s%s  %s%3s%%%s   load %s\n' \
      "$C_BLUE" "$(_dash_spark "${c[@]}")" "$C_RESET" "$(_dash_pct_color "$cnow")" "$cnow" "$C_RESET" "$load"
    printf ' RAM   %s%s%s  %s%3s%%%s   %s\n' \
      "$C_BLUE" "$(_dash_spark "${m[@]}")" "$C_RESET" "$(_dash_pct_color "$mnow")" "$mnow" "$C_RESET" \
      "$(awk -v u=$((memt-mema)) -v t="$memt" 'BEGIN{printf "%.1fG / %.1fG", u/1048576, t/1048576}')"
    printf ' DISK  %s%s%s  %s%3s%%%s   %s\n' \
      "$C_BLUE" "$(_dash_spark "${d[@]}")" "$C_RESET" "$(_dash_pct_color "$dnow")" "$dnow" "$C_RESET" "$dfline"
    printf '       %s%s%s\n\n' "$C_DIM" "$(_dash_window_label "$window" "$cols")" "$C_RESET"
  fi

  # --- sites ---
  local domain i=0
  printf ' %s%-3s %-28s %-9s %-7s %-6s %-7s %s%s\n' \
    "$C_BOLD" "#" "DOMAIN" "STATUS" "MEM" "CPU" "SSL" "TYPE" "$C_RESET"
  while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    i=$((i + 1))
    local name type st mem cpu memh cpup mark
    name="$(state_site_get "$domain" name)"
    type="$(state_site_get "$domain" type)"
    st="$(_site_status "$domain")"
    read -r mem cpu < <(_metrics_unit_usage "$name") || true
    memh="$(_dash_human_bytes "$mem")"
    cpup="$(_dash_site_cpu "$name" "$cpu" "$now")"
    case "$st" in
      running|static) mark="$C_GREEN" ;;
      no-unit)        mark="$C_DIM" ;;
      *)              mark="$C_RED" ;;
    esac
    printf ' %-3s %-28s %s%-9s%s %-7s %-6s %-7s %s\n' \
      "$i" "$domain" "$mark" "$st" "$C_RESET" "$memh" "$cpup" \
      "$([[ "$(state_site_get "$domain" ssl)" == "true" ]] && _dash_cert_days "$domain" || echo "no")" \
      "$type"
  done < <(state_sites_list 2>/dev/null)
  (( i == 0 )) && printf ' %s(no site yet — press c to create one)%s\n' "$C_DIM" "$C_RESET"
  _DASH_PREV_TS="$now"

  # --- services + alerts ---
  printf '\n %sSERVICES%s  %s\n' "$C_BOLD" "$C_RESET" "$(_dash_services)"
  local alerts; alerts="$(_dash_alerts)"
  [[ -n "$alerts" ]] && printf ' %sALERTS%s    %s\n' "$C_BOLD" "$C_RESET" "$alerts"
}

_dash_window_label() {
  local window="$1" cols="$2"
  local hours=$(( window / 60 ))
  (( hours < 1 )) && { printf '└─ last %s min ─┘' "$window"; return 0; }
  printf '└─ last %sh ─┘' "$hours"
}

# CPU% of one core, from the delta in the unit's cumulative CPU time.
_dash_site_cpu() {
  local name="$1" cpu="$2" now="$3"
  local prev="${_DASH_PREV_CPU[$name]:-}"
  _DASH_PREV_CPU[$name]="$cpu"
  [[ -z "$prev" || "$_DASH_PREV_TS" == "0" ]] && { printf '-'; return 0; }
  local dt=$(( now - _DASH_PREV_TS ))
  (( dt <= 0 )) && { printf '-'; return 0; }
  (( cpu < prev )) && { printf '-'; return 0; }
  awk -v d=$(( cpu - prev )) -v t="$dt" 'BEGIN{printf "%.1f%%", (d/(t*1000000000))*100}'
}

_dash_services() {
  local out="" svc label
  for svc in nginx:nginx fail2ban:fail2ban; do
    label="${svc%%:*}"
    out+="$(_dash_svc_mark "$label" "${svc#*:}") "
  done
  local e
  for e in mariadb:mariadb postgres:postgresql mongo:mongod redis:redis-server; do
    state_service_installed "${e%%:*}" || continue
    out+="$(_dash_svc_mark "${e%%:*}" "${e#*:}") "
  done
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    out+="${C_GREEN}UFW${C_RESET}"
  else
    out+="${C_YELLOW}UFW off${C_RESET}"
  fi
  printf '%s' "$out"
}

_dash_svc_mark() {
  local label="$1" unit="$2"
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    printf '%s%s%s ·' "$C_GREEN" "$label" "$C_RESET"
  else
    printf '%s%s%s ·' "$C_RED" "$label" "$C_RESET"
  fi
}

_dash_alerts() {
  local out="" domain name days
  while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    name="$(state_site_get "$domain" name)"
    case "$(_site_status "$domain")" in
      running|static|no-unit) : ;;
      *) out+="${C_RED}${domain} down${C_RESET} · " ;;
    esac
    if [[ "$(state_site_get "$domain" ssl)" == "true" ]]; then
      days="$(_dash_cert_days "$domain")"; days="${days%d}"
      [[ "$days" =~ ^-?[0-9]+$ ]] && (( days < 14 )) \
        && out+="${C_YELLOW}cert ${domain} ${days}d${C_RESET} · "
    fi
  done < <(state_sites_list 2>/dev/null)
  local d; d="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5+0}')"
  [[ "$d" =~ ^[0-9]+$ ]] && (( d >= 90 && d <= 100 )) && out+="${C_RED}disk ${d}%${C_RESET} · "
  printf '%s' "${out% · }"
}

# ============ COMMAND ============

# dashboard [--once] [--interval N] [--window MINUTES]
cmd_dashboard() {
  state_init
  local once="" interval="${LAPN_DASHBOARD_INTERVAL:-3}" window=1440
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --once)     once=1; shift ;;
      --interval) interval="$2"; shift 2 ;;
      --window)   window="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  _dash_init_blocks
  metrics_ensure_timer

  local cols; cols="$(( $(tput cols 2>/dev/null || echo 80) - 40 ))"
  (( cols < 12 )) && cols=12
  (( cols > 60 )) && cols=60

  if [[ -n "$once" || "${LAPN_INTERACTIVE:-0}" != "1" ]]; then
    _dash_render "$cols" "$window"
    return 0
  fi

  local key domains=() d
  while true; do
    printf '\033[H\033[2J'
    _dash_render "$cols" "$window"
    printf '\n %sq%s quit   %sr%s refresh   %sc%s create site   %s1-9%s open site   %sw%s window: %s\n' \
      "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" \
      "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$(_dash_window_label "$window" "$cols")"

    key=""
    read -r -t "$interval" -n 1 key 2>/dev/null || true
    case "$key" in
      q|Q) printf '\n'; return 0 ;;
      c|C) printf '\n'; ( core_dispatch "site:create" ) || log_warn "Finished with an error."; lapn_pause ;;
      w|W) case "$window" in 60) window=360 ;; 360) window=1440 ;; *) window=60 ;; esac ;;
      [1-9])
        domains=()
        while IFS= read -r d; do [[ -n "$d" ]] && domains+=("$d"); done < <(state_sites_list)
        if (( key <= ${#domains[@]} )) && declare -F site_actions_menu >/dev/null; then
          site_actions_menu "${domains[$((key - 1))]}"
        fi ;;
      *) : ;;
    esac
  done
}
