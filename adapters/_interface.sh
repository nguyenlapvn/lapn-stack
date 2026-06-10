#!/usr/bin/env bash
# adapters/_interface.sh — hợp đồng chung cho mọi adapter.
# Mỗi adapter (nextjs/express/static) override các hàm dưới đây.
#
# Quy ước:
#   - Các hàm nhận biến môi trường: SITE_DOMAIN, SITE_NAME, SITE_USER, SITE_ROOT, SITE_PORT, SITE_NODE.
#   - adapter_build/start chạy với cwd = $SITE_ROOT (do module gọi đã `cd`/`sudo -u`).
#
# adapter_detect       -> return 0 nếu nhận diện được loại app từ $SITE_ROOT/package.json
# adapter_needs_unit    -> return 0 nếu cần systemd unit (static = 1/false)
# adapter_build         -> build app (npm ci && npm run build...), chạy dưới user site
# adapter_start_cmd     -> in ra ExecStart đầy đủ (đường dẫn node + entrypoint)
# adapter_env_defaults  -> in các dòng KEY=VALUE thêm vào .env
# adapter_health_url    -> in path health check (mặc định /)

# --- Mặc định (adapter có thể override) ---
adapter_detect()       { return 1; }
adapter_needs_unit()   { return 0; }
adapter_build()        { return 0; }
adapter_start_cmd()    { printf ''; }
adapter_env_defaults() { printf ''; }
adapter_health_url()   { printf '/'; }

# node_bin_for <user> <node_version> -> in đường dẫn node của user qua fnm.
# fnm cài per-user; fallback node hệ thống nếu không tìm thấy.
adapter_node_bin() {
  local user="$1" ver="$2" home bin
  home="$(getent passwd "$user" | cut -d: -f6)"
  # fnm layout: ~/.local/share/fnm/node-versions/vXX.*/installation/bin/node
  bin="$(sudo -u "$user" bash -lc "command -v node" 2>/dev/null || true)"
  if [[ -n "$bin" ]]; then printf '%s' "$bin"; return 0; fi
  # Thử tìm trong fnm dir.
  local found
  found="$(find "$home/.local/share/fnm/node-versions" -maxdepth 3 -name node -type f 2>/dev/null \
            | grep "/v${ver}" | head -n1 || true)"
  [[ -n "$found" ]] && { printf '%s' "$found"; return 0; }
  printf '/usr/bin/node'
}

# load_adapter <type> — source adapter tương ứng (sau khi đã source _interface).
load_adapter() {
  local type="$1"
  local f="$LAPN_HOME/adapters/$type.sh"
  [[ -f "$f" ]] || die "Không tìm thấy adapter cho loại '$type'."
  # shellcheck source=/dev/null
  source "$f"
}
