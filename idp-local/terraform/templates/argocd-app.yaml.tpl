apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${app_name}
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    # The repo-server pod has the host repo mounted at /idp-local with .git/
    # initialized at that root, so Argo CD can git-clone the local file:// URL.
    repoURL: file:///idp-local
    targetRevision: HEAD
    path: charts/${app_name}
    helm:
      releaseName: ${app_name}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${namespace}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
