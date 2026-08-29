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
extension 且**預設接線好**——開側邊 ACP 樹、點 `pi`，右側面板直接跟 pi 對談，
provider/skills/sessions 沿用姊妹套件 [`Woow_podman_pi_agent_package`](https://github.com/WOOWTECH/Woow_podman_pi_agent_package) 的既有設定。

---

## 提供什麼

| | |
|---|---|
| **UI** | `http://<host>:8443` — 密碼保護、只給區網 |
| **IDE** | code-server 4.135.0，extension 走 OpenVSX |
| **Agent** | pi 0.83.0，右側 ACP chat panel 直接可用；terminal PATH 上也有 `pi` |
| **Workspace** | 主機 `~/Desktop` bind-mount 到 `/workspace`——你在編輯器改的檔案主機直接看得到，也還是你的擁有者 |
| **持久化** | Sessions、skills、providers 存在共用的 `pi-agent-data` podman volume；container 重建、重開機都不丟（見安全提醒） |
| **監管** | `systemd --user` via Quadlet，30 秒健康檢查 |

---

## pi 接線的原理 —— 30 秒版

VS Code 裡的 ACP Client extension 執行 `acp.agents.<name>.command` 定義的指令。
本 image 出貨 `/usr/local/bin/pi-code` 作為那個指令，它只做一件事：
把 `HOME` 重定向到 `/data/pi-agent/home`（volume 掛的地方）、然後 `exec pi-acp`，
pi-acp 再 spawn `pi --mode rpc` 走 stdio。

```
VS Code（瀏覽器）→ ACP extension → pi-code → pi-acp → pi --mode rpc
                                    │
                                    └─ export HOME=/data/pi-agent/home
```

`HOME` 覆寫**只發生在 wrapper 裡**（不會動到 code-server 容器層的 HOME），
所以 IDE 自己的狀態原封不動，只有 pi 子行程看得到共用 volume。這跟
[OD 的 `pi-od` wrapper](https://github.com/WOOWTECH/Woow_podman_opendesign/blob/main/pi-od)
在 `.197` 上的 pattern 完全一致。

完整決策紀錄在 `docs/plans/2026-08-30-initial-package.md`。

---

## 安裝

需 Podman ≥ 4.4（Quadlet）、rootless、以擁有 podman storage 的帳號執行。
**建議先裝** [`Woow_podman_pi_agent_package`](https://github.com/WOOWTECH/Woow_podman_pi_agent_package)
——它會建 `pi-agent-data` volume 並塞入 provider/skills/sessions。若你不裝，
本 repo 會自動建一個空的，pi 就沒有 provider，你需要 `pi login`。

```bash
git clone https://github.com/WOOWTECH/Woow_podman_code_server_package.git
cd Woow_podman_code_server_package

./scripts/install.sh
```

`install.sh` 做什麼：
1. 檢查 podman + Quadlet
2. `loginctl enable-linger`（登出後仍運行）
3. `podman build` → `localhost/woow-code-server:latest`
4. 把 `quadlet/code-server.container` 放進 `~/.config/containers/systemd/`
5. `systemctl --user daemon-reload && start code-server && enable --now code-server-health.timer`
6. 等 `/healthz` 回 200

想跳過 image 重建：`OD_SKIP_BUILD=1 ./scripts/install.sh`。

### 首次登入

開 `http://<host>:8443`、輸密碼。預設 `woowtech`——**請改**（見[安全](#安全)）。

ACP Client extension 已預裝、pi adapter 已設好。底部狀態列會顯示
`ACP: pi ACP adapter`（綠燈）、右側面板就是 chat。

### 移除

```bash
./scripts/uninstall.sh
```

停 + 移 container 與 units。**不會**動 `pi-agent-data` volume（那顆屬於
姊妹 pi-agent-package）。

---

## 目錄結構

```
Containerfile              base codercom/code-server + Node 22 + pi + pi-acp + ACP extension
quadlet/
  code-server.container    podman 容器定義 + 掛載 + env
rootfs/
  usr/local/bin/pi-code    ACP extension 呼叫的 HOME wrapper
  etc/skel/…/settings.json 預設 VS Code 設定，把 ACP adapter 指到 pi-code
systemd/
  code-server-health.{service,timer}   30s healthcheck 更新
scripts/
  install.sh               build + install + start + wait /healthz
  uninstall.sh             stop + remove（保留 pi-agent-data）
tests/
  smoke-container.sh       container up、/healthz 200、錯誤密碼擋掉
  smoke-pi-integration.sh  pi/pi-acp/pi-code 齊全、/data/pi-agent 有掛
  smoke-acp.sh             extension 有裝、settings.json 對到 pi-code
docs/plans/                塑造本 package 的設計決策
.github/workflows/build.yml    amd64 + arm64 CI，push/release 推到 ghcr
```

---

## 驗收部署

```bash
# 便宜測試套 — 零 LLM 呼叫、零成本，跑在主機上。
bash tests/smoke-container.sh          # /healthz + 密碼閘
bash tests/smoke-pi-integration.sh     # pi + pi-acp + pi-code + 共用 volume
bash tests/smoke-acp.sh                # extension + settings.json
```

三支要全綠。`smoke-pi-integration.sh` 檢查「姊妹套件的檔案」那幾條若空 volume
會 skip（不 fail）。

---

## 日常操作

```bash
podman ps --format '{{.Names}}\t{{.Status}}'      # 健康狀態
journalctl --user -u code-server -f               # systemd events
podman logs -f code-server                        # code-server output
podman exec -it code-server bash                  # 進 IDE 環境的 shell
systemctl --user restart code-server              # 重啟（狀態存 volume、不會丟）
```

想升 code-server 版：改 `Containerfile` 的 `ARG CODE_SERVER_VERSION=`、跑 `./scripts/install.sh`
（會觸發重 build）、`systemctl --user restart code-server`。pi 版跟 pi-acp 版同理，但
**pi 版必須跟姊妹 pi-agent-package 同步升**，兩邊 schema 才不會漂移。

---

## 安全

直說。

**刻意的短路。** 預設 `PASSWORD=woowtech` 在公司區網、防火牆後面是可以接受的。
超出這條就**不行**——密碼走 HTTP 是每 request 都 base64 傳。要對外開放的話：
- 前面掛一層有 auth 的 reverse proxy（nginx / NPM / Cloudflare Access）+ TLS，
  同時把 `Environment=PASSWORD=` 改強
- 或把 `PublishPort=` 改成 `127.0.0.1:8443:8080`，強迫走 reverse proxy

**容器能做什麼。** `code-server` 以 `coder` (uid 1000) 執行，rootless user namespace
對應到主機你的 uid。容器內 `sudo` 用 `SUDO_PASSWORD` 開啟（預設也是 `woowtech`）
——不想讓用戶 runtime apt-install 東西就把 quadlet 內的 env 拿掉。

**Bind mount。** `~/Desktop`、`~/.ssh`、`~/.gitconfig`、`~/.local/bin` 都是從
你主機的 uid 1000 掛進去。任何拿到 code-server shell 的都讀得到。`.ssh` 刻意
`:ro`——安全性不比執行本 script 的用戶差。

**pi 的 provider keys。** 在共用 volume 的 `/data/pi-agent/models.json` 內（mode 600）。
`code-server` (uid 1000) 是 owner、讀得到——這正是 ACP panel「不用設定 provider 就
能用」的原因。任何拿到本 container shell 的人也讀得到。要輪替 key 就進 pi 的
Models UI；不要把 key commit 進 workspace 的 repo。

---

## 姊妹套件

- [`Woow_podman_pi_agent_package`](https://github.com/WOOWTECH/Woow_podman_pi_agent_package) — pi-web 姊妹；兩容器共用 `pi-agent-data` volume
- [`Woow_podman_opendesign`](https://github.com/WOOWTECH/Woow_podman_opendesign) — OpenDesign 版本，同樣 volume 共用 pattern
- [ACP Client (formulahendry)](https://open-vsx.org/extension/formulahendry/acp-client) — 右側 agent chat panel 的 VS Code extension
- [pi-acp](https://www.npmjs.com/package/pi-acp) — 社群做的 ACP JSON-RPC → pi `--mode rpc` bridge

## 授權

MIT
