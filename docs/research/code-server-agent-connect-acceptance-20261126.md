# code-server Agent Connect 升級與驗收紀錄

**WIP：尚未完成全面驗收、發布正式版本或更新既有租戶。**

候選套件 `4.139.1-10` 保留 code-server 核心 `4.139.1`；擴充為 `0.2.0`。
原有 ID `woowtech.paseo`、指令與設定鍵繼續沿用，顯示名稱改為 Agent Connect。

## 本次升級

- Paseo CLI、server、client、protocol 從 `0.11.2` 升為固定 npm lock 的 `0.17.5`，
  code-server SDK generation 為 `0.17.5-r3-8664f2c3f8f5`，包含 HA root 模式的 Claude 相容處理。
- 三個設定檔同時選定網站、relay、主機品牌與 CORS。設定尚未套用時拒絕配對，
  offer 必須完整符合所選目標，不會將配對連結改寫到另一站。
- 安裝來源移至 `runtime-manifest/`，保留舊版 runtime 的控制能力。
  新版先在 staging 完成 npm、補丁與收據校驗，再原子發布；健康重跑不改寫 generation。
- 保留 code-server 的資料與 provider home 路徑、程序歸屬檢查與手動停止狀態。
  原對話的共享 MCP 更新保留原生 session；忙碌、等待權限及不確定 writer 是否關閉時拒絕更新。
  一般 Web 重新載入維持官方行為。

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

已執行 VSIX 正常升級、實際 npm 安裝、20,641 項 generation metadata 不變的健康重用、
併發啟動、健康恢復不改寫狀態、停止後不自動啟動，以及舊版升級的穩定身分雜湊核對。
上游每次啟動會重新產生短期 `local-credential`；它與應保持相同的配對金鑰分開檢查。

獨立的舊版遷移測試也已通過：同一瀏覽器 context 從 0.11.2 升到本次 R3，
沒有產生第二個 offer 或重新配對；server ID、金鑰與工作區 ID 保持相同，
網站能讀到升級後才在伺服器寫入的新內容。該輪測試 daemon 與 UUID fixtures 已清理。

| 案例 | Paseo | Woowtech | Apporo |
|---|---|---|---|
| 明確新配對、正確 origin／relay／TLS | 初輪通過 | 初輪通過 | 初輪通過 |
| 工作區讀取 | 初輪通過 | 初輪通過 | 初輪通過 |
| 文字、ZIP、二進位檔真實下載及 SHA256 | 初輪通過 | 初輪通過 | 初輪通過 |
| 瀏覽器重整保留連線 | 初輪通過 | 初輪通過 | 初輪通過 |
| 未配對 context 無法讀取測試檔 | 初輪通過 | 初輪通過 | 初輪通過 |
| 編輯、儲存、刪除及終端完整流程 | 待完成 | 待完成 | 待完成 |
| daemon 重啟後讀取新伺服器資料 | 待完成 | 待完成 | 待完成 |
| 三個 provider 的真實對話及模型切換 | 等待測試帳號 | 等待測試帳號 | 等待測試帳號 |
| 技能與 MCP 真實工具呼叫 | 等待測試帳號 | 等待測試帳號 | 等待測試帳號 |

原生面板已通過啟用、三站選擇、鍵盤操作、214px 面板無水平溢出、44px 控制項，
以及實際 VS Code 明／暗主題。設定套用、完整生命週期及舊配對重連另列結果；
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
