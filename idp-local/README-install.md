# install.sh 功能說明

**HTTP_PORT=9080 bash scripts/install.sh** for Windows
此腳本以**七個步驟**自動完成 idp-local 本地 IDP 平台的安裝。

## 使用方式

```bash
bash scripts/install.sh
```

## 核心策略

針對 Docker Hub / registry.k8s.io 被封鎖或 DNS 劫持的網路環境，腳本預先透過映像鏡像站（mirror）將所有映像拉取至本地並重新打標籤（retag），使 kubelet 直接從本地取得映像，完全繞開對外部 registry 的依賴。

## 環境變數（可選）

| 變數 | 預設值 | 說明 |
|---|---|---|
| `DOCKER_MIRROR` | `docker.m.daocloud.io` | Docker Hub 鏡像站 |
| `K8S_MIRROR` | `k8s.m.daocloud.io` | registry.k8s.io 鏡像站 |
| `GHCR_MIRROR` | `ghcr.m.daocloud.io` | GitHub Container Registry 鏡像站 |
| `KYVERNO_MODE` | `Enforce` | Kyverno 策略模式（Audit / Enforce） |
| `SKIP_BUILD` | `false` | 跳過建構服務映像（true 時需映像已存在） |

## 七個執行步驟

### 步驟 1 — 先決條件檢查

驗證 `docker`、`kubectl`、`helm`、`terraform` 均已安裝並在 PATH 中；確認 Docker daemon 正在執行；確認 Docker Desktop Kubernetes cluster 可連線。

### 步驟 2 — 透過鏡像站預拉映像

分三類來源預拉映像：

- **registry.k8s.io 映像**（ingress-nginx controller）— 透過 `K8S_MIRROR` 拉取後 retag 回原始名稱
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

### 步驟 5 — Terraform apply

切換至 `terraform/` 目錄，執行 `terraform init -upgrade` 後以 `-auto-approve` 執行 `terraform apply`，傳入 `project_root` 與 `kyverno_enforcement_mode` 兩個變數，完整部署整個 IDP 平台。

> 首次執行約需 10–20 分鐘。

### 步驟 6 — 等待平台就緒

針對九個 namespace 分別執行 `kubectl wait --for=condition=available`，逾時 300 秒：

`ingress-nginx` · `kyverno` · `crossplane-system` · `monitoring` · `argocd` · `argo-rollouts` · `backstage` · `svc-alpha` · `svc-beta`

任一未就緒時發出警告並提示後續排查指令：

```bash
kubectl get pods -n <namespace>
```

### 步驟 7 — 列印平台端點

安裝完成後輸出所有可存取的 URL 及認證資訊：

| 服務 | URL | 認證 |
|---|---|---|
| Backstage Portal | http://localhost/backstage | — |
| Argo CD | http://localhost/argocd | admin / `<terraform output>` |
| Argo Rollouts UI | http://localhost/rollouts | — |
| Grafana | http://localhost/grafana | admin / idp-demo |
| svc-alpha v1 | http://localhost/svc-alpha/v1/hello | — |
| svc-alpha v2 | http://localhost/svc-alpha/v2/hello | — |
| svc-beta v1 | http://localhost/svc-beta/v1/hello | — |
| svc-beta v2 | http://localhost/svc-beta/v2/hello | — |

## 排查與拆除

```bash
# 查看未正常運行的 Pod
kubectl get pods -A | grep -vE 'Running|Completed'

# 查看 Ingress 設定
kubectl get ingress -A

# 完整拆除平台
cd terraform && terraform destroy \
  -var="project_root=<REPO_ROOT>" -auto-approve
```
