# demo.sh 功能說明

此腳本是一份**互動式、逐步引導的展示流程**，設計用於向利害關係人（stakeholders）現場示範 IDP 平台的完整能力。每個步驟執行後會暫停，等待操作者按下 Enter 繼續，方便搭配口頭說明。

## 執行方式

```bash
bash scripts/demo.sh
```

## 11 個展示步驟

### 步驟 0 — 先決條件檢查

驗證五個工具均已就緒：`docker`（daemon 執行中）、`kubectl`（連線至 docker-desktop context）、`terraform`、`helm`、`kubectl-argo-rollouts` 外掛。任一缺失即立即中止。

### 步驟 1 — 建構服務映像

呼叫 `scripts/build-images.sh`，建構 `svc-alpha` 與 `svc-beta` 各自的 v1、v2 共四個 Docker 映像。

### 步驟 2 — 單指令啟動完整 IDP 平台

執行 `terraform init` 與 `terraform apply -auto-approve`，一次部署所有平台元件：

NGINX Ingress · Kyverno · Crossplane · Prometheus + Grafana · Argo CD · Argo Rollouts · Backstage

> 首次執行約需 5–10 分鐘。

### 步驟 3 — 等待平台就緒

分兩類等待：

- **一般 namespace**（`ingress-nginx`、`kyverno`、`crossplane-system`、`monitoring`、`argocd`、`argo-rollouts`、`backstage`）— 使用 `kubectl wait --for=condition=available`，逾時 300 秒
- **服務 namespace**（`svc-alpha`、`svc-beta`）— 改用 `kubectl argo rollouts status` 等待 Rollout 就緒（因 Rollout 不是 Deployment，無法用 `kubectl wait`）

### 步驟 4 — 列印平台端點

| 服務 | URL | 認證 |
|---|---|---|
| Backstage Portal | http://localhost/backstage | — |
| Argo CD | http://localhost/argocd | — |
| Argo Rollouts UI | http://localhost/rollouts | — |
| Grafana | http://localhost/grafana | admin / idp-demo |
| svc-alpha v1 | http://localhost/svc-alpha/v1/hello | — |
| svc-alpha v2 | http://localhost/svc-alpha/v2/hello | — |
| svc-beta v1 | http://localhost/svc-beta/v1/hello | — |
| svc-beta v2 | http://localhost/svc-beta/v2/hello | — |

### 步驟 5 — Backstage 功能導覽

引導展示者依序瀏覽七個 Backstage 功能（開啟瀏覽器至 http://localhost/backstage）：

1. **Catalog** — 查看 svc-alpha、svc-beta 元件列表
2. **Overview 頁籤** — Argo CD 同步狀態（Synced / Healthy）
3. **Kubernetes 頁籤** — 即時 Pod 狀態與 Rollout 進度
4. **API 頁籤** — OpenAPI 規格，v1（已棄用）vs v2 對比
5. **Docs 頁籤** — 由 `docs/index.md` 渲染的 TechDocs
6. **Relations** — svc-alpha → svc-beta 的依賴關係圖
7. **Create** — New IDP Service 範本，示範黃金路徑（golden path）

### 步驟 6 — 觸發 Canary 漸進式部署（v1 → v2）

修改 `charts/svc-alpha/values.yaml` 將映像標籤從 `v1` 改為 `v2`（因 Argo CD 開啟了 `selfHeal: true`，直接 `helm upgrade` 會被立即還原，必須透過 values 變更讓 Argo CD 同步），接著強制觸發 Argo CD refresh + sync，並以背景執行 `kubectl argo rollouts get --watch` 即時顯示 Rollout 進度。

### 步驟 7 — 在 20% 流量時暫停檢視

Rollout 第一階段停在 canary weight 20%，引導觀眾：

- 在 Grafana「IDP Services」儀表板確認約 20% 流量導向 v2
- 在 Argo Rollouts UI 查看 canary 步驟暫停狀態
- 直接用 `curl` 對 v1、v2 端點測試回應差異

```bash
curl http://localhost/svc-alpha/v1/hello
curl http://localhost/svc-alpha/v2/hello
```

### 步驟 8 — 晉升至 50%，啟動 AnalysisTemplate 自動驗證

執行第一次 `kubectl argo rollouts promote`，流量提升至 50%，同時 AnalysisTemplate 開始查詢 Prometheus 指標，驗證成功率是否連續三個 30 秒區間均 ≥ 95%。

### 步驟 9 — 完全晉升至 100%

執行第二次 `kubectl argo rollouts promote`，v2 成為穩定版本，Grafana 顯示 100% 流量導向 v2。

### 步驟 10（選用）— 模擬 Canary 失敗與自動回滾

互動確認後，向 `?fail=true` 端點連續發送 60 次錯誤請求，使錯誤率超過 10% 的閾值，觸發：

**AnalysisRun 失敗 → Rollout 中止 → 自動回滾至 v1**

可在 Argo Rollouts UI 即時觀察整個失敗回滾流程。

## 拆除平台

```bash
cd terraform && terraform destroy \
  -var="project_root=<REPO_ROOT>" -auto-approve
```
