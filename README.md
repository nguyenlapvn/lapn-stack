# LapN — Lightweight App Platform for Node.js

> Bộ script cài đặt & quản lý website Node.js (Next.js, Express/NestJS, static build) trên VPS Ubuntu qua terminal. Bảo mật là mặc định: per-site isolation, app chỉ bind localhost, systemd hardening, rate limit, SSL tự gia hạn.

**Lệnh chính:** `lapn` · **Tác giả:** Nguyễn Lập · **Repo:** [github.com/nguyenlapvn/lapn-stack](https://github.com/nguyenlapvn/lapn-stack)

## Cài đặt (VPS Ubuntu 22.04 / 24.04, RAM ≥ 2GB)

```bash
curl -sL https://raw.githubusercontent.com/nguyenlapvn/lapn-stack/main/install.sh | sudo bash
```

Hoặc clone rồi chạy:

```bash
git clone https://github.com/nguyenlapvn/lapn-stack /opt/lapn
sudo bash /opt/lapn/install.sh
```

Installer cài sẵn nginx + certbot deps, dựng `/etc/lapn`, viết rule UFW và cấu hình fail2ban.

> **Khi cài bằng `curl | sudo bash`** thì không có TTY, nên hai bước cần xác nhận bị bỏ qua: **đổi port SSH** và **bật UFW**. Rule firewall đã được ghi nhưng UFW vẫn tắt. Chạy nốt từ terminal:
>
> ```bash
> lapn security:ssh --port 2222     # tuỳ chọn, có flow chống tự khoá
> lapn security:firewall            # xác nhận rồi bật UFW
> ```
>
> `security:ssh` **không** tự tắt login root. Chỉ tắt khi bạn truyền `--no-root`, và cũng chỉ khi đã có user sudo khác (tránh tự khoá chính mình).

## Dùng nhanh

```bash
lapn                       # mở menu tương tác (mặc định khi chạy trong terminal)
lapn site:create           # wizard tạo site
lapn site:list
lapn deploy:git  --domain app.example.vn            # pull + build + restart
lapn ssl:issue   --domain app.example.vn --method dns-cloudflare --cf-token <API_TOKEN>
lapn stack:mariadb                                   # cài engine DB
lapn db:create   --site app.example.vn --engine mariadb
lapn db:remote   --add --user lapn_navicat --key "ssh-ed25519 AAAA..."
lapn doctor                # audit toàn server
lapn update                # tự cập nhật code trong /opt/lapn
lapn version
```

Phần lớn lệnh có dạng `module:action`; ba lệnh toàn cục không theo quy ước đó là `doctor`, `update` và `version`. Gõ `lapn` không tham số để mở menu (chạy không có TTY thì in help); gõ kèm flag để chạy không tương tác (CI/CD).

Tạo site không bắt buộc phải có repo ngay. Nếu bỏ trống Git repo, site vẫn được tạo (user, nginx, state) nhưng chưa có systemd unit — unit sẽ được dựng ở lần deploy đầu:

```bash
lapn site:create --domain app.example.vn --type express
lapn deploy:git  --domain app.example.vn --git git@github.com:you/app.git
```

### Node version

Mặc định là Node **24**. Node 20 đã hết hạn hỗ trợ từ 04/2026 nên không dùng làm mặc định nữa.

Trong menu: **Stack › Node versions** — xem default hiện tại + các version đã cài, cài thêm version, đổi default, hoặc chuyển một site đang chạy sang version khác.

```
LapN › Stack › Node

  Default for NEW sites : v24
  Installed for root    :
      * v20.19.0
      * v24.9.0 default

  1) Install a Node version
  2) Set the default for NEW sites
  3) Switch an EXISTING site to another version
```

Mỗi site **pin** version riêng trong `sites.json` lúc tạo, nên đổi mặc định không đụng gì tới site đang chạy — đó là lý do mục 2 và mục 3 tách riêng. Tương đương ở CLI:

```bash
lapn stack:node 24 --default        # đổi mặc định cho site TẠO MỚI (+ cài cho root)
lapn site:node --domain app.example.vn --node 24   # chuyển 1 site đang chạy sang 24
lapn site:create --domain x.vn --node 24           # pin ngay lúc tạo
```

`stack:node` chạy không kèm `--default` trong terminal sẽ hỏi có muốn đặt làm mặc định không. Nó ghi `LAPN_NODE_DEFAULT` vào `/etc/lapn/config` — file này được source **sau** `config/defaults.conf` nên override được mọi biến `LAPN_*`; `config/defaults.conf` trong repo là code, không sửa trực tiếp trên server.

`site:node` cài version mới cho user của site, **build lại** (native module biên dịch theo ABI cũ), rewrite unit systemd rồi restart + health check. Chạy với đúng version hiện tại thì nó chỉ re-render unit — đây cũng là cách sửa các site tạo bằng LapN < 0.3.2 (unit của chúng bị trỏ `ExecStart=/usr/bin/node`).

### SSL

| `--method` | Ai cấp cert | Khi nào dùng | Gia hạn |
|---|---|---|---|
| `certbot-nginx` | Let's Encrypt (HTTP-01) | DNS trỏ thẳng về VPS, **không** bật proxy Cloudflare (mây xám) | `certbot.timer`, tự động |
| `dns-cloudflare` | Let's Encrypt (DNS-01) | Có bật proxy Cloudflare (mây cam), hoặc cần wildcard | `certbot.timer`, tự động |
| `cf-origin` | Cloudflare Origin CA | Có bật proxy Cloudflare và muốn khỏi lo gia hạn | 15 năm, không cần |

```bash
lapn ssl:issue --domain app.example.vn --method certbot-nginx
lapn ssl:issue --domain app.example.vn --method dns-cloudflare --cf-token <API_TOKEN>
lapn ssl:issue --domain example.vn     --method dns-cloudflare --wildcard   # thêm *.example.vn
```

Vài điểm quyết định:

- **Mây cam (proxy bật) thì đừng dùng `certbot-nginx`.** Cloudflare chặn giữa port 80, và nếu bật "Always Use HTTPS" thì challenge HTTP-01 bị redirect → fail. Lệnh có cảnh báo khi phát hiện trường hợp này. Dùng `dns-cloudflare` — nó xác thực qua bản ghi TXT nên không quan tâm port 80.
- **Mây xám (Cloudflare chỉ làm DNS)** thì `certbot-nginx` chạy bình thường, đơn giản nhất, không cần API token.
- **`cf-origin` chỉ hợp lệ giữa Cloudflare và origin.** Tắt mây cam là trình duyệt báo lỗi cert ngay. Bù lại không bao giờ phải gia hạn. Nhớ đặt SSL mode = **Full (strict)** trên Cloudflare.
- Token cho `dns-cloudflare` cần quyền **Zone.DNS:Edit** trên zone đó. Truyền một lần bằng `--cf-token`, LapN lưu vào `/etc/lapn/secrets/cloudflare.token` (mode 600) để certbot dùng lại khi gia hạn.
- `--wildcard` là **opt-in**. Không bật thì cert chỉ gồm đúng domain bạn đưa.

Với `dns-cloudflare` / `cf-origin`, LapN tự bật snippet real-IP của Cloudflare — không có nó thì rate limit và fail2ban sẽ chặn theo IP edge của Cloudflare chứ không phải client thật.

`certbot-nginx` tự thêm block `:443` và redirect HTTP→HTTPS. Hai method còn lại chỉ thêm `:443`, không redirect — khi đứng sau Cloudflare thì bật "Always Use HTTPS" ở phía Cloudflare là đủ.

## Kiến trúc

```
bin/lapn        CLI router
lib/            core (log, ui, validate, net, state, core)
modules/        tính năng (site+deploy, db, ssl, security, doctor, stack, info) — tự khám phá
adapters/       nextjs / express / static
templates/      nginx / systemd / logrotate / env
config/         defaults.conf
tests/smoke.sh  test trên container Ubuntu trắng
```

Mỗi module tự khai báo `MODULE_NAME` / `MODULE_ORDER` / `MODULE_COMMANDS`, `lib/core.sh` quét `modules/[0-9]*.sh` để dựng menu và router — thêm file là có lệnh mới, không phải sửa chỗ nào khác.

### nginx: mỗi site 2 file

- `sites-available/lapn-<name>.conf` — chỉ `listen` + `server_name`, rồi `include` file dưới.
- `snippets/lapn-site-<name>.conf` — toàn bộ phần thân: security headers, rate limit, `client_max_body_size`, real-IP Cloudflare, `root` (static) và các `location`.

Cả block `:80` và block `:443` đều include cùng một file thân, nên cấu hình HTTP và HTTPS không bao giờ lệch nhau.

### Mỗi site

- user hệ thống riêng `site_<name>`, home `/home/sites/<name>` mode 750
- app bind `127.0.0.1:<port nội bộ 3001-3999>`, chỉ nginx proxy vào
- systemd unit `lapn-<name>.service` có hardening (`ProtectSystem=strict`, `NoNewPrivileges`, `MemoryMax`, `CPUQuota`…)
- `.env` nguồn ở `/etc/lapn/secrets/<name>/.env` (mode 600, owner root), systemd nạp qua `EnvironmentFile=`
- state tập trung ở `/etc/lapn/sites.json`, chỉ đọc/ghi qua `lib/state.sh`

## Phát triển

Dev trên Windows nhưng script chạy Linux — `.gitattributes` ép LF. Test trong Docker:

```bash
# cần --privileged để systemd thật chạy được trong container
docker run -it --rm --privileged -v ${PWD}:/opt/lapn jrei/systemd-ubuntu:24.04
# trong container:
bash /opt/lapn/tests/smoke.sh
```

`smoke.sh` chạy được ở mọi nơi cho phần lint (`bash -n`, `shellcheck`) và unit test của `lib/validate.sh`; phần end-to-end (install → tạo site → curl → xoá site) chỉ chạy khi có root + systemd.

Bật `shellcheck` khi code. Mọi script mở đầu bằng `set -euo pipefail`. Bump `VERSION` ở mỗi lần đổi code.
