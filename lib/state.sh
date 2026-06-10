#!/usr/bin/env bash
# lib/state.sh — đọc/ghi /etc/lapn/sites.json qua jq. Ghi atomic. Schema migration.
# Không module nào được tự cat/sed file này.

# state_init — tạo sites.json rỗng nếu chưa có.
state_init() {
  [[ -d "$LAPN_ETC" ]] || mkdir -p "$LAPN_ETC"
  if [[ ! -f "$LAPN_STATE" ]]; then
    jq -n --argjson v "${LAPN_SCHEMA_VERSION:-1}" \
      '{schema_version: $v, services: {}, sites: {}}' >"$LAPN_STATE"
    chmod 600 "$LAPN_STATE"
  fi
}

# _state_write_atomic — đọc JSON từ stdin, ghi đè state qua file tạm + mv.
_state_write_atomic() {
  local tmp; tmp="$(mktemp "${LAPN_STATE}.XXXXXX")"
  cat >"$tmp"
  # Kiểm tra JSON hợp lệ trước khi đè.
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; die "state.sh: JSON sinh ra không hợp lệ, hủy ghi."
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$LAPN_STATE"
}

# state_jq <filter> [args...] — chạy jq đọc trên state (read-only).
state_jq() {
  state_init
  jq "$@" "$LAPN_STATE"
}

# state_update <filter> [jq args...] — áp filter rồi ghi đè atomic.
state_update() {
  state_init
  local filter="$1"; shift
  jq "$@" "$filter" "$LAPN_STATE" | _state_write_atomic
}

# --- Sites ---

# state_site_exists <domain>
state_site_exists() {
  state_jq -e --arg d "$1" '.sites | has($d)' >/dev/null 2>&1
}

# state_site_get <domain> [field] — in object site, hoặc một field.
state_site_get() {
  local d="$1" field="${2:-}"
  if [[ -n "$field" ]]; then
    state_jq -r --arg d "$d" --arg f "$field" '.sites[$d][$f] // empty'
  else
    state_jq --arg d "$d" '.sites[$d] // empty'
  fi
}

# state_site_put <domain> <json object> — chèn/ghi đè một site.
state_site_put() {
  local d="$1" obj="$2"
  state_update '.sites[$d] = $obj' --arg d "$d" --argjson obj "$obj"
}

# state_site_set_field <domain> <field> <json value>
state_site_set_field() {
  local d="$1" f="$2" v="$3"
  state_update '.sites[$d][$f] = $v' --arg d "$d" --arg f "$f" --argjson v "$v"
}

# state_site_del <domain>
state_site_del() {
  state_update 'del(.sites[$d])' --arg d "$1"
}

# state_sites_list — in danh sách domain (mỗi dòng một domain).
state_sites_list() {
  state_jq -r '.sites | keys[]?'
}

# --- Services (engine DB cấp server) ---

# state_service_installed <engine>
state_service_installed() {
  state_jq -e --arg e "$1" '.services[$e].installed == true' >/dev/null 2>&1
}

# state_service_put <engine> <json object>
state_service_put() {
  state_update '.services[$e] = $obj' --arg e "$1" --argjson obj "$2"
}

# --- Migration ---

# state_migrate — kiểm tra schema_version, chạy migrate nếu thấp hơn.
state_migrate() {
  state_init
  local cur target="${LAPN_SCHEMA_VERSION:-1}"
  cur="$(state_jq -r '.schema_version // 0')"
  if (( cur < target )); then
    log_info "Migrate state $cur → $target"
    # v0/khuyết → v1: đảm bảo có services & sites.
    if (( cur < 1 )); then
      state_update '.services //= {} | .sites //= {} | .schema_version = 1'
    fi
    # Các bước migrate tương lai thêm ở đây (v1 → v2 ...).
  fi
}
