# code-server Paseo／Omnigent 驗收紀錄（2026-11-10）

Podman 與 HA QA 已完成 **4 個 Web 組合、每個組合各 3 個代理**的真實對話、同一對話內切換模型、保留上下文及共用 skill／MCP 驗證。HA 的真實 Supervisor Ingress 代理路徑與插件 Verify 操作也已通過。PaaS 已完成服務連線、配對與部分換版持久化檢查，**模型供應商 OAuth 尚待使用者登入，PaaS 的模型對話驗收未完成**。

本紀錄適用於隔離 QA。相關變更仍在草稿審查流程，尚未正式發版或切換正式流量。最終映像版本、digest、三平台換版與開機總表由主線另行追加；以下每項結果保留其實際測試版本，不把單獨安裝新版 VSIX 視為完整映像換版驗收。

**如何安裝與開始使用。** 插件 ID 為 `woowtech.paseo`、`woowtech.omnigent`。在 code-server 的 **Extensions → Installed** 搜尋 `@installed woow`，應看到兩個獨立插件，可各自停用或移除。候選完整映像包含 backend、代理與預裝機制；單獨安裝 VSIX 只安裝介面，**不會安裝 Claude Code、Codex、Pi 或 connector backend，也不會替使用者登入模型帳號**。

目前 UI 修正版為 0.1.4。使用與目標部署匹配且經驗證的 VSIX，在 Extensions 的 `…` 選單選擇 **Install from VSIX…**。原始碼打包產物在 `extensions/dist/`；映像內的安裝來源在 `/opt/woow-connector-vsix/`。若該部署已提供 0.1.4 產物，也可執行：

```sh
code-server --install-extension /opt/woow-connector-vsix/woowtech.paseo-0.1.4.vsix
code-server --install-extension /opt/woow-connector-vsix/woowtech.omnigent-0.1.4.vsix
```

需使用受信任的工作區，以及部署管理者安裝的 backend；預設絕對路徑為 `/usr/local/bin/woow-connectors`。插件不接受儲存庫的 workspace settings 覆寫 backend 路徑。在 code-server 開啟 **Remote settings** 設定目前容器的工作區與主機名稱。只有 VSIX、backend 缺失時，介面會回報 runtime unavailable，不能據此宣稱代理已部署。產物建置及 backend 合約見 [extensions 說明](../../extensions/README.md)。

Paseo：開啟 **WOOW Paseo**，設定工作區、啟動服務，明確選擇配對後開啟 [官方 Paseo Web](https://app.paseo.sh/)，確認信任主機，再選工作區、代理及模型。Omnigent：開啟 **WOOW Omnigent**，設定容器可達的後端 URL；若使用者瀏覽器的入口不同，另設 Web URL，再登入該 Omnigent 服務並選擇此 host。Omnigent 服務帳號與模型供應商帳號是兩種登入；Paseo 配對也不會完成模型供應商登入。

模型登入須在各自部署的終端完成；不複製其他部署的憑證。Claude 使用 `claude auth login`，Codex 使用 `codex login --device-auth`，Pi 啟動後輸入 `/login`。本輪 PaaS 僅等待使用者授權，未替使用者啟動新 OAuth 流程。一般操作見 [CONNECTORS.md](../../CONNECTORS.md)。

**4 個 Web 組合的實際結果。** 測試均從真正的 Paseo Web 或 Omnigent Web 建立代理對話，核對新的助理訊息與後端實際模型，切換後再驗證先前上下文，最後執行共用工具證明並清理測試對話。僅有使用者提示文字、模型清單或 host 在線均不算通過。

| 環境與 Web | Claude Code | Codex | Pi Agent | 同一對話切換模型、上下文、共用工具 |
| --- | --- | --- | --- | --- |
| Podman QA／Paseo Web | PASS | PASS | PASS | PASS |
| HA QA／Paseo Web | PASS | PASS | PASS | PASS |
| Podman QA／Omnigent Web | PASS | PASS | PASS | PASS |
| HA QA／Omnigent Web | PASS | PASS | PASS | PASS |
| PaaS QA／Paseo Web | 待供應商登入 | 待供應商登入 | 待供應商登入 | 未執行 |
| PaaS QA／Omnigent Web | 待供應商登入 | 待供應商登入 | 待供應商登入 | 未執行 |

下表是當次目錄與 runtime 回報的模型 ID，非未來帳號可用模型的保證。各 Web 在 Podman 與 HA 使用相同的模型配對：

| Web | 代理 | 第一個模型 → 第二個模型 |
| --- | --- | --- |
| Paseo | Claude Code | `claude-sonnet-5-5` → `claude-opus-5-5` |
| Paseo | Codex | `gpt-6.1-sol` → `gpt-6-sol` |
| Paseo | Pi Agent | `openai-codex/gpt-6.1-sol` → `openai-codex/gpt-6-sol` |
| Omnigent | Claude Code | `haiku` → `sonnet`；實際解析為 `claude-haiku-4-5-20251001` → `claude-sonnet-5-5` |
| Omnigent | Codex | `gpt-6.1-sol` → `gpt-6-astra` |
| Omnigent | Pi Agent | `openai-codex/gpt-6.1-sol` → `openai-codex/gpt-6-astra` |

**模型切換的驗收範圍是同一代理、同一對話。** 第一輪放入測試識別內容，第二輪改用另一模型並確認仍能回憶該內容。改選 Claude、Codex 或 Pi 是切換代理引擎，可能建立另一個 session；本輪不宣稱不同代理引擎自動共享完整對話歷史。

共用配置位於同一部署的 `/data/pi-agent/skills` 與 `/data/pi-agent/shared/mcp.json`，修改 MCP 後由 `woow-agent-sync` 同步。驗收使用 `woow-connector-proof` skill 及 `woow_connector_proof` MCP：每個代理使用獨立 run label，核對工具端新產生的呼叫紀錄，並核對新助理訊息中的工具結果。HA 的三個 skill 路徑解析為相同檔案，檔案雜湊一致；共用 MCP registry 保留原有 8 個 server 並加入證明用 server。這證實同部署共用與實際工具調用，沒有逐一驗收原有全部 MCP 工具的功能或外部 OAuth。

Podman 的 Codex 公開時間線未完整暴露原生工具項目，因此另核對對應 native thread 的 skill 讀取及 MCP call/output。此處使用工具紀錄補足證據，沒有只依助理聲稱「已使用 skill」判定成功。Omnigent 的兩個 Web 驗收均使用非管理員服務帳號；成功測試 session 已停止並封存。

測試後固定版本為 Claude Code **2.1.285**、Codex **0.167.0**、Pi **0.99.1**。Paseo runtime 為 **0.11.2**，Omnigent host SDK 為 **0.16.0**。HA Paseo 初測因缺少 `procps` 及 root Claude launch flag 發現問題；Codex／Pi 在補齊 `procps` 後通過，Claude 在 r2 修補後單獨重測通過，失敗的初始對話也已封存。Claude updater guard 明確傳至 SDK 子程序，驗收後仍為固定版本。詳細順序見 [Paseo browser validation](../../connectors/paseo/browser-validation.json) 與 [Omnigent integration status](../../connectors/omnigent/integration-status.json)。

**真正的 HA Ingress 已通過，主要 add-on 未更動。** 本次路徑為：

```text
瀏覽器
  → Home Assistant／Supervisor 的已驗證 Ingress
  → 本次隔離 nginx proxy add-on
  → 既有 code-server QA 容器
```

proxy 為本次建立、手動啟動的 QA add-on；code-server QA 容器仍由既有 QA 流程管理。首次檢查中，未持有效 Ingress session 回應 401，合法 session 可開啟工作台；兩個插件卡片、Remote settings、webview 及即時 runtime 狀態共 8 項檢查通過。兩條 WebSocket 收到 435 個資料 frame，CSP／service worker 錯誤為 0。主要 add-on 公開狀態與容器指紋未變。此結果涵蓋真正 Supervisor Ingress 的代理路徑，沒有宣稱已完成主要 add-on 原地升級。

**HA 插件的 6 次 Verify 也有實際模型回覆。** 透過上述 Ingress，在兩個插件分別選 Claude、Codex、Pi，共 6 次 Verify，6 份 runtime receipt 均成功，未出現非預期 runtime 失敗。這是插件命令與 receipt 路徑的驗收；完整的雙模型、上下文與 skill／MCP 驗收另由前述 4 個 Web 組合提供。

這 6 次實際呼叫使用 VSIX **0.1.3**。當時 Omnigent 的 runtime 已有有效成功 receipt，介面仍可能顯示 `Conversation: incomplete`。**0.1.4**（來源 `3f36c24`）修正權威 `verified` 狀態的解讀，包含 `verified:false` 優先於舊 receipt 的情形，並修正 Paseo 模型清單依所選代理篩選。0.1.4 的 **28 項測試通過**，兩次打包可重現；在真正 Ingress 更新兩個插件後，**14 項 UI 檢查通過**，兩個面板正確顯示既有成功結果，三代理的模型選單均正確。模型選單測試以取消結束，沒有再送出 Verify 或新增模型呼叫。

**PaaS 的已完成事項與登入缺口。** 已建立並確認專用非管理員 Omnigent 服務帳號登入成功，使用既有 host kit 的 `deployment-managed` 模式。連線 receipt 記錄 host `489eaa5e…`、`connected:true`、`pauseSupported:true`、`modelCallsMade:0`；它是服務與 host 連線證據，不是供應商模型授權或對話成功證據。

PaaS 登入前檢查顯示 Claude 沒有 credentials 檔，Codex 沒有 auth 檔，Pi auth 檔為空；亦未發現檢查範圍內的 API 憑證環境變數。當時 Paseo 模型清單顯示 Claude 16 項、Codex 9 項、Pi 0 項，前兩者有清單仍不代表帳號已可使用。PaaS 的共用 proof skill／MCP fixture 當時也尚未配置；後續須在使用者登入完成後，補齊 fixture 並執行兩個 Web 的完整三代理、雙模型與工具證明。

PaaS qa4（backend 來源 `1b12841`）在新 Pod Ready 後，另做了不呼叫模型的 Paseo 持久化檢查：工作區、主機名稱與 port 設定和 qa3 相同；原本啟用的 daemon 自動恢復在線；直接重用 qa3 的私有配對連結，官方 Web 仍可開啟原工作區與新對話輸入框。沒有重新 configure、start、產生新配對連結或啟動 provider OAuth。本紀錄不包含私有配對內容。

**預裝 receipt 已改成各 IDE 擴充套件目錄獨立保存。** `fe33712` 修正後的位置為 `<實際 extensions 目錄>/.woow-connector-seed.json`，不再以共用代理資料目錄決定所有 IDE 是否安裝過插件。使用 PaaS 實際 code-server CLI **4.139.1**、VSIX **0.1.3**，在獨立暫存 HOME／XDG 與假代理資料下確認：

- A、B 兩個不同 extension store 共用同一假代理資料目錄，兩者各安裝兩個插件成功。
- 用 CLI 從 A 解除安裝 Paseo 後，reseed 保存解除安裝狀態；再次 reseed 仍不強制裝回，B 保留兩個插件。
- 刪除整個 A extension store 後，fresh seed 重新安裝兩個插件；B 不受影響。
- receipt 位於各自 extension store、權限為 0600；隱藏檔不影響 CLI `--list-extensions --show-versions`。
- 假代理資料未變，測試暫存目錄已清除；現用 extension store、代理設定與登入資料未變，模型呼叫為 0。

qa4 開機後再檢查實際目錄 `/home/coder/.local/share/code-server/extensions`，已存在上述 receipt，兩個插件均記錄並列出 **0.1.3**；已安裝 seed 原始碼 SHA-256 為 `3153009e1f50af39f7a5100a3601f08e3a8b17bbd1ce93d43e18169c64a85505`。這是 qa4 的開機快照；0.1.4 最終映像開機總表另由主線補入。

**證據索引。** 公開來源內可直接讀取 [Paseo validation](../../connectors/paseo/validation.json)、[Paseo Web 驗收](../../connectors/paseo/browser-validation.json)、[Omnigent integration status](../../connectors/omnigent/integration-status.json)。下列具體 receipt 保存在本輪私有 QA archive `connector-qa/`，由 reviewer 透過既有工作區讀取，沒有連同帳號、登入檔或配對連結提交到儲存庫：

| 驗收項目 | 私有 archive 內的 receipt |
| --- | --- |
| Podman／Paseo 三代理 Web | `paseo-web-podman-result.json` |
| HA／Paseo 三代理 Web 與重測順序 | `paseo-web-ha-result.json` |
| Podman／Omnigent 三代理 Web | `omnigent-podman-acceptance.json` |
| HA／Omnigent 三代理 Web | `omnigent-ha-acceptance.json` |
| HA 真正 Ingress 拓撲與主要服務未變 | `ha-ingress-isolated/completion-receipt.json` |
| HA 六次真實 Verify | `ha-ingress-isolated/ui-verification/six-valid-receipts-summary.json` |
| 0.1.4 測試、可重現打包與 14 項 UI 檢查 | `vsix-0.1.4/package-report.json`、`vsix-0.1.4/ha-ingress-browser-report.json` |
| PaaS managed host 已連線且無模型呼叫 | `omnigent-paas-connect.json` |
| PaaS provider 登入與 proof fixture 缺口 | `omnigent-paas-native-preflight.json`、`paseo-web-paas-preflight.json` |
| PaaS qa4 Paseo 設定、舊配對與開機 receipt | `paseo-web-paas-qa4-persistence.json` |
| 兩個獨立 extension store 的實際 CLI 行為 | `paseo-paas-seed-store-integration-fe33712.json` |

待完成項目為 PaaS 使用者供應商登入及完整模型／工具驗收、最終候選映像的換版開機總表、審查合併與正式發版。arm64 目前有依賴解析證據，沒有三代理 runtime 實機驗收；Open VSX 公開上架也未完成。現有 QA 存取使用既有私有轉送或受驗證的 HA Ingress，未在本紀錄宣告新的公開 QA IDE 網址。
