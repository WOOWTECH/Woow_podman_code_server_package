# Woow Podman code-server

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.4%20rootless-892CA0)](https://podman.io)
[![Quadlet](https://img.shields.io/badge/units-Quadlet%20%2B%20systemd-orange)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
[![code-server](https://img.shields.io/badge/code--server-4.135.0-blueviolet)](https://github.com/coder/code-server)
[![pi-coding-agent](https://img.shields.io/badge/pi--coding--agent-0.83.0-blue)](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
[![ACP](https://img.shields.io/badge/ACP%20client-formulahendry.acp--client%400.2.0-green)](https://open-vsx.org/extension/formulahendry/acp-client)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[English](README.md) · **繁體中文**

把 [`code-server`](https://github.com/coder/code-server)（瀏覽器版 VS Code）
封裝成 rootless Podman 用的 addon，內建 [pi coding agent](https://github.com/earendil-works/pi)
與 [ACP Client](https://open-vsx.org/extension/formulahendry/acp-client)
extension 且**預設接線好**——開側邊 ACP 樹、點 `pi`，右側面板直接跟 pi 對談。

pi 的狀態（登入、sessions、skills、模型設定）**這個部署內部私有**——不再跟任何
姊妹套件共用。這跟 WOOWTECH 的 Home Assistant add-on 與 k3s chart 對齊：三邊
各自保管自己的 pi 狀態。完整跨平台契約見 [`PARITY_CONTRACT.md`](PARITY_CONTRACT.md)。

---

## 提供什麼

| | |
|---|---|
| **UI** | `http://<host>:8443` — 密碼保護、只給區網 |
| **IDE** | code-server 4.135.0，extension 走 OpenVSX |
| **Agent** | pi 0.83.0，右側 ACP chat panel 直接可用；terminal PATH 上也有 `pi` |
| **Workspace** | 主機 `~/Desktop` bind-mount 到 `/workspace`——你在編輯器改的檔案主機直接看得到，也還是你的擁有者 |
| **持久化** | pi 狀態存在內部的 `woow-code-server-pi-data` volume；IDE 設定存在 `woow-code-server-ide`；container 重建、重開機都不丟 |
| **監管** | `systemd --user` via Quadlet，30 秒健康檢查 |

---

## pi 接線的原理 —— 30 秒版

VS Code 裡的 ACP Client extension 執行 `acp.agents.<name>.command` 定義的指令。
本 image 出貨 `/usr/local/bin/pi-code` 作為那個指令，它只做一件事：
把 `HOME` 重定向到 `/data/pi-agent/home`（內部 volume 掛的地方）、然後
`exec pi-acp`，pi-acp 再 spawn `pi --mode rpc` 走 stdio。

```
VS Code（瀏覽器）→ ACP extension → pi-code → pi-acp → pi --mode rpc
                                    │
                                    └─ export HOME=/data/pi-agent/home
```

`HOME` 覆寫**只發生在 wrapper 裡**（不會動到 code-server 容器層的 HOME），
所以 IDE 自己的狀態原封不動，只有 pi 子行程看得到 `/data/pi-agent`。
`pi-code`、`/etc/profile.d/pi.sh`（同樣邏輯套用到 terminal 裡直接打的 `pi`）
以及新增的 `pi-seed` 這三個檔案在 podman/HA/k3s 三邊都是逐位元組相同的
——見 `rootfs/opt/SHA256SUMS`。

完整決策紀錄在 `docs/plans/2026-08-30-initial-package.md`，`2026-09-xx`
那段補記了「pi 狀態改內部化」的決策。

---

## 安裝

需 Podman ≥ 4.4（Quadlet）、rootless、以擁有 podman storage 的帳號執行。

```bash
git clone https://github.com/WOOWTECH/Woow_podman_code_server_package.git
cd Woow_podman_code_server_package

./scripts/install.sh
```

`install.sh` 做什麼：
1. 檢查 podman + Quadlet
2. `loginctl enable-linger`（登出後仍運行）
3. 若 `~/.gitconfig` 是空的、`~/.ssh` 沒有私鑰、或 `~/.local/bin` 裡有失效
   symlink，會警告（不會中止）——下面四個 host mount 要這些東西是真的才
   能用
4. 若還沒有 `~/.config/woow-code-server/env`（mode 600），建立一份並隨機
   產生 `PASSWORD`/`SUDO_PASSWORD`——密碼因此不會進 git
5. `podman build` → `localhost/woow-code-server:latest`
6. 把 `quadlet/code-server.container`、兩個新的 `*.volume` unit、以及兩個
   健康檢查 unit 放進對應的 `~/.config/...` 目錄
7. `systemctl --user daemon-reload && start code-server && enable --now
   code-server-health.timer`
8. 等 `/healthz` 回 200

想跳過 image 重建：`OD_SKIP_BUILD=1 ./scripts/install.sh`。

### 首次使用

開 `http://<host>:8443`、輸入 `install.sh` 結束時印出的密碼（也存在
`~/.config/woow-code-server/env` 裡）。

這個部署的內部 pi 儲存還**沒有任何登入憑證**，先登入一次：

```bash
podman exec -it -u coder code-server sh -lc 'pi login'
```

之後在 IDE 裡：底部狀態列會顯示 `ACP: pi ACP adapter`（綠燈）、右側面板
就是用這次登入在跑的 chat。

> **從舊版（用共用 `pi-agent-data` volume）升級？** 跑
> `./scripts/migrate-pi-state.sh` 把 `settings.json` 和 ACP session map
> 搬過來（絕對不會搬 `auth.json`——看該腳本自己的警告，改用 `pi login`
> 比較安全）。

### 移除

```bash
./scripts/uninstall.sh            # 保留 woow-code-server-pi-data + -ide
./scripts/uninstall.sh --purge    # 連同上面兩顆一起刪（會先問 y/N）
```

---

## 目錄結構

```
Containerfile              base codercom/code-server + Node 22 + pi + pi-acp + ACP extension
quadlet/
  code-server.container      podman 容器定義 + 掛載 + env
  woow-code-server-pi.volume  內部 pi 狀態 volume
  woow-code-server-ide.volume 內部 IDE 使用者資料 volume
rootfs/
  usr/local/bin/pi-code     ACP extension 呼叫的 HOME wrapper
  usr/local/bin/pi-seed     冪等的 pi 狀態初始化腳本（HA/k3s 共用同一份）
  etc/profile.d/pi.sh       讓 terminal 的 `pi` 指到同一個儲存位置
  etc/skel/…/settings.json  預設 VS Code 設定，把 ACP adapter 指到 pi-code
  opt/SHA256SUMS            上面三個共用檔案的雜湊值
systemd/
  code-server-health.{service,timer}   30s healthcheck 更新
scripts/
  install.sh                 build + install + start + wait /healthz
  uninstall.sh                stop + remove（預設保留 pi/ide volume）
  migrate-pi-state.sh          從舊的共用 pi-agent-data volume 選擇性搬移
tests/
  lib/parity.sh               通用測試轉接器（PARITY_TARGET=podman|ha|k3s）
  smoke-container.sh          container up、/healthz 200、錯誤密碼擋掉
  smoke-pi-integration.sh     pi/pi-acp/pi-code 齊全、內部儲存已初始化
  smoke-acp.sh                extension 有裝、settings.json 6 個必要 key 都對
docs/plans/                塑造本 package 的設計決策
.github/workflows/build.yml    amd64 + arm64 CI，push/release 推到 ghcr
```

---

## 驗收部署

```bash
# 便宜測試套 — 零 LLM 呼叫、零成本，跑在主機上。
bash tests/smoke-container.sh          # /healthz + 密碼閘
bash tests/smoke-pi-integration.sh     # pi + pi-acp + pi-code + 內部儲存
bash tests/smoke-acp.sh                # extension + settings.json
```

三支要全綠。`smoke-pi-integration.sh` 在你還沒 `pi login` 之前，
`auth.json` 那條會 skip（不 fail）。

---

## 日常操作

```bash
podman ps --format '{{.Names}}\t{{.Status}}'      # 健康狀態
journalctl --user -u code-server -f               # systemd events
podman logs -f code-server                        # code-server output
podman exec -it code-server bash                  # 進 IDE 環境的 shell
systemctl --user restart code-server              # 重啟（pi + IDE 狀態都存在各自的 volume，不會丟）
```

想升 code-server 版：改 `Containerfile` 的 `ARG CODE_SERVER_VERSION=`、跑
`./scripts/install.sh`（會觸發重 build）、`systemctl --user restart
code-server`。`PI_CODING_AGENT_VERSION` / `PI_ACP_VERSION` /
`ACP_CLIENT_VERSION` 同理，但這三個版本要跟另外兩個 code-server 部署
（HA add-on、k3s chart）**同步升**——動之前先看 `PARITY_CONTRACT.md` §2.1。

---

## 安全

直說。

**刻意的短路。** `~/.config/woow-code-server/env` 裡自動產生的
`PASSWORD` 在公司區網、防火牆後面是可以接受的。超出這條就**不行**——
密碼走 HTTP 是每 request 都 base64 傳。要對外開放的話：
- 前面掛一層有 auth 的 reverse proxy（nginx / NPM / Cloudflare Access）+
  TLS，同時把 env 檔裡的 `PASSWORD` 改強
- 或把 `PublishPort=` 改成 `127.0.0.1:8443:8080`，強迫走 reverse proxy

**ACP 聊天 webview 需要瀏覽器信任的 HTTPS。** 側邊樹狀圖、狀態列、pi
adapter 連線在純 HTTP 下都正常。**聊天 webview 面板不行**——VS Code 的
webview 內容是透過 ServiceWorker 送達的，而 ServiceWorker 註冊要求
origin 是「安全」的（`localhost`，或是作業系統信任的憑證）。使用者在
頁面層級點「繼續前往」通過的自簽憑證，SW 那層還是會擋下來。這是目前
podman 這邊唯一跟 HA add-on、k3s chart **不對齊**的地方——後兩者都坐在
瀏覽器信任的來源後面（HA ingress；Cloudflare Tunnel 網域），聊天
webview 也都證實可以動；podman 預設的區網曝光方式是純 HTTP。想讓這裡的
聊天面板也動起來：
- 建議做法：前面掛 NPM / nginx / Cloudflare Access，帶一張 Let's
  Encrypt（或同等作業系統信任）的憑證，並把 `PublishPort=` 改成
  `127.0.0.1:8443:8080`。
- 替代做法：在每台使用者機器上用 [`mkcert`](https://github.com/FiloSottile/mkcert)
  （跑一次 `mkcert -install`，再 `mkcert <host-ip>` 簽憑證），把
  code-server 指到那張憑證，瀏覽器就會在本機信任它、不會跳警告。
- 零基礎設施做法：SSH port-forward 到主機
  （`ssh -L 8443:localhost:8443 <host>`），瀏覽
  `http://localhost:8443`——`localhost` 永遠是安全 context，完全不需要
  憑證就能讓 webview 動起來。
- 不夠的做法：單獨開 `code-server --cert`。2026-08-30 的實機測試已經
  證實——頁面點過警告後能載入，但 webview 的 SW 在自簽憑證上還是拒絕
  註冊。

**如果你自己加了 reverse proxy，有一個通用陷阱要注意：** proxy 一定要
把瀏覽器實際使用的 `Host`/`Origin` 原封不動轉發過去，否則 code-server
會把 WebSocket upgrade 判 403。這個症狀看起來跟上面的 ServiceWorker /
secure-context 問題一模一樣，但其實是完全不同、不相關的成因——如果加了
proxy 之後側邊欄、terminal 整個死掉（即使憑證是對的），在 quadlet 的
`Exec=` 裡加上 `--trusted-origins <hostname>` 給 code-server。

**容器能做什麼。** `code-server` 以 `coder` (uid 1000) 執行，rootless user
namespace 對應到主機你的 uid。容器內 `sudo` 用 `SUDO_PASSWORD` 開啟——
不想讓用戶 runtime apt-install 東西，就把 `~/.config/woow-code-server/env`
裡那行拿掉。

**Bind mount。** `~/Desktop`、`~/.ssh`、`~/.gitconfig`、`~/.local/bin` 都是從
你主機的 uid 1000 掛進去。任何拿到 code-server shell 的都讀得到。`.ssh` 刻意
`:ro`——安全性不比執行本 script 的用戶差。提醒：在全新主機上，這幾個
mount 來源可能根本還不能用——`install.sh` 會明講（`.gitconfig` 是空的、
`.ssh` 沒私鑰、`.local/bin` 裡有失效 symlink）。

**pi 的憑證。** pi 唯一持有的憑證是一組 OAuth pair（`auth.json`，mode
600）——access token、refresh token、到期時間、帳號 id，由 `pi login`
寫入。預設**沒有任何 API key**（`models.json` 是 `{"providers":{}}`，
除非你設定 `PI_PROVIDER_KEYS_JSON`）。`auth.json` 存在內部的
`woow-code-server-pi-data` volume 裡；任何拿到本 container shell 的人
都讀得到。pi 每次 refresh 都會**覆寫** refresh token——這正是本 repo
不把 `auth.json` 複製到多個部署的原因：複製到兩個地方，哪邊先 refresh
就可能讓另一邊失效。請在每個部署裡各自重新 `pi login`。

---

## 相關套件

- [ACP Client (formulahendry)](https://open-vsx.org/extension/formulahendry/acp-client) — 右側 agent chat panel 的 VS Code extension
- [pi-acp](https://www.npmjs.com/package/pi-acp) — 社群做的 ACP JSON-RPC → pi `--mode rpc` bridge
- [`Woow_ha_code_server_add_on`](https://github.com/WOOWTECH/Woow_ha_code_server_add_on) — 同一套 pi/ACP 接線，包成 Home Assistant add-on
- [`Woow_k3s_code_server_package`](https://github.com/WOOWTECH/Woow_k3s_code_server_package) — 同一顆 image，用 Helm + Cloudflare Tunnel 部署到 k3s

## 授權

MIT
