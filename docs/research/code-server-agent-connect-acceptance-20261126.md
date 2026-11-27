# code-server Agent Connect 升級與驗收紀錄

**WIP：尚未完成全面驗收、發布正式版本或更新既有租戶。**

**R3 候選已撤回核可，R4 已完成本機驗證，等待成品重建與重驗。** HA 成品比較掃描發現
esbuild 內嵌舊 Go binary 新增 19 項漏洞（1 Critical、18 High）。R4 固定 esbuild `0.28.2`
與 Go `1.26.5` binary，實際 SDK 編譯相容性及 360 項 runtime／49 項擴充測試通過。
下文 R3 成品結果是升級對照，不能列為 R4 或正式發布的通過證據。
[R3 比對結果](https://github.com/WOOWTECH/Woow_ha_code_server_add_on/actions/runs/45913001509/job/140230408318)、
[已關閉的 R3 核可單](https://git-prod.woowtech.io/woow-paas/paas-odoo-ci/issues/806)。

候選套件 `4.139.1-10` 保留 code-server 核心 `4.139.1`；擴充為 `0.2.0`。
原有 ID `woowtech.paseo`、指令與設定鍵繼續沿用，顯示名稱改為 Agent Connect。

## 本次升級

- Paseo CLI、server、client、protocol 從 `0.11.2` 升為固定 npm lock 的 `0.17.5`，
  目前 code-server SDK generation 為 `0.17.5-r4-2b20ef5fac0a`，包含 HA root 模式的 Claude 相容處理。
- 三個設定檔同時選定網站、relay、主機品牌與 CORS。設定尚未套用時拒絕配對，
  offer 必須完整符合所選目標，不會將配對連結改寫到另一站。
- 安裝來源移至 `runtime-manifest/`，保留舊版 runtime 的控制能力。
  新版先在 staging 完成 npm、補丁與收據校驗，再原子發布；健康重跑不改寫 generation。
- 保留 code-server 的資料與 provider home 路徑、程序歸屬檢查與手動停止狀態。
  原對話的共享 MCP 更新保留原生 session；忙碌、等待權限及不確定 writer 是否關閉時拒絕更新。
  一般 Web 重新載入維持官方行為。
- R4 另外核對 amd64／arm64 的 compiler archive integrity、JS loader 與兩個 binary 路徑的
  實際 SHA256。R3 的 46 個檔案與五組補丁收據固定保留為控制用途，安裝 R4 不覆寫它。
- 內建瀏覽器驗收工具可明確選三站，沿用所選目標的原始 offer；支援官方 0.17.5 與
  Smart 0.17.4 的兩種既有工作區開啟流程。三站實際配對／開啟目錄及未配對隔離皆已通過，
  該輪使用 R3 對照主機，沒有模型呼叫。

## 正式網站基準

| 目標 | 正式網站 | 本輪版本 | Relay | 安全政策 |
|---|---|---|---|---|
| Paseo 官方，行為基準 | https://app.paseo.sh | 0.17.5 | relay.paseo.sh:443 | protected |
| Woowtech Smart | https://smart.woowtech.io | 0.17.4 | relay.woowtech.io:443 | 既有 Smart 客戶端相容 |
| Apporo Smart | https://smart.apporo.ai | 0.17.4 | relay.apporo.ai:443 | 既有 Smart 客戶端相容 |

每站使用全新瀏覽器 context；沒有把其他 session 的 preview 或歷史測試算作本次通過。

## 本輪證據範圍

隔離測試使用獨立 namespace、資料卷、密碼、工作區與瀏覽器。
初次升級在舊 PaaS 映像上掛載本次來源，驗證相同路徑的 runtime 準備及切換。
**來源 overlay 測試不等於新建成品映像驗收，也不代表所有 HA、Podman、PaaS、k3s
正式部署已更新。** 各成品仍需自己的建置、新安裝及升級證據。

接續已完成獨立成品測試：amd64 候選映像使用全新資料卷，沒有掛載來源或
`/opt/woow-connectors` overlay，三個正式網站的相同 47 項流程全部通過。
實際映像與執行中的 managed／state／process generation 都有核對。
這證明本次 Podman 成品在隔離 k3s 測試環境的行為；HA 與 PaaS 衍生成品另列驗證。

- 成品建置來源：`537d542efba8416f8d226ba887ac9c2662eb119e`。
- amd64 digest：`sha256:00d75fa221793f18b76d0882db6af34c75cdfad6da9dd7795d10fd197ae98bc0`。
- arm64 已完成建置與公開 manifest 核對；目前沒有 arm64 節點，尚未執行原生硬體驗收。
- [候選建置](https://github.com/WOOWTECH/Woow_podman_code_server_package/actions/runs/45911036930)、
  [逐項去敏證據](code-server-agent-connect-evidence-20261126.json)。

已執行 VSIX 正常升級、實際 npm 安裝、R2 的 20,641 項 generation metadata 不變健康重用、
併發啟動、健康恢復不改寫狀態、停止後不自動啟動，以及舊版升級的穩定身分雜湊核對。
上游每次啟動會重新產生短期 `local-credential`；它與應保持相同的配對金鑰分開檢查。

獨立的舊版遷移測試也已通過：同一瀏覽器 context 從 0.11.2 升到本次 R3，
沒有產生第二個 offer 或重新配對；server ID、金鑰與工作區 ID 保持相同，
網站能讀到升級後才在伺服器寫入的新內容。該輪測試 daemon 與 UUID fixtures 已清理。

另已實際將來源 overlay 的 R3 測試容器換為上述成品映像，移除 overlay，保留同一組
PVC、配對身分、既有工作區、VSIX 內容及 IDE／Agent Connect 設定。
容器重建後背景服務自行恢復，同一瀏覽器讀到重建後的新內容；再明確 Stop 並第二次
重建，觀察超過 35 秒仍保持停止，最後明確 Start 後原瀏覽器再次讀到新內容。
這輪沒有第二次配對，且本輪 marker 已清理。它與前述 0.11.2 SDK 遷移是兩項獨立測試。

| 案例 | Paseo | Woowtech | Apporo |
|---|---|---|---|
| 明確新配對、正確 origin／relay／TLS | 通過 | 通過 | 通過 |
| 工作區讀取 | 通過 | 通過 | 通過 |
| 文字、ZIP、二進位檔真實下載及 SHA256 | 通過 | 通過 | 通過 |
| 瀏覽器重整保留連線 | 通過 | 通過 | 通過 |
| 未配對 context 無法讀取測試檔 | 通過 | 通過 | 通過 |
| 編輯、儲存、刪除及終端完整流程 | 通過 | 通過 | 通過 |
| daemon 重啟後讀取新伺服器資料 | 通過 | 通過 | 通過 |
| 三個 provider 的真實對話及模型切換 | 等待測試帳號 | 等待測試帳號 | 等待測試帳號 |
| 技能與 MCP 真實工具呼叫 | 等待測試帳號 | 等待測試帳號 | 等待測試帳號 |

上述來源 overlay 流程合計 47 項：Paseo 15、Woowtech 16、Apporo 16。
各站分別核對 managed、state 與實際 daemon process 的 R3 generation。
全新成品的三站流程另執行 47 項；兩輪使用不同的資料卷與瀏覽器 context。
另有 314 項 runtime／安裝器／SDK／CLI／seed 測試與 49 項擴充測試通過，均無跳過。
這是 R3 對照的數量；R4 的目前結果為 360 項 runtime／安裝器／SDK／CLI／seed 與
49 項擴充，均無跳過，另已核對實際 R3 原檔及 R4 健康安裝重用不改寫檔案。

R4 compiler 相容檢查使用實際 SDK plugin compiler 與 OpenCode bridge 編譯函式。
也發現 SDK 既有 server plugin entrypoint 限制：`export default function setup(){...}`
可由正式 loader 載入，default arrow 或先宣告 `const` 再 default export 則失敗；
R3、R4 結果一致。本次沒有改寫該 SDK compiler／loader，不能將這些形式列為已支援。

原生面板已通過啟用、三站選擇、鍵盤操作、214px 面板無水平溢出、44px 控制項，
以及實際 VS Code 明／暗主題；成品映像上的五項介面與八項原生操作也均通過。
原生操作涵蓋保存設定、待套用警示、拒絕未套用配對、Stop／Start、明確新配對與實際檔案讀取。
首次操作測試混淆建置產物的 root 擁有者與執行程序的 coder 身分，已修正測試假設並保留失敗紀錄，
沒有為此修改產品。只讀模型目錄取得 Claude 16、Codex 9、Pi 0 筆，尚未驗證認證。

[一般面板截圖](code-server-agent-connect-wide-20261126.png)／
[214px 面板截圖](code-server-agent-connect-narrow-20261126.png)。
設定套用、完整生命週期及舊配對重連分別保留紀錄；
已保存的主機名稱不能當作連線成功證據。模型目錄也不等於模型已登入或已回覆。

## 同事實測流程

1. 使用相符 runtime 的候選 code-server，確認 Extensions 顯示 **Agent Connect**，
   ID 為 `woowtech.paseo`。單獨安裝 VSIX 不會替舊映像安裝新版 SDK。
2. 開啟面板，填入容器內工作區路徑、主機名稱及 Web app，按 **Save configuration**。
   如設定待套用，等對話閒置後按 **Stop**、再按 **Start**。
3. 確認 Selected target 與 Active target 相同，再按 **Pair with selected Web app**，
   在對應網站確認 **Connect**。不要將配對 URL 貼入聊天、設定或問題回報。
4. 測試工作區、檔案讀寫與下載、終端、網站重整與 daemon 重啟。
   重連後讀取重啟後才產生的新內容，不能只看舊主機名稱。
5. 分別登入測試部署的 Claude、Codex、Pi，從即時目錄選模型。
   測試新回覆、串流、停止、續聊、同一對話切換第二個模型及技能／MCP 呼叫。
   每個 provider、模型、網站各自記錄；登入與額度錯誤保持失敗狀態。
6. 換網站時重做完整設定及配對，使用新 context，不改寫其他網站的 offer。
7. 僅清理本輪建立的檔案、終端及對話。關閉面板會保留背景連線；需關閉時明確停止。

回報包含候選映像 digest、套件／擴充版本、實際網站版本、案例 ID、預期與實際結果，
以及去敏截圖。不要附密碼、token、配對 URL、瀏覽器 storage 或原始 provider 診斷。

## 帳號就緒後的模型驗收表

以下案例需在 Paseo 基準站先執行，再以 Woowtech、Apporo 對照。每個網站的 Claude、
Codex、Pi 各自填一份結果；即時模型目錄可讀取不代表帳號可用。

| 案例 ID | 操作 | 通過依據 |
|---|---|---|
| MODEL-01 | 選目前可用模型，開新對話要求回覆本輪隨機字串 | 正確 provider／模型、串流事件及完成回覆 |
| MODEL-02 | 要求較長回覆，串流期間按停止 | 回覆停止，狀態回到可輸入，可接續提問 |
| MODEL-03 | 記住另一個隨機字串，重整網站後要求取回 | 原對話內容保留，可讀取新回覆 |
| MODEL-04 | 同一對話改用第二個可用模型，再追問前文 | 原生對話 ID 保持、模型確實切換、前文可續接 |
| TOOL-01 | 使用只讀工具讀取本輪工作區 fixture | 真實工具事件及 fixture 的實際內容一致 |
| TOOL-02 | 呼叫明確指定的測試技能及 MCP 只讀工具 | 可辨認工具／技能來源，沒有拿文字模擬工具成功 |
| MCP-01 | 閒置時更新共享 MCP，再於同一對話呼叫新增工具 | 原生對話 ID 保持，新工具實際可用 |
| MCP-02 | 回覆忙碌或等待權限時嘗試更新 MCP | 拒絕不安全更新，原對話仍可完成或停止 |
| AUTH-01 | 使用未登入或額度不足的測試狀態 | 顯示可理解的錯誤，不回報模型驗收成功 |

目前以上案例均為 **等待指定測試帳號**，尚未呼叫模型或登入 provider。
如某個 provider 沒有第二個可用模型，MODEL-04 記錄為未驗收並保留原因。
