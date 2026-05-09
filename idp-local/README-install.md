# install.sh 功能說明

此腳本以**七個主要步驟（含兩個子步驟）**自動完成 idp-local 本地 IDP 平台的安裝。

## 使用方式

```bash
# 標準安裝（Linux / macOS）
bash scripts/install.sh

# Windows 11 + Docker Desktop（com.docker.backend 佔用 port 80/8080）
HTTP_PORT=9080 bash scripts/install.sh
```

腳本會在 Step 1b 自動偵測 port 衝突,並印出可用的替代 port 建議。

## ⚠️ 安裝前置作業（強烈建議）

### Backstage 主機名稱解析

Backstage 採用官方 Helm Chart 與官方映像 `ghcr.io/backstage/backstage`,該映像於建構時將前端 `publicPath` 寫死為 `/`,**無法在 sub-path（如 `/backstage`）下正常運作**。因此 Backstage 改以**獨立 hostname**「`backstage.localhost`」掛載,其他服務（Argo CD、Grafana、Rollouts、svc-alpha/svc-beta）仍掛載於 `localhost` 之下。

依 RFC 6761,`*.localhost` 應自動解析為 `127.0.0.1`,但部分企業網路環境的 DNS 伺服器會直接回傳 NXDOMAIN,導致 `kubectl`、`curl`、瀏覽器查詢失敗。

**Windows 11 解法（建議於安裝前完成,需系統管理員權限）:**

1. 以系統管理員身份開啟 PowerShell:
   - 開始選單搜尋「PowerShell」→ 右鍵「以系統管理員身份執行」
2. 將 hostname 加入 hosts 檔案:
   ```powershell
   Add-Content -Path "$env:WINDIR\System32\drivers\etc\hosts" -Value "127.0.0.1 backstage.localhost"
   ```
3. 清除 DNS 快取（強制立即生效）:
   ```powershell
   ipconfig /flushdns
   ```

**手動編輯 hosts 檔案（不使用 PowerShell）:**

1. 以系統管理員身份開啟 Notepad
2. 開啟 `C:\Windows\System32\drivers\etc\hosts`
3. 新增一行:
   ```
   127.0.0.1 backstage.localhost
   ```
4. 儲存後執行 `ipconfig /flushdns`

**Linux / macOS 解法:**

```bash
echo "127.0.0.1 backstage.localhost" | sudo tee -a /etc/hosts
```

**驗證解析（注意:`nslookup` 不讀 hosts 檔案,請改用以下指令）:**

```powershell
ping backstage.localhost
# 預期看到:Pinging backstage.localhost [127.0.0.1] with 32 bytes of data:

Resolve-DnsName backstage.localhost
# 預期看到:Section "Hosts",IPAddress 127.0.0.1
```

> **`nslookup` 為何顯示 NXDOMAIN?** 因為 `nslookup` 直接查詢 DNS 伺服器,完全不讀本機 hosts 檔案。Windows resolver（`GetAddrInfo`）才會優先檢查 hosts,這也是瀏覽器、`ping`、`curl`、`kubectl` 等工具實際使用的解析方式。

## 核心策略

針對 Docker Hub / registry.k8s.io / quay.io / ghcr.io 被封鎖或 DNS 劫持的網路環境,腳本預先透過映像鏡像站（mirror）將所有映像拉取至本地並重新打標籤（retag）,使 kubelet 直接從本地取得映像,完全繞開對外部 registry 的依賴。

## 環境變數（可選）

| 變數 | 預設值 | 說明 |
|---|---|---|
| `HTTP_PORT` | `80` | nginx-ingress LoadBalancer HTTP port;Windows 上若 port 80 被 `com.docker.backend` 佔用,請改用 `9080` |
| `HTTPS_PORT` | `443` | nginx-ingress LoadBalancer HTTPS port |
| `DOCKER_MIRROR` | `docker.m.daocloud.io` | Docker Hub 鏡像站 |
| `K8S_MIRROR` | `k8s.m.daocloud.io` | registry.k8s.io 鏡像站 |
| `GHCR_MIRROR` | `ghcr.m.daocloud.io` | GitHub Container Registry 鏡像站 |
| `QUAY_MIRROR` | `quay.m.daocloud.io` | quay.io 鏡像站（Argo CD、Argo Rollouts、Prometheus 等映像來源） |
| `KYVERNO_MODE` | `Enforce` | Kyverno 策略模式（`Audit` / `Enforce`） |
| `SKIP_BUILD` | `false` | 跳過建構服務映像（`true` 時需 svc-alpha / svc-beta 映像已存在） |
| `<NAME>_REPO_URL` | — | 任一 Helm repo 的鏡像 URL 覆寫（如 `PROMETHEUS_COMMUNITY_REPO_URL`),詳見步驟 4 |

## 執行步驟說明

### 步驟 1 — 先決條件檢查

驗證 `docker`、`kubectl`、`helm`、`terraform` 均已安裝並在 PATH 中;確認 Docker daemon 正在執行;確認 Docker Desktop Kubernetes cluster 可連線。

### 步驟 1b — Host port 可用性檢查（Windows）

偵測 `HTTP_PORT`（預設 80）是否已被 Windows 程序佔用。若佔用,腳本會:

1. 識別佔用程序（如 `com.docker.backend`、`W3SVC`）並提供對應的釋放方式
2. 自動掃描備用 port（9080、9090、9443、38080、39080）,印出第一個可用的 port

```
  ✘  Port 80 is held by PID 18656 (com.docker.backend).
  ⚠    Docker Desktop's backend owns port 80 — cannot be stopped.
  ⚠    → Use this confirmed-free port instead:
  ⚠      HTTP_PORT=9080 bash scripts/install.sh
```

> 此步驟僅在 Windows 環境（可呼叫 `powershell.exe`）執行;Linux / macOS 自動略過。

### 步驟 2 — 透過鏡像站預拉映像

分四類來源預拉映像:

- **registry.k8s.io 映像**（ingress-nginx controller v1.9.6）— 透過 `K8S_MIRROR` 拉取後 retag 回原始名稱
- **Docker Hub 映像**（Grafana、Redis、Postgres）— 透過 `DOCKER_MIRROR` 拉取後 retag 為 `docker.io/...`
- **GitHub Container Registry 映像**（Kyverno cleanup-controller、Backstage 官方映像 `backstage/backstage:1.27.0`）— 透過 `GHCR_MIRROR` 拉取後 retag 為 `ghcr.io/...`
- **quay.io 映像**（Argo CD v2.10.7、Argo Rollouts v1.7.2、kubectl-argo-rollouts v1.7.2、Prometheus operator/server、Alertmanager、node-exporter）— 透過 `QUAY_MIRROR` 拉取後 retag 為 `quay.io/...`

任一映像拉取失敗時僅發出警告,不中斷流程;kubelet 會回退至原始 registry 直連。

### 步驟 3 — 建構服務映像

呼叫 `scripts/build-images.sh` 建構 `svc-alpha:v1`、`svc-alpha:v2`、`svc-beta:v1`、`svc-beta:v2` 四個本地映像。若 `SKIP_BUILD=true`,則改為驗證這四個映像是否已存在於本地。

> **註:** 舊版的「Step 3a — Build custom Backstage image」已移除。Backstage 現採用官方 chart + 官方映像,無須本地建構。

### 步驟 4 — Helm repo 同步

清除所有缺少本地 index 快取的過期 Helm repo（避免 Terraform Helm provider 在 `helm_release` 時因缺少快取而全部失敗）,接著以四階回退機制註冊六個 Helm repo:

1. **Tier 1+2（主要 URL）:** `helm repo add` 重試 3 次 + `curl` 直接下載 `index.yaml` 至 helm cache
2. **Tier 3（CDN 備援）:** 若 GitHub Pages 無法存取,自動改用 jsdelivr CDN（`cdn.jsdelivr.net/gh/<owner>/<repo>@gh-pages`）
3. **Tier 4(中止安裝):** 若皆失敗,腳本會印出可直接複製的回復指令並退出（避免後續 Terraform 浪費 25 分鐘重試）

| Repo 名稱 | 用途 | 預設來源 |
|---|---|---|
| `ingress-nginx` | Nginx Ingress Controller | `https://kubernetes.github.io/ingress-nginx` |
| `kyverno` | Kyverno 策略引擎 | `https://kyverno.github.io/kyverno` |
| `crossplane-stable` | Crossplane | `https://charts.crossplane.io/stable`(非 GitHub Pages,無 CDN 備援) |
| `prometheus-community` | kube-prometheus-stack | `https://prometheus-community.github.io/helm-charts` |
| `backstage` | Backstage 開發者入口（官方 chart 1.9.4） | `https://backstage.github.io/charts` |
| `argo` | Argo CD、Argo Rollouts | `https://argoproj.github.io/argo-helm` |

可透過 `<NAME>_REPO_URL` 環境變數個別覆寫,例如:

```bash
PROMETHEUS_COMMUNITY_REPO_URL=https://cdn.jsdelivr.net/gh/prometheus-community/helm-charts@gh-pages \
  bash scripts/install.sh
```

最後執行 `helm repo update` 更新本地快取。

### 步驟 4b — 初始化 ArgoCD 本地 Git repo

ArgoCD repo-server 會以 `git clone file:///idp-local` 存取本地 chart,因此 `idp-local/` 目錄必須是獨立的 git repo。

- 若 `idp-local/.git/` 不存在:執行 `git init` 並提交所有檔案（首次安裝）
- 若已存在:偵測未提交的變更並自動補提（`charts/` 有修改時確保 ArgoCD HEAD 看到最新版本）

> 此巢狀 git repo 不影響外層 `IDP_example` repo;git 將其視為嵌入式 repository 並忽略其 `.git/`。

### 步驟 5 — Terraform apply

切換至 `terraform/` 目錄。安裝流程:

1. **State 正規化**:以 Python 直接讀寫 `terraform.tfstate`,移除任何由較新版 kubernetes provider 寫入的 `identity` 區塊（解除 "managed by newer provider version" 鎖死）,並修補 Windows 中斷寫入造成的 NUL byte padding
2. **Force-unlock**:清理上次崩潰留下的過期 state lock
3. **`terraform init -upgrade`**
4. **Phase 1（kubernetes_* 資源序列化建立）**:以 `-parallelism=1` 建立所有 namespace、ServiceAccount、ConfigMap、Secret、Deployment、Service 等。Windows 上 hashicorp/kubernetes provider 在並行 RPC 下會因 Go runtime stack corruption 崩潰,序列化可規避此問題
5. **Phase 2（Helm release、kubectl_manifest）**:使用預設 parallelism 建立 helm_release 與 kubectl_manifest 資源
6. **Retry 機制**:每 phase 最多重試 5 次,每次重試前自動 reconcile 已建立但未進入 state 的孤兒資源

每次 `terraform apply` 傳入下列變數:

| 變數 | 來源 |
|---|---|
| `project_root` | `$REPO_ROOT`(`idp-local/` 絕對路徑) |
| `kyverno_enforcement_mode` | `$KYVERNO_MODE` |
| `http_port` | `$HTTP_PORT` |
| `https_port` | `$HTTPS_PORT` |

> 首次執行約需 10–20 分鐘（取決於映像下載速度）。

### 步驟 6 — 等待平台就緒

分兩階段等待:

**階段 A — Terraform 管理的 namespace（標準 Deployment）**

針對以下 namespace 執行 `kubectl wait --for=condition=available deployment`,逾時 300 秒:

`ingress-nginx` · `kyverno` · `crossplane-system` · `monitoring` · `argocd` · `argo-rollouts` · `backstage`

**階段 B — ArgoCD 管理的 namespace（Argo Rollouts,非 Deployment）**

`svc-alpha` 和 `svc-beta` 由 ArgoCD Application 非同步部署,使用 Argo Rollout 而非標準 Deployment。腳本以輪詢方式每 10 秒確認 pod 是否出現,最長 300 秒。

### 步驟 7 — 列印平台端點

安裝完成後輸出所有可存取的 URL 及認證資訊（與 `terraform output` 取得的內容一致）:

| 服務 | URL（HTTP_PORT=9080 範例） | 認證 |
|---|---|---|
| **Backstage Portal** | **`http://backstage.localhost:9080`** ⚠️ | — Guest sign-in |
| Argo CD | `http://localhost:9080/argocd` | admin / `<terraform output -raw argocd_admin_password>` |
| Argo Rollouts UI | `http://localhost:9080/rollouts/svc-alpha`(namespace 在 URL path 中) | — |
| Grafana | `http://localhost:9080/grafana` | admin / idp-demo |
| svc-alpha v1 | `http://localhost:9080/svc-alpha/v1/hello` | — |
| svc-alpha v2 | `http://localhost:9080/svc-alpha/v2/hello` | — |
| svc-beta v1 | `http://localhost:9080/svc-beta/v1/hello` | — |
| svc-beta v2 | `http://localhost:9080/svc-beta/v2/hello` | — |

> ⚠️ **Backstage 使用獨立 hostname**:請務必先完成上方「⚠️ 安裝前置作業」段落的 hosts 檔案設定,否則 Backstage 在瀏覽器以外的工具(`curl`、`kubectl`、scripts)將無法存取。

事後查詢 URL:

```bash
cd terraform
terraform output backstage_url
terraform output argocd_url
terraform output -raw argocd_admin_password
```

## Windows 11 常見問題

### Port 80 / 8080 被 `com.docker.backend` 佔用

Docker Desktop 4.20+ 會將 `com.docker.backend` 綁定至 port 80（Dashboard）及 port 8080（內部 API）。這兩個 port 無法停用,WSL2 port mirroring 嘗試將 nginx-ingress 暴露在同一 port 時會被攔截,導致所有服務均返回 Go 404（`Content-Length: 19`）。

**解決方式:** 使用腳本自動建議的替代 port:

```bash
HTTP_PORT=9080 bash scripts/install.sh
```

### Backstage 顯示空白頁 / 跳轉迴圈 / `manifest.json 404`

最常見原因:未完成 hosts 檔案設定,或瀏覽器快取了舊的 NXDOMAIN 回應。

```powershell
ipconfig /flushdns
```

並在 Chrome 中開啟 `chrome://net-internals/#dns` → **Clear host cache**。

如已用 `localhost:9080/backstage` 開啟過 Backstage 而失敗,請改用 `http://backstage.localhost:9080`。

### svc-alpha / svc-beta 返回 nginx 404

這兩個服務由 ArgoCD Application 部署（非 Terraform 直接部署）。若 ArgoCD 未成功 sync,Ingress 規則不存在,nginx 返回 HTML 404。

常見原因:`idp-local/` 缺少 `.git/` 目錄,ArgoCD 無法 `git clone file:///idp-local`。**Step 4b** 已自動修復此問題。

### 瀏覽器 console 出現大量「A listener indicated an asynchronous response by returning true」錯誤

```
:9080/catalog?...:1 Uncaught (in promise) Error: A listener indicated an asynchronous
response by returning true, but the message channel closed before a response was received
```

**這不是 Backstage 或 IDP 平台的 bug,而是 Chrome 擴充功能(AdBlock Plus、AdBlock 等)的已知雜訊。**

技術原因:擴充功能的 content script 註冊了 `chrome.runtime.onMessage` listener 並 `return true`(表示「我會非同步回應」),但 channel 關閉前沒有 `sendResponse`,Chrome 因而印出這條警告。任何裝有這類擴充的 Chrome 都會在**所有網站**上看到同樣訊息。

**驗證(三選一):**

- **無痕視窗測試:** 用 `Ctrl+Shift+N` 開啟 Backstage URL — 擴充預設停用 — 訊息消失即可確認非 Backstage 問題
- **任意網站對照:** 在同一 Chrome profile 開啟 `https://www.google.com`,F12 console 會看到同樣訊息
- **暫停擴充:** `chrome://extensions/` 暫時關閉 AdBlock Plus / AdBlock,重新整理 Backstage,訊息消失即可確認

**過濾掉這類雜訊:** F12 → Console → Filter 欄位輸入 `-listener`(前面加減號表示排除),即可隱藏所有包含 "listener" 的訊息,真正的錯誤仍會顯示。

**真正的 Backstage / 平台錯誤長這樣(才需要處理):**

- `Failed to fetch` 後接 `/api/catalog/...`、`/api/techdocs/...` 等 Backstage API 路徑
- `404 Not Found` 出現在 Network 面板的紅色項目(非 console)
- Stack trace 指向 `@backstage/...` 套件
- Backstage 主畫面紅色橫幅錯誤(如先前的 TechDocs EROFS、YAML duplicate key 錯誤)

### Argo Rollouts dashboard 卡在 Loading…

導覽至 `localhost:9080/rollouts`(無 namespace) 時,dashboard 預設嘗試載入 `argo-rollouts` namespace,該 namespace 內無 Rollout 資源因此卡住。請改用:

```
http://localhost:9080/rollouts/svc-alpha
http://localhost:9080/rollouts/svc-beta
```

進入後可由右上 namespace 下拉切換。

## 🔐 選用:啟用 SSO 登入(GitHub + Google)

預設安裝採用 Backstage 的 **Guest 登入**(無 IdP、無密碼),適合本機 demo。
若要為**多人共享環境**或**正式 demo 場景**啟用 SSO,可額外掛載 GitHub OAuth 與
Google OAuth 兩個 Sign-in provider — 兩者皆已內建於官方映像 `ghcr.io/backstage/backstage:1.27.0`,
無須建構自訂映像。

### 步驟 1 — 註冊 OAuth 應用程式(per-attendee 或 per-environment)

**GitHub OAuth App** (建議使用個人帳號或專屬 demo organization):

1. 開啟 https://github.com/settings/developers → **New OAuth App**
2. 填寫:
   - Application name: `Backstage IDP Demo`
   - Homepage URL: `http://backstage.localhost:9080`
   - Authorization callback URL: `http://backstage.localhost:9080/api/auth/github/handler/frame`
3. Register → 記下 **Client ID** → **Generate a new client secret** → 記下 **Client Secret**

**Google Cloud OAuth Client** (需有 Google Cloud Project):

1. 開啟 https://console.cloud.google.com/apis/credentials
2. 上方選單建立新 Project(或選現有的)
3. **+ CREATE CREDENTIALS** → **OAuth client ID**
4. Application type: **Web application**
5. Authorized redirect URIs: `http://backstage.localhost:9080/api/auth/google/handler/frame`
6. CREATE → 記下 **Client ID** 與 **Client Secret**

> ⚠️ **Callback / redirect URI 必須完全一致**(scheme + host + port + path),否則 OAuth provider 會回傳 `redirect_uri_mismatch` 錯誤。若你使用非 9080 的 `HTTP_PORT`,請相應調整。

### 步驟 2 — 將 4 組 secrets 寫入 Kubernetes(不可進入 git)

```bash
kubectl create secret generic backstage-sso   -n backstage   --from-literal=AUTH_GITHUB_CLIENT_ID='Iv1.xxxxxxxx'   --from-literal=AUTH_GITHUB_CLIENT_SECRET='ghp_xxxxxxxxxxxx'   --from-literal=AUTH_GOOGLE_CLIENT_ID='nnn-yyy.apps.googleusercontent.com'   --from-literal=AUTH_GOOGLE_CLIENT_SECRET='GOCSPX-zzzzzzz'
```

> 此 Secret 與 backstage 的 ConfigMap / Deployment 同 namespace,Backstage pod 才能透過 `valueFrom.secretKeyRef` 讀取。

### 步驟 3 — 複製範本檔案並啟用

```bash
cd backstage/
cp app-config-sso.yaml.example app-config-sso.yaml
# 此檔已加入 backstage/.gitignore,無需編輯內容
```

`app-config-sso.yaml` 本身**不含**任何 client secret — 它只引用 `${AUTH_GITHUB_CLIENT_ID}` 等環境變數,實際值由步驟 2 的 k8s Secret 注入。

### 步驟 4 — 修改 Terraform 模組以掛載額外設定

編輯 `terraform/modules/backstage/main.tf`,在 `helm_release.backstage` 的 values 區塊內:

**4a. 為 `extraEnvVars` 新增四個變數:**

```yaml
extraEnvVars:
  - name: ARGOCD_ADMIN_PASSWORD
    valueFrom: { secretKeyRef: { name: backstage-argocd, key: ARGOCD_ADMIN_PASSWORD } }
  - name: POSTGRES_PASSWORD
    valueFrom: { secretKeyRef: { name: backstage-postgres, key: POSTGRES_PASSWORD } }
  # ↓ 新增 4 行
  - name: AUTH_GITHUB_CLIENT_ID
    valueFrom: { secretKeyRef: { name: backstage-sso, key: AUTH_GITHUB_CLIENT_ID } }
  - name: AUTH_GITHUB_CLIENT_SECRET
    valueFrom: { secretKeyRef: { name: backstage-sso, key: AUTH_GITHUB_CLIENT_SECRET } }
  - name: AUTH_GOOGLE_CLIENT_ID
    valueFrom: { secretKeyRef: { name: backstage-sso, key: AUTH_GOOGLE_CLIENT_ID } }
  - name: AUTH_GOOGLE_CLIENT_SECRET
    valueFrom: { secretKeyRef: { name: backstage-sso, key: AUTH_GOOGLE_CLIENT_SECRET } }
```

**4b. 為 `extraAppConfig` 新增第二個 ConfigMap 引用(主設定檔之後):**

```yaml
extraAppConfig:
  - filename: app-config.yaml
    configMapRef: backstage-app-config
  # ↓ 新增 — 將 SSO 設定層疊在主設定上
  - filename: app-config-sso.yaml
    configMapRef: backstage-app-config-sso
```

**4c. 在模組中新增第二個 ConfigMap 資源(與 `kubernetes_config_map.backstage_app_config` 並列):**

```hcl
resource "kubernetes_config_map" "backstage_app_config_sso" {
  metadata {
    name      = "backstage-app-config-sso"
    namespace = kubernetes_namespace.backstage.metadata[0].name
  }
  data = {
    "app-config-sso.yaml" = file("${var.project_root}/backstage/app-config-sso.yaml")
  }
}
```

**4d. 將該 ConfigMap 加入 `helm_release.backstage` 的 `depends_on`:**

```hcl
depends_on = [
  kubernetes_config_map.backstage_app_config,
  kubernetes_config_map.backstage_app_config_sso,   # 新增
  kubernetes_config_map.backstage_catalog,
  ...
]
```

### 步驟 5 — 套用變更

```bash
cd terraform
terraform apply   -replace='module.backstage.kubernetes_config_map.backstage_app_config_sso'   -replace='module.backstage.helm_release.backstage'   -var="project_root=$(cd .. && pwd)"   -var="http_port=${HTTP_PORT:-9080}"   -var="https_port=${HTTPS_PORT:-9443}"   -auto-approve
cd ..

kubectl rollout restart deployment -n backstage backstage
kubectl rollout status  deployment -n backstage backstage --timeout=120s
```

### 步驟 6 — 驗證

打開 `http://backstage.localhost:9080`,登入頁面應該出現**三張卡片**:

- **Sign in as Guest** — 原本的 fallback,可保留供 demo 用
- **Sign in using GitHub** — 點擊跳轉 GitHub OAuth → Authorize → 自動返回並登入
- **Sign in using Google** — 同上,使用 Google 帳號

若 OAuth callback 失敗,常見原因:

| 症狀 | 原因 | 解決 |
|---|---|---|
| `redirect_uri_mismatch` | OAuth App 註冊的 callback URL 與實際不符 | 確認 Authorization callback URL 完全等於 `http://backstage.localhost:9080/api/auth/<provider>/handler/frame` |
| 點擊登入後白屏,console 顯示 401 | k8s Secret 未建立或 key 名稱拼錯 | `kubectl get secret backstage-sso -n backstage -o yaml` 檢查所有 4 個 key 是否存在 |
| `User not found` 錯誤 | catalog 無對應 User entity | 步驟 3 的範本檔案已包含 `emailMatchingUserEntityProfileEmail` fallback,允許未在 catalog 註冊的使用者登入 |
| Pod CrashLoopBackOff | `app-config-sso.yaml` 不存在但 ConfigMap 已被 Terraform 建立(空檔案) | 確認步驟 3 的 `cp` 已執行,且檔案有實質內容 |

### 移除 SSO(回到單純 Guest)

```bash
# 1. 從 main.tf 移除步驟 4 的所有變更(extraEnvVars 4 行、extraAppConfig 1 區塊、ConfigMap resource、depends_on 1 行)
# 2. 套用
cd terraform && terraform apply -replace='module.backstage.helm_release.backstage'   -var="project_root=$(cd .. && pwd)" -var="http_port=${HTTP_PORT:-9080}"   -var="https_port=${HTTPS_PORT:-9443}" -auto-approve
# 3. 刪除 secret 與 SSO config 檔案
kubectl delete secret backstage-sso -n backstage --ignore-not-found
rm backstage/app-config-sso.yaml
```

### 與 Production 的差距

此設定足夠 demo / staging,但要上 production 還缺:

- **session 持久化:** 設定 `auth.session.secret`(從另一個 Secret 注入 `BACKEND_SECRET`),否則 pod 重啟後所有 session 失效
- **catalog 中的 User / Group 實體:** 透過 `@backstage/plugin-catalog-backend-module-github-org` 或 `-msgraph` 自動同步(這兩個 plugin **不在** `default-app` 映像,需自訂映像)
- **HTTPS:** OAuth provider 對非 localhost 的 production URL 通常要求 HTTPS;在 nginx-ingress 加 TLS termination 並更新 callback URL
- **權限框架:** Backstage 1.13+ Permission API 可定義「只有 owner 能編輯該 entity」等規則,預設「所有登入者皆可」
- **移除 guest fallback:** 從 `auth.providers` 中移除 `guest` 區塊,以及 `app-config-sso.yaml` 中 GitHub 設定的 `emailMatchingUserEntityProfileEmail` resolver

## 排查與拆除

```bash
# 查看未正常運行的 Pod
kubectl get pods -A | grep -vE 'Running|Completed'

# 查看 Ingress 設定（注意 backstage 使用獨立 host）
kubectl get ingress -A

# 查看 ArgoCD Application 同步狀態
kubectl get app -n argocd

# 查看 terraform 平台端點
cd terraform && terraform output

# 完整拆除平台（使用專用腳本,避免 Kyverno webhook deadlock）
bash scripts/teardown.sh
# Windows 上若使用非預設 port:
HTTP_PORT=9080 bash scripts/teardown.sh
```

> **為何不直接用 `terraform destroy`?**
> Kyverno、nginx-ingress、Crossplane 安裝時會建立 `ValidatingWebhookConfiguration` 和 `MutatingWebhookConfiguration`。直接執行 `terraform destroy` 時,Kubernetes 會在 pod 終止過程中仍嘗試呼叫 webhook,但已終止的 pod 無法回應,造成死鎖。`teardown.sh` 會在 `terraform destroy` 前先刪除 webhook 設定、設定 60 秒分階段 timeout、最終 force-delete namespace 與 finalizer,避免此問題。
