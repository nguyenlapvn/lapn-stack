# LapN — Lightweight App Platform for Node.js

> Bộ script cài đặt & quản lý website Node.js (Next.js, Express/NestJS, static build) trên VPS Ubuntu qua terminal. Bảo mật là mặc định: per-site isolation, app chỉ bind localhost, systemd hardening, rate limit, SSL tự gia hạn.

**Lệnh chính:** `lapn` · **Tác giả:** Nguyễn Lập

## Cài đặt (VPS Ubuntu 22.04 / 24.04, RAM ≥ 2GB)

```bash
curl -sL https://raw.githubusercontent.com/<user>/lapn-stack/main/install.sh | sudo bash
```

Hoặc clone rồi chạy:

```bash
git clone https://github.com/<user>/lapn-stack /opt/lapn
sudo bash /opt/lapn/install.sh
```

## Dùng nhanh

```bash
lapn                       # mở menu tương tác (mặc định)
lapn site:create           # wizard tạo site
lapn site:list
lapn ssl:issue   --domain app.example.vn --method dns-cloudflare
lapn db:install  mariadb
lapn db:remote   --add --user lapn_navicat --key "ssh-ed25519 AAAA..."
lapn doctor                # audit toàn server
```

Mọi lệnh đều có dạng `module:action`. Gõ `lapn` không tham số để mở menu; gõ kèm flag để chạy không tương tác (CI/CD).

## Kiến trúc

Xem [docs/plan.md](docs/plan.md) — thiết kế đầy đủ (core, bảo mật, luồng nghiệp vụ, roadmap).

```
bin/lapn        CLI router
lib/            core (log, ui, validate, net, state, core)
modules/        tính năng (stack, site, ssl, security, deploy, db, doctor) — tự khám phá
adapters/       nextjs / express / static
templates/      nginx / systemd / logrotate / env
config/         defaults.conf
tests/smoke.sh  test trên container Ubuntu trắng
```

## Phát triển

Dev trên Windows nhưng script chạy Linux — `.gitattributes` ép LF. Test trong Docker:

```bash
docker run -it --rm -v ${PWD}:/opt/lapn jrei/systemd-ubuntu:24.04
# trong container:
bash /opt/lapn/tests/smoke.sh
```

Bật `shellcheck` khi code. Mọi script mở đầu bằng `set -euo pipefail`.
