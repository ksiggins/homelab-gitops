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

This guide explains how to install the **Bitnami Sealed Secrets controller** using Argo CD and securely manage Kubernetes Secrets in GitOps style using the helper script `scripts/seal_secret.sh`.

### 1. Install the `kubeseal` CLI

On **macOS**, install via Homebrew:

```bash
brew install kubeseal
```

Verify installation:

```bash
kubeseal --version
```

You should see output similar to:

```
kubeseal version: v0.27.0
```

> The `kubeseal` CLI encrypts plaintext Kubernetes Secrets into SealedSecrets that can only be decrypted by the controller running in your cluster.

### 2. Deploy the Sealed-Secrets Controller via Argo CD

The controller manages encryption and decryption of all SealedSecrets in your cluster.

Create the following Argo CD Application under `apps/templates/sealed-secrets.yaml`:

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
    argocd.argoproj.io/sync-wave: "1"
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

Commit this file and allow Argo CD to sync — it will install the controller and CRDs automatically.

Validate the installation:

```bash
kubectl get pods -n sealed-secrets
```

You should see a running `sealed-secrets-controller` pod.

### 3. Generate Encrypted Secrets with the Helper Script

Use the helper script to easily encrypt key/value pairs into SealedSecret data.

```bash
scripts/seal_secret.sh <namespace> key1=value1 [key2=value2 ...]
```

Examples:

```bash
./scripts/seal_secret.sh cert-manager api-token='YOUR_CLOUDFLARE_TOKEN'
```

or multiple keys:

```bash
./scripts/seal_secret.sh monitoring admin-user=admin admin-password='S3cr3t!'
```

The script automatically detects the Sealed-Secrets controller, contacts it for the public key, and encrypts your values locally.
It works even if the target namespace doesn’t yet exist.

Sample output:

```
# Copy the below lines into your SealedSecret under spec.encryptedData

    admin-user: AgBYQiXkvi3YYp1hEa5NnC2OFQYUpJfllG+ziQNWmo1tBdmLB...
    admin-password: AgAQGmqNpRovRD7zPu5mST51KE5B98mTQQt1yQVybZ9suv...
```

Copy each encrypted key into your SealedSecret manifest, under `spec.encryptedData`.

### 4. Create the SealedSecret Manifest

Save your encrypted data under the appropriate path, for example:

```
manifests/cert-manager/issuer/cloudflare-secret.yaml
```

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: cloudflare-secret
  namespace: cert-manager
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  labels:
    app.kubernetes.io/name: cert-manager
    app.kubernetes.io/component: dns-credentials
    app.kubernetes.io/part-of: homelab-gitops
    app.kubernetes.io/managed-by: argocd
    app.kubernetes.io/instance: cert-manager
spec:
  encryptedData:
    api-token: <PASTE_ENCRYPTED_BLOB_HERE>
```

Commit and push this file — it’s safe to store encrypted secrets in Git.

### 5. Verify Secret Decryption in Cluster

After Argo CD syncs, the Sealed-Secrets controller automatically decrypts and creates a native Kubernetes Secret in the target namespace.

Verify:

```bash
kubectl get sealedsecret -n cert-manager
kubectl get secret cloudflare-secret -n cert-manager
```

If both resources exist, the process is working correctly.

### 6. Rotate or Update Secrets

To update credentials:

1. Re-run the helper script with updated values.
2. Replace the encrypted strings in your committed `SealedSecret` file.
3. Commit and push — Argo CD syncs and the Secret is automatically updated in the cluster.

Your GitOps environment now supports fully encrypted secret management with zero plaintext exposure.
