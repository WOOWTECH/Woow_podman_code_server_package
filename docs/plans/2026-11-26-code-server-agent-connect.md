# Code-server Agent Connect Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 將現有 code-server Paseo 連接器升級為通用 Agent Connect，保留原擴充 ID、設定與已配對資料，並以 Paseo 官方版為基準，完成 Woowtech Smart、Apporo Smart 三站的真實驗收。

**Architecture:** 以 `Woow_podman_code_server_package` 為連接器與 VSIX 的唯一來源，透過既有同步工具供 HA Add-on、PaaS 與獨立 k3s 整合。先建立隔離 code-server 環境與測試主機身分，驗證新 runtime、來源驗證、生命週期及各客戶端的實際行為，再發布與同步經驗證的套件。既有正式實例的部署範圍依使用者指定目標處理。

**Tech Stack:** Node.js 22、Paseo CLI/server、VS Code workspace extension、Playwright、Python 3、code-server、Podman container packaging、Kubernetes/Helm、GitHub Actions/Gitea。

---

### Task 1: 固定來源與驗收基準

**Files:** 本檔；工作目錄外的 `research/runtime-audit.md`、`research/acceptance-audit.md`、`task.json`。

1. 記錄來源 main `a70b33d9b96c9d0d23832c4928d62eeed00fd0f7`、套件 `4.139.1-9`、擴充 `0.1.6`、Paseo runtime `0.11.2-r2`。
2. 讀取指定 session `3f89319b935f40fca3665fb9a394e65f` 與本機移交的實測程式；繼承測試方法，不繼承通過結論。
3. 查驗官方發行版與目前三站版本；辨識官方 0.17.5 相容 API 與現有 pi-paseo 實作可沿用的模組、補丁和授權。
4. 盤點 HA、PaaS、獨立 k3s 的實際來源與映像；僅以新建隔離環境進行初次部署。

### Task 2: 升級連接器 runtime

**Files:** 將新版來源 manifest 移至 `connectors/paseo/runtime-manifest/package.json`、`package-lock.json`，避免覆蓋仍在服務的舊版 `runtime/` manifest；`connectors/paseo/src/runtime.mjs`、`runtime-layout.mjs`、生命週期/身分/補丁模組；`connectors/paseo/install-runtime.sh`；`connectors/paseo/provenance.json`；`connectors/paseo/tests/`。

1. 先跑既有連接器測試並保存本次基線。
2. 對新版本實際 API 的差異補上有意義的契約、生命週期及遷移測試，再實作相容介面。
3. 固定完整 npm lock；保留安裝身分、設定、歷史及停止狀態，辨識舊 daemon 並要求安全升級，避免平行啟動或終止非本套件的程序。安裝器先驗證來源，於獨立 staging 建置並校驗後原子發布；已存在的健康 generation 只重用，絕不原地清除其 node_modules。
4. 保留共享技能、MCP、原生 provider 登入與原對話恢復；執行實際新 runtime 的隔離啟停、模型目錄、重連及重啟驗證。

### Task 3: Agent Connect 介面與三站配對

**Files:** `extensions/paseo/package.json`、`README.md`；`extensions/shared/extension.cjs`、`runtime.cjs`、`ui.cjs`；`extensions/tests/`；`CONNECTORS.md`。

1. 對既有 extension ID `woowtech.paseo`、command ID 及 `woow.paseo.*` 設定維持升級相容；顯示名稱、選單、頁首與說明改為 Agent Connect。
2. 提供 Paseo 官方、Woowtech Smart、Apporo Smart 明確的目標選擇，同時選定 relay、品牌握手與安全模式。保留既有設定值與自訂 URL 的普通開啟功能；私密配對只送到完整驗證的三個固定目標，不把舊 offer 改寫到另一站。
3. 配對只在明確操作時產生，驗證來源與目標再傳遞私密 offer；不寫入 webview、記錄、設定或公開驗收資料。
4. 測試取消、錯誤來源、無效 URL、通知非阻塞、缺 runtime、停用、移除與舊設定遷移。
5. 在真實 code-server 驗證擴充安裝與面板操作，以及寬窄視窗、明暗主題、鍵盤操作與可見錯誤。

### Task 4: 三站全面實測

**Files:** 新增 `qa/agent-connect/` 下的可重用驗收程式及矩陣；工作目錄外保存本次原始證據與去敏報告。

1. 為每站建立獨立瀏覽器 context，使用本次隔離 code-server 的主機身分；記錄實際 origin、客戶端版本、runtime 與來源 SHA。
2. 對照官方逐項執行：配對、工作區/專案、各可用 provider 登入與模型目錄、真實回覆、串流/停止/續聊/模型切換、工具/技能/MCP、檔案與下載、終端、斷線重連與重整。
3. 對官方版本支援且三站顯示的設定、權限提示、專案/工作區/對話生命週期與錯誤路徑納入矩陣；不把不適用、未執行或前次證據算作通過。
4. 在已驗證的舊版測試環境升級本次 VSIX/runtime，逐筆核對原有設定、身分、配對及測試對話保留；另測全新安裝。
5. 測試只建立與清理本輪資源；保留其他 session 的主機、帳號、檔案與對話。

### Task 5: 封裝、來源同步與交付

**Files:** `extensions/package.json`、VSIX build/package scripts；`VERSION` 與適用變更紀錄；`scripts/sync-connectors.py`；下游 `CONNECTORS_SOURCE.json` 與必要整合檔案。

1. 執行 `npm test --prefix extensions`、本次 runtime 行為測試、VSIX 封裝與 SHA256 校驗；確認 seed 不降版、不強制裝回已移除的擴充。
2. 分開檢查新建與升級映像；只在具體需要時修改 Chart，避免無關版號變動。
3. 準備 PR，依各 repo 真實規則執行 CI、覆核、發布與 GitHub/Gitea 同步；人工 gate 到具體成果可覆核時才提出。
4. 交付版本與部署矩陣、三站實測逐項結果、資料保留證據、回復方式與任何尚未完成的功能或帳號條件。
