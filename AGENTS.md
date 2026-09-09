# RTF on EKS Auto Mode — Kiro Runbook

Deploy MuleSoft Runtime Fabric on Amazon EKS Auto Mode with a working public ALB endpoint.
Pinned to **Kubernetes 1.35** and **RTF 3.0.277**.

## Before You Start

### Required Tools
```bash
eksctl version    # need 0.195.0+
aws --version     # need 2.15+
kubectl version --client
helm version
aws sts get-caller-identity   # confirms AWS auth
```

### Required Files
- `license.lic` — Mule Enterprise license file (place in this directory)
- `rtf-config.env` — copy from `rtf-config.env.example` and fill in (see below)

### One-Time: Create a Connected App in Anypoint
1. Access Management → Connected Apps → Create App
2. Select "App acts on its own behalf (client credentials)"
3. Add scopes: Runtime Manager → Manage Runtime Fabrics + Read Runtime Fabrics, General → View Environment
4. **Critical**: For each scope, assign to the correct Business Group AND check off specific environment(s) (e.g. Sandbox). Missing this returns empty lists with zero error.
5. Copy Client ID + Client Secret

### Create rtf-config.env
```bash
cp rtf-config.env.example rtf-config.env
```
Fill in:
- `ORG_ID` — your Anypoint org ID
- `CLIENT_ID` / `CLIENT_SECRET` — from the Connected App
- `ENVIRONMENT_NAME` — defaults to "Sandbox"
- `DOMAIN` — a real domain/subdomain you own (e.g. rtf.mulesoftdemo.com)

**Do NOT commit `rtf-config.env` — it contains secrets. Only `.example` is safe to share.**

### values.yaml — NOT required
Script 08 generates one automatically. Only download from Anypoint if you need optional params (FIPS, custom proxy, etc). A real file, if present, takes precedence.

---

## Execution Order

Run scripts sequentially. Each script is idempotent — safe to re-run.
Make all scripts executable first: `chmod +x *.sh`

### Step 1: Delete existing cluster (only if starting over)
```bash
./01-delete-cluster.sh
```
- ~10 min
- Cleans up Ingress objects, Services, waits for ALB deprovisioning, deletes cluster
- Skip if this is a fresh install

### Step 2: Create EKS cluster with Auto Mode
```bash
./02-create-cluster.sh
```
- ~15-20 min
- Creates EKS Auto Mode cluster (K8s 1.35) from `rtf-automode-v3.yaml`
- Validates Auto Mode capabilities after creation
- **Wait for this to complete before proceeding**

### Step 3: Create StorageClass
```bash
./03-create-storageclass.sh
```
- ~1 min
- **CRITICAL**: Auto Mode enables block storage but does NOT create a StorageClass
- Without this, every PVC stays Pending forever
- Provisioner: `ebs.csi.eks.amazonaws.com` (NOT `ebs.csi.aws.com`)

### Step 4: Setup OIDC Provider
```bash
./04-setup-oidc.sh
```
- ~1 min
- Required for IRSA — without this, the ALB controller cannot authenticate
- Needs IAM permissions: `iam:CreateOpenIDConnectProvider`

### Step 5: Install AWS ALB Controller
```bash
./05-install-alb.sh
```
- ~3 min
- Installs ALB controller with IRSA credentials
- IRSA is mandatory — Auto Mode blocks IMDS (hop-limit=1)
- Verify: `kubectl get pods -n kube-system | grep aws-load-balancer`

### Step 6: Add amd64 NodePool
```bash
./06-add-nodepool.sh
```
- ~1 min
- Auto Mode defaults to arm64 (Graviton) — RTF images are amd64-only
- Creates dedicated Karpenter NodePool for the `rtf` namespace

### Step 7: Register Fabric & Associate Environment
```bash
./07-register-fabric.sh
```
- ~1 min
- **Automates two manual UI steps**: fabric creation + environment association
- Reads credentials from `rtf-config.env`
- Writes `rtf-fabric.env` with activation data, registry credentials, fabric ID
- All downstream scripts (08, 09, 10) auto-source from `rtf-fabric.env`

### Step 8: Install RTF Agent
```bash
./08-install-rtf.sh
```
- ~5 min
- Auto-sources credentials from `rtf-fabric.env`
- Auto-converts `license.lic` → `license.b64`
- Auto-generates `values.yaml` if not present
- Creates namespace, pull secret, installs Helm chart
- Verify: `kubectl get pods -n rtf` — all should be Running

### Step 9: Setup Ingress Phase 1 — Force ALB + Get CNAME
```bash
./09-setup-ingress-template.sh
```
- ~5 min
- Deploys keep-alive backend to force ALB creation
- Captures ALB hostname and prints CNAME record
- Non-interactive — no blocking prompts

### ⏸️ MANUAL STEP: Add DNS CNAME Record
The script prints something like:
```
Type: CNAME
Name: *.rtf (or whatever matches your subdomain)
Data: <some-alb-hostname>.elb.amazonaws.com
```
Add this record at your DNS provider. This is ONE record, one time — NOT per-app.

**Tell the user to add this CNAME record, then confirm when done.**

### Step 10: Setup Ingress Phase 2 — Apply HTTPRouteTemplate
```bash
./10-apply-ingress-template.sh
```
- ~1 min
- Run immediately after the CNAME is added (doesn't need to wait for propagation)
- Re-derives ALB hostname itself — no dependency on step 9 having just run
- Verify: `kubectl get httproutetemplates -n rtf`

### Step 11: Validate
```bash
./11-validate.sh
```
- ~2 min
- Full post-install validation
- Checks: cluster status, Auto Mode capabilities, node architecture, ALB controller, IRSA, RTF pods, HTTPRouteTemplate, keep-alive ingress, Anypoint connectivity, registry connectivity
- Look for any FAIL lines in output

---

## After Completion

Apps deployed through Anypoint Runtime Manager are reachable at:
```
http://<app-name>.<your-domain>/
```
No Host header override. No app code changes. The Ingress tab in Runtime Manager shows `http://*.<your-domain>` as an available host pattern.

---

## Key Gotchas

1. **eksctl version**: Must be 0.195.0+ — older versions silently ignore `autoModeConfig`, creating a cluster WITHOUT Auto Mode
2. **StorageClass provisioner**: `ebs.csi.eks.amazonaws.com` (NOT `ebs.csi.aws.com`)
3. **IRSA is mandatory**: Auto Mode blocks IMDS — no alternative credential path
4. **RTF is amd64-only**: Graviton nodes can't run RTF pods
5. **Keep-alive backend**: Don't delete it — it keeps the ALB alive for the wildcard CNAME
6. **Connected App scopes**: Must be assigned to the right Business Group AND Environment — missing this returns empty lists with zero error
7. **AWS SSO expiry**: Tokens expire mid-session — re-run `aws sso login` if you get `ExpiredTokenException`
8. **Delete order**: Always delete Ingress/LoadBalancer objects BEFORE deleting the cluster to avoid orphaned ALBs
9. **Don't commit rtf-config.env**: Contains real secrets — only `.example` is safe for version control

---

## File Reference

| File | Purpose |
|------|---------|
| `rtf-config.env.example` | Template — copy to `rtf-config.env` and fill in |
| `rtf-config.env` | Your credentials (git-ignored) |
| `rtf-fabric.env` | Auto-generated by 07 — activation data + registry creds |
| `rtf-automode-v3.yaml` | EKS cluster config |
| `auto-ebs-sc.yaml` | StorageClass definition |
| `amd64-nodepool.yaml` | Karpenter NodePool for RTF |
| `license.lic` | Your Mule Enterprise license (git-ignored) |
| `license.b64` | Auto-generated by 08 (git-ignored) |
| `values.yaml` | Auto-generated by 08 unless you provide one (git-ignored) |
