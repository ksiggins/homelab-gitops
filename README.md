# Homelab GitOps

## Argo CD Sync-Waves

| **Sync Wave** | **Level** | **Application** | **Environments** | **Purpose / Dependencies** |
|----------------|-----------|------------------|------------------|-----------------------------|
| **0** | Root | `root` | — | Bootstraps all `infra`, `staging`, and `prod` ApplicationSets. Initializes structure and triggers recursive syncs. |
| **1** | Infra | `cert-manager` | — | Installs cert-manager (with CRDs) for automated certificate management. Required by all TLS-enabled apps. |
| **1** | Infra | `longhorn` | — | Deploys Longhorn distributed storage and backup services. Independent of cert-manager. |
| **2** | Component | `cert-manager` | prod, staging | Deploys environment-specific `ClusterIssuer` and Cloudflare DNS API secret. Depends on base `cert-manager`. |
| **3** | Component | `traefik` | prod, staging | Deploys dashboard `IngressRoute`, middleware, auth secret, and certificate. Depends on `cert-manager` and base `traefik`. |
| **4** | Component | `longhorn` | prod, staging | Deploys Longhorn UI `IngressRoute` and TLS certificate. Depends on `cert-manager` and base `traefik`. |

### Sync-Wave Summary

- **Wave 1 →** Establishes core infrastructure: certificate management (`cert-manager`) and storage (`longhorn`).
- **Wave 2 →** Configures environment-specific issuers and secrets for `cert-manager`.
- **Wave 3 →** Deploys ingress controller configuration and certificates for `traefik`.
- **Wave 4 →** Deploys UI ingress and TLS configuration for `longhorn`.

This represents your **exact current stack**, deployed deterministically through the `root → infra → env` ApplicationSet chain.

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
