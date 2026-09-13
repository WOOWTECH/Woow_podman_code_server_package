# Woow Podman code-server

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.9%20rootless-892CA0)](https://podman.io)
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
| **UI** | `http://127.0.0.1:18443` — 密碼保護，預設只聽 loopback（SSH port-forward、選用的 tailscale sidecar，或同主機上的 proxy） |
| **IDE** | code-server 4.135.0，extension 走 OpenVSX |
| **Agent** | pi 0.83.0，右側 ACP chat panel 直接可用；terminal PATH 上也有 `pi` |
| **Workspace** | 主機 `~/Desktop` bind-mount 到 `/workspace`——你在編輯器改的檔案主機直接看得到，也還是你的擁有者 |
| **持久化** | pi 狀態存在內部的 `woow-code-server-pi-data` volume；IDE 設定存在 `woow-code-server-ide`；container 重建、重開機都不丟 |
| **監管** | `systemd --user` via Quadlet，`Restart=always`，30 秒健康檢查 |

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

需要 rootless Podman >= 4.9（含 Quadlet 產生器），以擁有 podman storage 的帳號執行。已在
Ubuntu 24.04（podman 4.9.3、systemd 255）並啟用 linger 的環境測試。

```bash
git clone https://github.com/WOOWTECH/Woow_podman_code_server_package.git
cd Woow_podman_code_server_package

scripts/install.sh                      # 或：scripts/install.sh --port 8443 --bind 0.0.0.0
```

`scripts/install.sh` 可重複執行：沒有變更時重跑不會重啟任何東西。它會：

1. 檢查主機（不是 root、podman >= 4.9、有 Quadlet 產生器、`systemctl --user` 可用），並啟用
   linger，讓 IDE 在登出後仍在、開機自動回來；
2. 第一次執行時，從 [`config/woow-code-server.env.example`](config/woow-code-server.env.example)
   建立 `~/.config/woow-code-server/woow-code-server.env`（權限 0600）。`--port N`、
   `--bind ADDR`、`--set KEY=VALUE` 會改設定並存回該檔；
3. 若已有一個不受 Quadlet 管理、名為 `code-server` 的容器（Quadlet 用
   `podman run --replace` 啟動容器，會把它刪掉），或埠號已被占用，就拒絕繼續；
4. 用該 env 檔渲染 [`quadlet/`](quadlet/) 內的單元（`@@VAR@@` 標記，白名單在
   `quadlet/render-vars`），並在安裝任何東西**之前**，用 podman 4.9.3 的 Quadlet 產生器與
   `systemd-analyze --user verify` 檢查；
5. 建立缺少的 bind mount 來源（workspace、`~/.ssh` 0700、空的 gitconfig、`~/.local/bin`），
   從 `GIT_USER_NAME`/`GIT_USER_EMAIL` 或詢問來設定 git 身分，並對缺少 SSH 私鑰、失效
   symlink 提出警告；
6. 若 `localhost/woow-code-server:$(cat VERSION)` 這個 tag 還不存在就建置（`--rebuild` 強制
   重建，`--no-build` 禁止建置）；
7. 若 podman secret `code-server-config` 不存在，建立一組隨機 24 字元密碼（若存在舊的
   `~/.config/woow-code-server/env`，則沿用裡面的密碼，使用者不會被鎖在外面）；
8. 只安裝有變更的檔案、只重啟檔案有變更的單元，並啟用 `code-server-health.timer`；
9. 等容器變成 healthy，然後執行 `tests/smoke.sh --quick`。

`scripts/install.sh --dry-run` 會渲染並驗證全部內容、回報將會變更什麼，但不做任何變更。

### 設定

編輯 `~/.config/woow-code-server/woow-code-server.env` 後重新執行 `scripts/install.sh`（或用
`--set KEY=VALUE`）。這些值會渲染進單元檔，所以值有變更就重啟容器，沒變更就不重啟。

| 鍵 | 預設 | 說明 |
|---|---|---|
| `CODE_SERVER_BIND` | `127.0.0.1` | 發布位址。改成區網 IP 或 `0.0.0.0`，等於把純 HTTP 的密碼頁放到那個網路上，而且 ACP 聊天 webview 在那裡不會顯示（見 [安全](#安全)）。 |
| `CODE_SERVER_PORT` | `18443` | 主機埠號。舊的預設 `8443` 會跟 `Woow_podman_vpn_tailscale_package` 的 Caddy proxy 衝突。 |
| `CODE_SERVER_WORKSPACE` | `%h/Desktop` | IDE 開啟的資料夾，bind mount 到 `/workspace`。`%h` 是執行安裝的使用者家目錄。 |
| `CODE_SERVER_SSH_DIR` | `%h/.ssh` | 唯讀掛到 `/home/coder/.ssh`。 |
| `CODE_SERVER_GITCONFIG` | `%h/.gitconfig` | 唯讀掛到 `/etc/gitconfig`（git 的 system 路徑）。 |
| `CODE_SERVER_HOST_BIN` | `%h/.local/bin` | 唯讀掛到 `/mnt/host-local-bin`，排在 `PATH` 最前面。 |
| `PI_DEFAULT_PROVIDER` / `PI_DEFAULT_MODEL` | `openai-codex` / `gpt-5.6-sol` | 只有在 pi 的 `settings.json` 不存在時才寫入。 |
| `CODE_SERVER_TAILSCALE` | `no` | 設 `yes` 會安裝下面的選用 sidecar（`--with-tailscale`）。 |
| `CODE_SERVER_TS_HOSTNAME` | `woow-code-server` | 該 sidecar 的 tailnet 節點名稱。 |

### 首次使用

```bash
scripts/show-password.sh                # 從 podman secret 取出登入密碼
```

密碼放在 podman secret `code-server-config` 裡，內容是一小段 YAML 設定檔，由 code-server 透過
`$CODE_SERVER_CONFIG` 讀取；它不在單元檔裡、不在 `podman inspect` 裡、也不在容器環境變數裡。
要輪替密碼：`scripts/install.sh --rotate-password`。

在主機上開 `http://127.0.0.1:18443`，或從別台機器轉發：

```bash
ssh -L 18443:127.0.0.1:18443 <host>     # 然後開 http://localhost:18443
```

這個部署的內部 pi 儲存還**沒有任何登入憑證**，先登入一次：

```bash
podman exec -it -u coder code-server sh -lc 'pi login'
```

之後在 IDE 裡：底部狀態列會顯示 `ACP: pi ACP adapter`（綠燈），右側面板就是用這次登入在跑的
chat。

> **從舊版（用共用 `pi-agent-data` volume）升級？** 跑 `scripts/migrate-pi-state.sh` 把
> `settings.json` 和 ACP session map 搬過來（絕對不會搬 `auth.json`——看該腳本自己的警告，
> 改用 `pi login` 比較安全）。

### 選用：tailnet 前門（tailscale sidecar）

ACP 聊天 webview 只在瀏覽器信任的來源（或 `localhost`）才會顯示。這個 sidecar 讓本部署有一個
帶真憑證的 tailnet HTTPS 名稱，而且不需要在區網上公開任何埠：

```bash
scripts/install.sh --with-tailscale --ts-authkey-file ~/ts.key   # 建議用 tagged、ephemeral、預先核准的 key
```

它會安裝 `quadlet/optional/woow-tailscale-code-server.*`：一個 userspace 模式、跑在 host 網路
上的 tailscale 節點，把 `http://127.0.0.1:<port>` 服務在
`https://<CODE_SERVER_TS_HOSTNAME>.<tailnet>.ts.net/`；auth key 放在 podman secret，serve 設定
由 `config/tailscale-serve.json.in` 渲染。`scripts/install.sh --without-tailscale` 會把 sidecar
移除（保留它的節點狀態 volume）。若該主機的節點已經登入過，會沿用既有的狀態 volume，不需要
auth key。

### 升級

```bash
git pull
scripts/upgrade.sh
```

`upgrade.sh` 會先為已安裝的單元做快照、執行 `scripts/backup.sh`，再執行 `scripts/install.sh`
（建置新的 `VERSION` tag 並重啟有變更的部分）與完整的 `tests/smoke.sh`。任何一步失敗，就放回
先前的單元、以先前的映像 tag（仍然存在）重啟，並以 1 結束。升級成功後會保留目前與前一個映像
tag，刪掉更舊的（`--keep-images` 全部保留）。

`VERSION` 的格式是 `<code-server 版本>-<套件修訂>`，必須與單元的 `Image=` tag 及 Containerfile
的 `ARG CODE_SERVER_VERSION` 一致；不一致時 CI 會失敗。升 pi/pi-acp/ACP 版本是另一件跨平台的
事——動之前先看 `PARITY_CONTRACT.md` §2.1。

### 備份與還原

```bash
scripts/backup.sh                       # -> ~/backups/woow-code-server/<時間戳>/
scripts/backup.sh --include-secrets     # 另外存登入密碼與 tailscale key（secrets/ 目錄）
scripts/backup.sh --stop                # 匯出期間停止 IDE，pi 狀態更一致
scripts/restore.sh ~/backups/woow-code-server/<時間戳>      # 會先詢問；--yes 略過
```

備份會匯出 `woow-code-server-pi-data`（pi 登入、sessions、skills）、`woow-code-server-ide`
（IDE 設定），以及存在時的 sidecar 狀態 volume，每個都附 `.sha256`，並複製一份 env 檔。
`restore.sh` 會停止 IDE、換掉這些 volume、再啟動並跑 smoke 測試。

### 移除

```bash
scripts/uninstall.sh                    # 停止並移除單元；保留 volume、secret 與映像
scripts/uninstall.sh --purge            # 另外刪除 volume（會先做最後一次備份）與 secret
scripts/uninstall.sh --purge-images     # 另外移除 localhost/woow-code-server:* 映像
```

`--purge` 是這些腳本刪除資料的唯一方式；它會要求輸入應用名稱確認（`--yes` 可略過，供腳本使
用）。一般移除後再跑 `scripts/install.sh`，會沿用同樣的 volume 與同樣的密碼。你的 workspace、
`~/.ssh`、`~/.gitconfig`、`~/.local/bin` 與 env 檔永遠不會被動到。

### 遷移既有部署

適用於已經在跑轉換前單元的主機（手動安裝的 Quadlet 檔，例如 woowtechopenclaw）：

1. 先備份：`scripts/backup.sh --include-secrets` 需要單元已安裝，所以改用
   `podman volume export woow-code-server-pi-data -o ~/pi-data-pre-quadlet.tar`（`-ide` 同理），
   並保留一份舊的單元檔。
2. `~/.config/systemd/user/` 裡舊的健康檢查單元不是這些腳本安裝的，所以 `install.sh` 會拒絕覆蓋
   它們。先移開一次：`systemctl --user disable --now code-server-health.timer`、
   `mv ~/.config/systemd/user/code-server-health.{service,timer} ~/backups/`。
3. `scripts/install.sh --port 18443`（或 `--port 8443 --bind 0.0.0.0` 保留舊的端點）。既有的
   `code-server.container` 與兩個 `*.volume` 會在備份一份到
   `~/.local/state/woow-quadlet/woow-code-server/replaced/` 之後被接管；volume 保留資料；
   `~/.config/woow-code-server/env` 裡的密碼會被收進 podman secret，沒有人會被鎖在外面。
4. 確認可以登入之後，刪掉 `~/.config/woow-code-server/env` 與所有 `env.bak-*`：它們以明文存著
   密碼。
5. **端點會改變**：除非你指定舊的值，否則會從 `0.0.0.0:8443` 變成 `127.0.0.1:18443`。原本用
   `http://<host>:8443` 的區網使用者會連不到，手動設定的 tailscale `serve --tcp=8443` 也會對不
   上。請先公告新網址，或改用本 repo 的 sidecar（`--with-tailscale`）——它透過
   `woow-tailscale-code-server-state` volume 保留節點身分，網址變成
   `https://<hostname>.<tailnet>.ts.net/`。

回復：`scripts/uninstall.sh`，把
`~/.local/state/woow-quadlet/woow-code-server/replaced/<時間戳>/` 裡的舊單元檔放回去，
`daemon-reload` 後啟動。

---

## 目錄結構

```
VERSION                    <code-server 版本>-<套件修訂>；映像 tag
Containerfile              base codercom/code-server + Node 22 + pi + pi-acp + ACP extension
quadlet/
  code-server.container      容器定義、掛載與健康檢查（含 @@VAR@@ 標記）
  woow-code-server-pi.volume  內部 pi 狀態 volume
  woow-code-server-ide.volume 內部 IDE 使用者資料 volume
  render-vars                install.sh 可以代入的變數白名單
  optional/                  tailscale sidecar，用 --with-tailscale 才安裝
config/
  woow-code-server.env.example  每台主機的設定 -> ~/.config/woow-code-server/woow-code-server.env
  tailscale-serve.json.in       sidecar 的 serve 設定，安裝時以實際埠號渲染
rootfs/
  usr/local/bin/pi-code     ACP extension 呼叫的 HOME wrapper
  usr/local/bin/pi-seed     冪等的 pi 狀態初始化腳本（HA/k3s 共用同一份）
  etc/profile.d/pi.sh       讓 terminal 的 `pi` 指到同一個儲存位置
  etc/skel/…/settings.json  預設 VS Code 設定，把 ACP adapter 指到 pi-code
  opt/SHA256SUMS            上面三個共用檔案的雜湊值
systemd/
  code-server-health.{service,timer}   30s healthcheck 更新（用裸的 `podman`）
scripts/
  lib/quadlet-lib.sh        WOOWTECH 共用 Quadlet 函式庫（vendored，CI 檢查雜湊）
  install.sh                渲染 + 驗證 + 建置 + 安裝 + 只重啟有變更的單元
  upgrade.sh                快照 + 備份 + 安裝 + smoke，失敗自動回復
  uninstall.sh              停止 + 移除（沒有 --purge 就不刪資料）
  backup.sh / restore.sh    volume 匯出與匯入
  show-password.sh          從 podman secret 印出登入密碼
  migrate-pi-state.sh       從舊的共用 pi-agent-data volume 選擇性搬移
tests/
  dryrun.sh                 渲染單元並用 4.9.3 產生器檢查（含 dryrun.local.sh、fixtures/）
  smoke.sh                  podman 專屬檢查，再跑下面的 parity 套件
  lib/parity.sh             通用測試轉接器（PARITY_TARGET=podman|ha|k3s）
  smoke-container.sh        container up、/healthz 200、密碼閘
  smoke-pi-integration.sh   pi/pi-acp/pi-code 齊全、內部儲存已初始化
  smoke-acp.sh              extension 有裝、settings.json 必要 key 都對
  smoke-toolchain.sh        pip/venv、npm -g、git 身分、login shell 的 pi
docs/plans/                塑造本 package 的設計決策
.github/workflows/quadlet-ci.yml  vendored 函式庫雜湊 + dry-run + shellcheck
.github/workflows/build.yml       amd64 + arm64 image build，push/release 推到 ghcr
```

---

## 驗收部署

```bash
tests/smoke.sh            # podman 檢查 + 下面四支 parity 套件
tests/smoke.sh --quick    # podman 檢查 + smoke-container.sh（install.sh 跑的就是這個）
tests/dryrun.sh           # 不需要已部署：渲染單元並做靜態檢查
```

`tests/smoke.sh` 會先做只有 podman 部署能做的檢查——單元與健康檢查 timer 是 active、容器
healthy、`/healthz` 回 200、埠號**只**聽在設定的位址上、podman secret 裡的密碼可以登入、secret
確實掛進容器、容器環境變數與單元檔裡都沒有 `PASSWORD`——然後再跑四支通用套件：

```bash
PARITY_TARGET=podman tests/smoke-container.sh          # /healthz + 密碼閘
PARITY_TARGET=podman tests/smoke-pi-integration.sh     # pi + pi-acp + pi-code + 內部儲存
PARITY_TARGET=podman tests/smoke-acp.sh                # extension + settings.json
PARITY_TARGET=podman tests/smoke-toolchain.sh          # pip/venv、npm -g、git 身分、login shell 的 pi
```

全部要綠。`smoke-pi-integration.sh` 在你還沒 `pi login` 之前，`auth.json` 那條會 skip（不 fail）。

---

## 日常操作

```bash
podman ps --format '{{.Names}}\t{{.Status}}'      # 健康狀態
journalctl --user -u code-server -f               # systemd events
podman logs -f code-server                        # code-server output
podman exec -it code-server bash                  # 進 IDE 環境的 shell
systemctl --user restart code-server              # 重啟（pi + IDE 狀態都存在各自的 volume，不會丟）
```

想升 code-server 版：改 `Containerfile` 的 `ARG CODE_SERVER_VERSION=` **以及** `VERSION`
（單元的 `Image=` tag 也跟著），然後跑 `scripts/upgrade.sh`——它會備份、建置、重啟，smoke 測試
失敗就自動回復。`PI_CODING_AGENT_VERSION` / `PI_ACP_VERSION` / `ACP_CLIENT_VERSION` 同理，但
這三個版本要跟另外兩個 code-server 部署（HA add-on、k3s chart）**同步升**——動之前先看
`PARITY_CONTRACT.md` §2.1。

映像在本機建置、不推到任何 registry（`Pull=never`）。把有版號的映像發布到 GHCR 並讓單元改用它
是之後的工作；目前 `build.yml` 只產生 `main-<sha>` 映像，本部署並不使用。

---

## 安全

直說。

**密碼放在哪裡。** 一組隨機 24 字元密碼，存在 podman secret `code-server-config`，以唯讀方式
掛在 `/run/secrets/code-server-config.yaml`，由 code-server 透過 `$CODE_SERVER_CONFIG` 讀取。
它不在單元檔裡、不在 `systemctl --user cat` 裡、不在容器環境變數裡、也不在 `podman inspect`
裡——這在同時跑 podman MCP server 的主機上特別重要，否則它的 `inspect` 工具會把密碼交出去。
用 `scripts/show-password.sh` 印出來，用 `scripts/install.sh --rotate-password` 輪替。

**預設端點是 loopback。** `127.0.0.1:18443`：只有主機上的行程連得到，密碼也不會以純 HTTP 穿
過網路。支援的三種連入方式是 SSH port-forward（`ssh -L 18443:127.0.0.1:18443 <host>`）、選用的
tailscale sidecar，或同一台主機上終結 TLS 的 proxy（NPM / nginx / cloudflared）。把
`CODE_SERVER_BIND` 設成區網 IP 或 `0.0.0.0`，等於把純 HTTP 的密碼頁放到那個網路上（憑證每次
request 都以 base64 傳送），而且聊天 webview 仍然不會動：install.sh 會警告，這只有在受信任的
proxy 後面才是對的選擇。

**ACP 聊天 webview 需要瀏覽器信任的 HTTPS。** 側邊樹狀圖、狀態列、pi
adapter 連線在純 HTTP 下都正常。**聊天 webview 面板不行**——VS Code 的
webview 內容是透過 ServiceWorker 送達的，而 ServiceWorker 註冊要求
origin 是「安全」的（`localhost`，或是作業系統信任的憑證）。使用者在
頁面層級點「繼續前往」通過的自簽憑證，SW 那層還是會擋下來。這是目前
podman 這邊唯一跟 HA add-on、k3s chart **不對齊**的地方——後兩者都坐在
瀏覽器信任的來源後面（HA ingress；Cloudflare Tunnel 網域），聊天
webview 也都證實可以動。在 podman 這邊，讓聊天面板動起來的方式是：
- 選用的 tailscale sidecar（`scripts/install.sh --with-tailscale`）：帶
  瀏覽器信任憑證的 tailnet HTTPS 名稱，而且 loopback 以外什麼都不公開。
- 在這台主機上掛 NPM / nginx / Cloudflare Access，帶一張 Let's
  Encrypt（或同等作業系統信任）的憑證，並保持
  `CODE_SERVER_BIND=127.0.0.1`。
- 替代做法：在每台使用者機器上用 [`mkcert`](https://github.com/FiloSottile/mkcert)
  （跑一次 `mkcert -install`，再 `mkcert <host-ip>` 簽憑證），把
  code-server 指到那張憑證，瀏覽器就會在本機信任它、不會跳警告。
- 零基礎設施做法，也是預設做法：SSH port-forward 到主機
  （`ssh -L 18443:127.0.0.1:18443 <host>`），瀏覽
  `http://localhost:18443`——`localhost` 永遠是安全 context，完全不需要
  憑證就能讓 webview 動起來（PARITY_CONTRACT.md P31 已實測）。
- 不夠的做法：單獨開 `code-server --cert`。2026-08-30 的實機測試已經
  證實——頁面點過警告後能載入，但 webview 的 SW 在自簽憑證上還是拒絕
  註冊。

**如果你自己加了 reverse proxy，有一個通用陷阱要注意：** proxy 一定要
把瀏覽器實際使用的 `Host`/`Origin` 原封不動轉發過去，否則 code-server
會把 WebSocket upgrade 判 403。這個症狀看起來跟上面的 ServiceWorker /
secure-context 問題一模一樣，但其實是完全不同、不相關的成因——如果加了
proxy 之後側邊欄、terminal 整個死掉（即使憑證是對的），在
`quadlet/code-server.container` 加一行 `Exec=`，帶
`--trusted-origins <hostname>` 給 code-server，然後重跑
`scripts/install.sh`。

**容器能做什麼。** `code-server` 以 `coder` (uid 1000) 執行，rootless user
namespace 對應到主機你的 uid。

**容器內沒有任何提權途徑，`SUDO_PASSWORD` 也給不了。** quadlet 設了
`NoNewPrivileges=true`，不論密碼設成什麼，`sudo` 一律以
*"The 'no new privileges' flag is set, which prevents sudo from running as
root"* 失敗——已實測確認。舊版 README 寫的是相反的，而 Containerfile 也
據此叫你「缺什麼就 runtime `apt install`」；兩者都是錯的，而且這正是映像
當初沒裝 pip 的原因。要什麼工具就寫進 **Containerfile**。`install.sh` 不再
產生 `SUDO_PASSWORD`：一個什麼都換不到的憑證只是負債。真的需要容器內 root，
請自己把 quadlet 的 `NoNewPrivileges` 拿掉，並清楚知道代價。

**Bind mount。** workspace、SSH 目錄、gitconfig 與主機 bin 目錄都是從執行安裝的使用者掛進去
（容器內的 uid 1000 對應回那個使用者）。任何拿到 code-server shell 的都讀得到。`.ssh` 刻意
`:ro`——安全性不比執行本 script 的用戶差。每個路徑都是設定項，所以測試或共用主機可以把它們指
到暫時的目錄，而不是真正的 `~/.ssh`。提醒：在全新主機上這些來源可能還不能用——`install.sh`
會建立缺少的部分、設定 git 身分，並對其餘情況提出警告（沒有 SSH 私鑰、bin 目錄裡有失效
symlink）。

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
