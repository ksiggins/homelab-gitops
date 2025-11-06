# Homelab GitOps

## Handling Let’s Encrypt Staging Certificates in Local Testing

When using **Let’s Encrypt’s staging ClusterIssuer** (e.g., `letsencrypt-dns01-staging`), certificates are signed by *untrusted test roots*. These roots are **not included in macOS, Windows, or browser trust stores** — by design.
As a result, browsers like Chrome and Safari will show `net::ERR_CERT_AUTHORITY_INVALID`, and web apps such as **Grafana** may log you out frequently because session cookies and local storage are tied to *trusted origins*.

### Why This Happens

Let’s Encrypt’s staging environment issues certificates under the `(STAGING) Pretend Pear X1` root (RSA) or related chains. See their docs:
https://letsencrypt.org/docs/staging-environment/

To eliminate constant browser warnings and session resets during local testing, you can **temporarily import the staging root certificate** into your system’s trust store so it appears trusted locally.

### Steps (macOS Example)

1. **Download the staging root certificate** (choose matching chain):
   ```bash
   curl -O https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x1.pem
   ```

2. **Convert PEM → DER format** (macOS preferred):
   ```bash
   openssl x509 -in letsencrypt-stg-root-x1.pem -outform der -out /tmp/letsencrypt-stg-root-x1.der
   ```

3. **Add the certificate to the System keychain**:
   ```bash
   sudo security add-trusted-cert      -d -r trustRoot      -k /Library/Keychains/System.keychain      /tmp/letsencrypt-stg-root-x1.der
   ```

4. **Verify in Keychain Access**
   - Open *Keychain Access* → select **System** keychain → *Certificates*
   - Look for **(STAGING) Pretend Pear X1** (blue “+” icon indicates trusted)
   - Restart Chrome/Safari and reload your staging site (e.g., Grafana) — the TLS should now appear trusted and you should *not* keep getting logged out.

### Removing the Staging Root (After Testing)

Once you switch to production certificates, delete the test root to restore a clean trust store:
```bash
sudo security delete-certificate -c "(STAGING) Pretend Pear X1" /Library/Keychains/System.keychain
```

### Rate Limits: Staging vs Production

Using the staging environment is *strongly recommended for testing* because you avoid hitting the tighter production quotas.
- Staging: https://letsencrypt.org/docs/staging-environment/)
- Production: https://letsencrypt.org/docs/rate-limits/

**Staging Environment Limits**
- New Registrations per IP Address: **50 per 3 hours**
- New Registrations per IPv6 Range: **500 per 3 hours**
- New Orders per Account: **1500 per 3 hours**
- New Certificates per Registered Domain: **30,000 per second**
- New Certificates per Exact Set of Hostnames: **30,000 per week**
- Authorization Failures per Hostname per Account: **200 per hour**
- Consecutive Authorization Failures per Hostname per Account: **3,600 per 6 hours**

**Production Environment Limits**
- Certificates per Registered Domain: **50 per week**
- Duplicate Certificate Requests per week: **5**
- Accounts per IP Address: **10 per 3 hours**
- New Orders per Account: **300 per 3 hours**
- Failed Validations per Account: **60 per hour**
- Pending Authorizations per Account: **300 maximum**

If you have frequent rebuilds or CI/CD workflows (e.g., issuing new certs for each cluster create), you can easily hit the production caps.
Use **staging** during automation or testing to avoid temporary rate-limit lockouts.

### Notes

- This trust change only affects your **local machine**.
- Never import staging roots on production or shared environments.
- Use **production issuer** (e.g., `letsencrypt-dns01-prod`) once your automation is validated — those certificates chain to **ISRG Root X1** and are trusted by default.

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
    name: https://kubernetes.default.svc
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
