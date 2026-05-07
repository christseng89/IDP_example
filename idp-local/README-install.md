# install.sh 功能說明

此腳本以**七個主要步驟（含兩個子步驟）**自動完成 idp-local 本地 IDP 平台的安裝。

## 使用方式

```bash
# 標準安裝（Linux / macOS）
bash scripts/install.sh

# Windows 11 + Docker Desktop（com.docker.backend 佔用 port 80/8080）
HTTP_PORT=9080 bash scripts/install.sh
```

腳本會在 Step 1b 自動偵測 port 衝突，並印出可用的替代 port 建議。

## 核心策略

針對 Docker Hub / registry.k8s.io 被封鎖或 DNS 劫持的網路環境，腳本預先透過映像鏡像站（mirror）將所有映像拉取至本地並重新打標籤（retag），使 kubelet 直接從本地取得映像，完全繞開對外部 registry 的依賴。

## 環境變數（可選）

| 變數 | 預設值 | 說明 |
|---|---|---|
| `HTTP_PORT` | `80` | nginx-ingress LoadBalancer HTTP port；Windows 上若 port 80 被 `com.docker.backend` 佔用，請改用 `9080` |
| `HTTPS_PORT` | `443` | nginx-ingress LoadBalancer HTTPS port |
| `DOCKER_MIRROR` | `docker.m.daocloud.io` | Docker Hub 鏡像站 |
| `K8S_MIRROR` | `k8s.m.daocloud.io` | registry.k8s.io 鏡像站 |
| `GHCR_MIRROR` | `ghcr.m.daocloud.io` | GitHub Container Registry 鏡像站 |
| `KYVERNO_MODE` | `Enforce` | Kyverno 策略模式（`Audit` / `Enforce`） |
| `SKIP_BUILD` | `false` | 跳過建構服務映像（`true` 時需映像已存在） |

## 執行步驟說明

### 步驟 1 — 先決條件檢查

驗證 `docker`、`kubectl`、`helm`、`terraform` 均已安裝並在 PATH 中；確認 Docker daemon 正在執行；確認 Docker Desktop Kubernetes cluster 可連線。

### 步驟 1b — Host port 可用性檢查（Windows）

偵測 `HTTP_PORT`（預設 80）是否已被 Windows 程序佔用。若佔用，腳本會：

1. 識別佔用程序（如 `com.docker.backend`、`W3SVC`）並提供對應的釋放方式
2. 自動掃描備用 port（9080、9090、9443、38080、39080），印出第一個可用的 port

```
  ✘  Port 80 is held by PID 18656 (com.docker.backend).
  ⚠    Docker Desktop's backend owns port 80 — cannot be stopped.
  ⚠    → Use this confirmed-free port instead:
  ⚠      HTTP_PORT=9080 bash scripts/install.sh
```

> 此步驟僅在 Windows 環境（可呼叫 `powershell.exe`）執行；Linux / macOS 自動略過。

### 步驟 2 — 透過鏡像站預拉映像

分三類來源預拉映像：

- **registry.k8s.io 映像**（ingress-nginx controller v1.9.6）— 透過 `K8S_MIRROR` 拉取後 retag 回原始名稱
- **Docker Hub 映像**（Grafana、Redis、Backstage）— 透過 `DOCKER_MIRROR` 拉取後 retag 為 `docker.io/...` 與短名稱
- **GitHub Container Registry 映像**（Kyverno cleanup-controller）— 透過 `GHCR_MIRROR` 拉取後 retag 為 `ghcr.io/...`

任一映像拉取失敗時僅發出警告，不中斷流程。

### 步驟 3 — 建構服務映像

呼叫 `scripts/build-images.sh` 建構 `svc-alpha:v1`、`svc-alpha:v2`、`svc-beta:v1`、`svc-beta:v2` 四個本地映像。若 `SKIP_BUILD=true`，則改為驗證這四個映像是否已存在於本地。

### 步驟 4 — Helm repo 同步

清除所有缺少本地 index 快取的過期 Helm repo（避免 Terraform Helm provider 在 `helm_release` 時因缺少快取而全部失敗），接著註冊六個 Helm repo：

| Repo 名稱 | 用途 |
|---|---|
| `ingress-nginx` | Nginx Ingress Controller |
| `kyverno` | Kyverno 策略引擎 |
| `crossplane-stable` | Crossplane |
| `prometheus-community` | kube-prometheus-stack |
| `backstage` | Backstage 開發者入口 |
| `argo` | Argo CD、Argo Rollouts |

最後執行 `helm repo update` 更新本地快取。

### 步驟 4b — 初始化 ArgoCD 本地 Git repo

ArgoCD repo-server 會以 `git clone file:///idp-local` 存取本地 chart，因此 `idp-local/` 目錄必須是獨立的 git repo。

- 若 `idp-local/.git/` 不存在：執行 `git init` 並提交所有檔案（首次安裝）
- 若已存在：偵測未提交的變更並自動補提（`charts/` 有修改時確保 ArgoCD HEAD 看到最新版本）

> 此巢狀 git repo 不影響外層 `IDP_example` repo；git 將其視為嵌入式 repository 並忽略其 `.git/`。

### 步驟 5 — Terraform apply

切換至 `terraform/` 目錄，執行 `terraform init -upgrade` 後以 `-auto-approve` 執行 `terraform apply`，傳入以下變數，完整部署整個 IDP 平台：

| 變數 | 來源 |
|---|---|
| `project_root` | `$REPO_ROOT`（`idp-local/` 絕對路徑） |
| `kyverno_enforcement_mode` | `$KYVERNO_MODE` |
| `http_port` | `$HTTP_PORT` |
| `https_port` | `$HTTPS_PORT` |

> 首次執行約需 10–20 分鐘。

### 步驟 6 — 等待平台就緒

分兩階段等待：

**階段 A — Terraform 管理的 namespace（標準 Deployment）**

針對以下 namespace 執行 `kubectl wait --for=condition=available deployment`，逾時 300 秒：

`ingress-nginx` · `kyverno` · `crossplane-system` · `monitoring` · `argocd` · `argo-rollouts` · `backstage`

**階段 B — ArgoCD 管理的 namespace（Argo Rollouts，非 Deployment）**

`svc-alpha` 和 `svc-beta` 由 ArgoCD Application 非同步部署，使用 Argo Rollout 而非標準 Deployment，因此 `kubectl wait deployment` 會立即返回（無資源可等）。

腳本改以輪詢方式每 10 秒確認 pod 是否出現，出現後再等待 pod Ready，最長 300 秒。若未就緒則提示排查指令：

```bash
kubectl get app svc-alpha -n argocd
kubectl get pods -n svc-alpha
```

### 步驟 7 — 列印平台端點

安裝完成後輸出所有可存取的 URL 及認證資訊。URL 中的 port 由 `HTTP_PORT` 決定（預設 80 時省略 port 號）：

| 服務 | URL（HTTP_PORT=9080 範例） | 認證 |
|---|---|---|
| Backstage Portal | http://localhost:9080/backstage | — |
| Argo CD | http://localhost:9080/argocd | admin / `<terraform output>` |
| Argo Rollouts UI | http://localhost:9080/rollouts | — |
| Grafana | http://localhost:9080/grafana | admin / idp-demo |
| svc-alpha v1 | http://localhost:9080/svc-alpha/v1/hello | — |
| svc-alpha v2 | http://localhost:9080/svc-alpha/v2/hello | — |
| svc-beta v1 | http://localhost:9080/svc-beta/v1/hello | — |
| svc-beta v2 | http://localhost:9080/svc-beta/v2/hello | — |

## Windows 11 常見問題

### Port 80 / 8080 被 `com.docker.backend` 佔用

Docker Desktop 4.20+ 會將 `com.docker.backend` 綁定至 port 80（Dashboard）及 port 8080（內部 API）。這兩個 port 無法停用，WSL2 port mirroring 嘗試將 nginx-ingress 暴露在同一 port 時會被攔截，導致所有服務均返回 Go 404（`Content-Length: 19`）。

**解決方式：** 使用腳本自動建議的替代 port：

```bash
HTTP_PORT=9080 bash scripts/install.sh
```

### svc-alpha / svc-beta 返回 nginx 404

這兩個服務由 ArgoCD Application 部署（非 Terraform 直接部署）。若 ArgoCD 未成功 sync，Ingress 規則不存在，nginx 返回 HTML 404。

常見原因：`idp-local/` 缺少 `.git/` 目錄，ArgoCD 無法 `git clone file:///idp-local`。**Step 4b** 已自動修復此問題。

## 排查與拆除

```bash
# 查看未正常運行的 Pod
kubectl get pods -A | grep -vE 'Running|Completed'

# 查看 Ingress 設定
kubectl get ingress -A

# 查看 ArgoCD Application 同步狀態
kubectl get app -n argocd

# 完整拆除平台
cd terraform && terraform destroy \
  -var="project_root=<REPO_ROOT>" \
  -var="http_port=<HTTP_PORT>" \
  -auto-approve
```
