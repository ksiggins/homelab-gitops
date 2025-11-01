# Homelab GitOps

## Argo CD Sync-Waves Recap

Application Sync-Wave setup from `apps/templates/`:

| **Sync Wave** | **Application** | **Deployment Pattern** | **Purpose** | **Notes** |
|----------------|----------------|-------------------------|--------------|------------|
| **0** | `root` | **Git** | Bootstrap “root-of-apps” — registers all sub-applications recursively. | Runs first; sets the stage for everything. |
| **1** | `sealed-secrets` | **Helm** | Installs Bitnami SealedSecrets controller so future sealed secrets can decrypt. | Must run early because later apps depend on it for secrets. |
| **2** | `cert-manager` | **Helm** | Installs cert-manager chart (`skipCrds: true`). | Needed before any app that creates Certificates or Issuers. |
| **2** | `traefik-crds` | **Git** | Installs Traefik CRDs (CustomResourceDefinitions). | Required before deploying `traefik`. |
| **2** | `longhorn` | **Helm** | Installs Longhorn chart and creates the `longhorn-system` namespace. | Provides distributed storage for PVCs and backups. |
| **3** | `cert-issuer` | **Git** | Applies `ClusterIssuer` manifests that rely on cert-manager. | Depends on wave 2 `cert-manager`. |
| **3** | `traefik` | **Helm** | Deploys Traefik Helm chart (uses CRDs from wave 2). | Provides ingress controller for later apps. |
| **3** | `kube-prometheus-stack` | **Multi-source** | Deploys Prometheus, Alertmanager, and Grafana stack using Helm, plus Namespace, SealedSecret, Certificate, and IngressRoute manifests via Git. | Depends on Longhorn (storage) and cert-manager (TLS). |
| **4** | `argocd-overlay` | **Git** | Adds extra manifests (IngressRouteTCP, TLS certs) to the Argo CD deployment. | Depends on certs + Traefik. |
| **4** | `traefik-overlay` | **Git** | Adds Traefik dashboard IngressRoute, TLS certificate, and auth secret. | Depends on cert-manager + Traefik. |
| **5** | `longhorn-overlay` | **Git** | Adds sealed NAS credentials, recurring jobs, and ingress for Longhorn UI. | Depends on base Longhorn being deployed (wave 2). |

### Deployment Pattern Legend

- **Helm (repo):** Pulls chart directly from an external Helm repository (e.g., Jetstack, Prometheus Community).
- **Git (manifests):** Applies static or templated manifests (e.g., overlay, CRDs, or Issuers).
- **Multi-source (Helm + Git):** Combines Helm chart with overlay manifests (Namespace, Secrets, Ingress, Certs).

### Sync-Waves
- **Wave 2 →** Core infrastructure (CRDs, certs, storage).
- **Wave 3 →** Dependent apps (Ingress, Monitoring, CertIssuer).
- **Wave 4–5 →** Overlays and UI extensions.
- The order guarantees reproducible GitOps bootstrapping from a blank cluster, even when using multi-source Applications.

## Sealed Secrets Setup

This guide describes how to install the **Bitnami Sealed Secrets controller** using Argo CD and how to securely manage Kubernetes Secrets in GitOps style using the `kubeseal` CLI.

### 1. Install `kubeseal` CLI

On **macOS**, install via Homebrew:

```bash
brew install kubeseal
```

Verify:

```bash
kubeseal --version
```

You should see something like:

```
kubeseal version: v0.27.0
```

> The CLI communicates with the Sealed-Secrets controller in your cluster to encrypt plaintext Secrets into SealedSecrets.

### 2. Deploy the Sealed-Secrets Controller with Argo CD

The controller manages encryption and decryption of Secrets within your cluster.

Create the Argo CD Application `apps/templates/sealed-secrets.yaml` as follows:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sealed-secrets
  namespace: argocd
  labels:
    app.kubernetes.io/name: sealed-secrets
    app.kubernetes.io/component: secret-controller
    app.kubernetes.io/part-of: homelab-gitops
    app.kubernetes.io/managed-by: argocd
    app.kubernetes.io/instance: sealed-secrets
  annotations:
    argocd.argoproj.io/sync-wave: "10"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://bitnami-labs.github.io/sealed-secrets
    chart: sealed-secrets
    targetRevision: 2.17.7
    helm:
      releaseName: sealed-secrets
  destination:
    name: in-cluster
    namespace: sealed-secrets
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ApplyOutOfSyncOnly=true
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
```

Commit this to Git.
When Argo CD syncs, it installs the Sealed-Secrets controller and CRDs into the cluster.

Validate:

```bash
kubectl get pods -n sealed-secrets
```

You should see a `sealed-secrets-controller` pod running.

### 3. Encrypt the Secret Using `kubeseal`

Run the following command to generate a sealed version and extract **just the encrypted blob**:

```bash
kubectl create secret generic cloudflare-secret   --namespace cert-manager   --from-literal=api-token='YOUR_REAL_CLOUDFLARE_API_TOKEN'   --dry-run=client -o yaml | kubeseal   --controller-name=sealed-secrets   --controller-namespace=sealed-secrets   --format yaml   --namespace cert-manager | yq '.spec.encryptedData."api-token"'
```

That prints a single encrypted string (safe to store). Copy it.

### 4. Create a SealedSecret File

Now create your sealed version under:

```
manifests/cert-manager/issuer/cloudflare-api-token.yaml
```

Example:

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: cloudflare-api-token-secret
  namespace: cert-manager
  annotations:
    argocd.argoproj.io/sync-wave: "10"
  labels:
    app.kubernetes.io/name: cert-manager
    app.kubernetes.io/component: cloudflare-dns-token
    app.kubernetes.io/part-of: homelab-gitops
    app.kubernetes.io/managed-by: argocd
    app.kubernetes.io/instance: cert-manager
spec:
  encryptedData:
    api-token: <PASTE_YOUR_ENCRYPTED_BLOB_HERE>
```

Commit and push this file — it’s safe to store encrypted secrets in Git.

### 5. Validate Decryption in Cluster

After Argo CD syncs, the Sealed-Secrets controller will automatically decrypt and create a normal Kubernetes Secret inside the `cert-manager` namespace.

Verify:

```bash
kubectl get sealedsecret -n cert-manager
kubectl get secret cloudflare-api-token-secret -n cert-manager
```

If both exist, the process worked.
You now have a fully GitOps-safe secret management flow.

### 8. Rotate or Update a Secret

When you need to change the token:

1. Re-run the `kubeseal` command to generate a new encrypted blob.
2. Replace the value in your committed `SealedSecret` file.
3. Commit + push → Argo CD syncs → Secret automatically rotated in-cluster.
