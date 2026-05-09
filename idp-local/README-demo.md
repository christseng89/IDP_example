# demo.sh 功能說明

此腳本是一份**互動式、逐步引導的展示流程**,設計用於向利害關係人(stakeholders)現場示範 IDP 平台的完整能力。每個步驟執行後會暫停,等待操作者按下 Enter 繼續,方便搭配口頭說明。

`demo.sh` 不重複實作平台安裝邏輯,而是**委派給 `install.sh`** 處理底層複雜性(映像預拉、Helm repo 快取、state 修補、Phase 1/2 序列化建立、retry 機制等)。展示腳本本身只專注於「使用者視角」的步驟。

## 執行方式

```bash
# 標準執行(Linux / macOS)
bash scripts/demo.sh

# Windows 11 + Docker Desktop(port 80 被 com.docker.backend 佔用)
HTTP_PORT=9080 bash scripts/demo.sh
```

## ⚠️ 執行前置作業

### 1. Backstage 主機名稱解析(**強烈建議**)

Backstage 採用官方映像,前端 publicPath 寫死為 `/`,只能掛載於獨立 hostname `backstage.localhost`。

依 RFC 6761,`*.localhost` 應自動解析為 `127.0.0.1`,但部分企業 DNS 會回傳 NXDOMAIN。請於展示前先設定 hosts 檔案(需系統管理員權限):

**Windows(PowerShell as Administrator)**

```powershell
Add-Content -Path "$env:WINDIR\System32\drivers\etc\hosts" -Value "127.0.0.1 backstage.localhost"
ipconfig /flushdns
```

**Linux / macOS**

```bash
echo "127.0.0.1 backstage.localhost" | sudo tee -a /etc/hosts
```

驗證(注意 `nslookup` 不讀 hosts):

```bash
ping backstage.localhost   # 應顯示 [127.0.0.1]
```

詳細說明請參考 [README-install.md](README-install.md) 的「⚠️ 安裝前置作業」段落。

### 2. kubectl-argo-rollouts 外掛(選用,推薦)

未安裝時,Steps 6/8/9/10 會自動改以 Argo Rollouts dashboard UI 操作。但若已安裝,可在 terminal 中使用 `kubectl argo rollouts ...` 系列指令。安裝方式:

```bash
# Linux / macOS
curl -LO https://github.com/argoproj/argo-rollouts/releases/download/v1.7.2/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64
sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts

# Windows
curl -LO https://github.com/argoproj/argo-rollouts/releases/download/v1.7.2/kubectl-argo-rollouts-windows-amd64.exe
mkdir -p ~/bin && mv kubectl-argo-rollouts-windows-amd64.exe ~/bin/kubectl-argo-rollouts.exe
# 確保 ~/bin 在 PATH 中
```

## 環境變數

| 變數 | 預設值 | 說明 |
|---|---|---|
| `HTTP_PORT` | `80` | nginx-ingress LoadBalancer HTTP port;Windows + Docker Desktop 環境通常需設為 `9080` |
| `HTTPS_PORT` | `443` | nginx-ingress LoadBalancer HTTPS port |

`demo.sh` 會將這兩個變數透傳至 `install.sh`,確保整個 demo 流程的端點 URL 一致。

## 11 個展示步驟

### 步驟 0 — 先決條件檢查

驗證五項基礎能力是否就緒:

| 工具 / 條件 | 失敗行為 |
|---|---|
| `docker info` 可執行(daemon 運作中) | 立即中止 |
| `kubectl cluster-info --context docker-desktop` 可連線 | 立即中止 |
| `terraform version` 可執行 | 立即中止 |
| `helm version` 可執行 | 立即中止 |
| `kubectl argo rollouts version` 可執行 | **僅警告**,流程繼續(後續 Rollout 操作改走 dashboard UI) |
| `backstage.localhost` 可由 hosts 解析 | **僅警告**,流程繼續(Step 5 Backstage 導覽會無法存取) |

### 步驟 1 — 建構服務映像

呼叫 `scripts/build-images.sh`,建構 `svc-alpha` 與 `svc-beta` 各自的 v1、v2 共四個本地 Docker 映像:

- `svc-alpha:v1` / `svc-alpha:v2`
- `svc-beta:v1` / `svc-beta:v2`

### 步驟 2 — 單指令啟動完整 IDP 平台

委派給 `install.sh` 執行,後者依序處理:

1. 透過映像鏡像站(DaoCloud)預拉所有平台映像並 retag
2. Helm repo 同步(含 jsdelivr CDN 備援)
3. ArgoCD 本地 git repo 初始化
4. Terraform state 正規化(處理 provider 版本鎖死、NUL byte 損毀)
5. Phase 1(kubernetes_* 資源序列化建立)+ Phase 2(helm_release、kubectl_manifest)
6. 最多 5 次 retry(規避 Windows kubernetes provider plugin 崩潰)

部署元件:**NGINX Ingress · Kyverno · Crossplane · Prometheus + Grafana · Argo CD · Argo Rollouts · Backstage(含 Postgres backing store)**

> **預估時間:** 首次執行 10–20 分鐘(取決於映像下載速度);後續 re-run 約 3 分鐘。


### 步驟 3 — 等待平台就緒

分兩類等待:

- **一般 namespace**(`ingress-nginx`、`kyverno`、`crossplane-system`、`monitoring`、`argocd`、`argo-rollouts`、`backstage`)— 使用 `kubectl wait --for=condition=available deployment`,逾時 300 秒
- **服務 namespace**(`svc-alpha`、`svc-beta`)— 已安裝 plugin 時用 `kubectl argo rollouts status`;否則退回至 `kubectl wait pod --for=condition=Ready`

### 步驟 4 — 列印平台端點

URL 由 `BASE_URL` 與 `BACKSTAGE_URL` 動態組成,自動配合 `HTTP_PORT`:

| 服務 | URL(`HTTP_PORT=9080` 範例) | 認證 |
|---|---|---|
| **Backstage Portal** | **`http://backstage.localhost:9080`** ⚠️ | Guest sign-in |
| Argo CD | `http://localhost:9080/argocd` | admin / `<terraform output -raw argocd_admin_password>` |
| Argo Rollouts UI | `http://localhost:9080/rollouts/svc-alpha`(namespace 在路徑中) | — |
| Grafana | `http://localhost:9080/grafana` | admin / idp-demo |
| svc-alpha v1 | `http://localhost:9080/svc-alpha/v1/hello` | — |
| svc-alpha v2 | `http://localhost:9080/svc-alpha/v2/hello` | — |
| svc-beta v1 | `http://localhost:9080/svc-beta/v1/hello` | — |
| svc-beta v2 | `http://localhost:9080/svc-beta/v2/hello` | — |

> ⚠️ **Backstage 使用獨立 hostname**,請確認已完成執行前置作業 1。

### 步驟 5 — Backstage 功能導覽

引導展示者依序瀏覽 Backstage 功能(開啟瀏覽器至 `${BACKSTAGE_URL}`):

1. **Sign in as Guest** — 訪客登入(無 IdP 設定,純 demo 用)
2. **Catalog** — 查看 svc-alpha、svc-beta 元件列表
3. **Overview 頁籤** — 元件 metadata 與 relations
4. **Kubernetes 頁籤** — 即時 Pod 狀態與 Rollout 進度(透過 in-cluster ServiceAccount 授權,不需手動配置 token)
5. **API 頁籤** — OpenAPI 規格,v1(已棄用)vs v2 對比
6. **Docs 頁籤** — 由 `docs/index.md` 渲染的 TechDocs
7. **Relations** — svc-alpha → svc-beta 的依賴關係圖
8. **Create → New IDP Service** — 黃金路徑(golden path)scaffolder 範本

### 步驟 6 — 觸發 Canary 漸進式部署(v1 → v2)

兩階段操作:

1. **修改 chart values:** `sed -i 's/^  tag: v1$/  tag: v2/' charts/svc-alpha/values.yaml`
2. **提交至本地 git:** ArgoCD repo-server 透過 `file:///idp-local` 讀取 chart,必須 commit 才會被 ArgoCD 看到
3. **強制 ArgoCD refresh + sync:**
   ```bash
   kubectl annotate app svc-alpha -n argocd argocd.argoproj.io/refresh=normal --overwrite
   kubectl patch app svc-alpha -n argocd --type merge -p '{"operation":{"sync":...}}'
   ```
4. **背景監控:** 啟動 `kubectl argo rollouts get rollout svc-alpha --watch`(plugin 已安裝)或 `kubectl get rollout -w`(plugin 未安裝)

> **為何不用 `helm upgrade`?** Argo CD 開啟 `selfHeal: true`,任何不經 ArgoCD 的變更會在 3 分鐘內被回滾。透過 values.yaml + git commit + ArgoCD sync 才是「持久」的部署路徑。

### 步驟 7 — 在 20% 流量時暫停檢視

Rollout 進入第一階段 `setWeight: 20`,進入 `pause: {}`。引導觀眾:

- 在 Grafana「IDP Services」儀表板確認約 20% 流量導向 v2
- 在 Argo Rollouts UI(`${BASE_URL}/rollouts/svc-alpha`)查看 canary 步驟暫停狀態
- 直接用 `curl` 對 v1、v2 端點測試回應差異:
  ```bash
  curl ${BASE_URL}/svc-alpha/v1/hello
  curl ${BASE_URL}/svc-alpha/v2/hello
  ```

### 步驟 8 — 晉升至 50%,啟動 AnalysisTemplate 自動驗證

執行 `kubectl argo rollouts promote svc-alpha -n svc-alpha`(plugin 未安裝時改在 dashboard UI 點 Promote 按鈕)。

流量提升至 50%,同時 AnalysisTemplate 開始查詢 Prometheus 指標:

- 成功率(success rate)≥ 95%
- 連續三個 30 秒區間均達標 → 通過
- 任一區間失敗 → 整個 AnalysisRun 失敗,觸發 Rollout 自動中止

### 步驟 9 — 完全晉升至 100%

執行第二次 `kubectl argo rollouts promote`(或 dashboard UI),Rollout 推進至 `setWeight: 100`,v2 成為穩定版本,Grafana 顯示 100% 流量導向 v2。

### 步驟 10(選用)— 模擬 Canary 失敗與自動回滾

互動確認 `[y/N]` 後,向 `?fail=true` 端點連續發送 60 次錯誤請求:

```bash
for i in {1..60}; do
  curl -s "${BASE_URL}/svc-alpha/v2/hello?fail=true" > /dev/null
done
```

錯誤率超過 AnalysisTemplate 閾值(10%),觸發三層自動恢復:

1. **AnalysisRun 失敗** — Prometheus 查詢回報錯誤率異常
2. **Rollout 中止** — 自動進入 `Aborted` 狀態
3. **流量回滾至 v1** — Stable service 重新承擔 100% 流量

可在 Argo Rollouts UI 即時觀察整個失敗 → 中止 → 回滾流程。

## 拆除平台

務必使用專用腳本(避免 Kyverno webhook deadlock):

```bash
# 標準
bash scripts/teardown.sh

# 非預設 port
HTTP_PORT=9080 bash scripts/teardown.sh
```

> **為何不直接用 `terraform destroy`?**
> Kyverno、nginx-ingress、Crossplane 安裝時會建立 `ValidatingWebhookConfiguration` 和 `MutatingWebhookConfiguration`。直接執行 `terraform destroy` 時,Kubernetes 會在 pod 終止過程中仍嘗試呼叫 webhook,但已終止的 pod 無法回應,造成死鎖。`teardown.sh` 會在 `terraform destroy` 前先刪除 webhook 設定、為 nginx/Kyverno/Crossplane 各設 60 秒分階段 timeout、最終 force-delete namespace 與 finalizer,並對 Step 6 的全量 destroy 加上 5 次 retry(同 install.sh 的 Windows provider crash 規避)。

## 常見問題

### 「Backstage 顯示空白頁 / 跳轉迴圈 / `manifest.json 404`」

最常見原因:未完成 hosts 檔案設定,或瀏覽器快取了舊的 NXDOMAIN 回應。

```powershell
ipconfig /flushdns
```

並在 Chrome 中開啟 `chrome://net-internals/#dns` → **Clear host cache**。

### 「Argo Rollouts dashboard 卡在 Loading…」

訪問 `${BASE_URL}/rollouts`(無 namespace)時,dashboard 預設嘗試載入 `argo-rollouts` namespace,該 namespace 內無 Rollout 資源因此卡住。請改用:

```
http://localhost:9080/rollouts/svc-alpha
http://localhost:9080/rollouts/svc-beta
```

### 「kubectl: error: unknown command 'argo' for 'kubectl'」

`kubectl-argo-rollouts` 外掛未安裝,或不在 `PATH` 中。請參考執行前置作業 2 安裝。`demo.sh` 已將此外掛標記為選用 — 未安裝時 Steps 6/8/9/10 會改走 dashboard UI,流程仍可完整執行。

### 「步驟 6 的 git commit 失敗」

`scripts/install.sh` 的 Step 4b 會在 `idp-local/` 中初始化獨立的 git repo(供 ArgoCD `file:///idp-local` 使用)。若該步驟未成功,Step 6 的 `git add && git commit` 會失敗。手動修復:

```bash
cd <REPO_ROOT>     # 即 idp-local/
git init -q
git add -A && git commit -q -m "initial snapshot for ArgoCD"
```

## 相關文件

- [README-install.md](README-install.md) — `install.sh` 詳細功能說明、安裝前置作業、環境變數
- [terraform/outputs.tf](terraform/outputs.tf) — 平台端點的 Terraform output(可用 `terraform output` 事後查詢)
- 各服務 chart 位於 `charts/svc-alpha/` 與 `charts/svc-beta/`(由 ArgoCD 直接部署)
