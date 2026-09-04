#!/bin/bash
set -e

# =========================================================================
# Phase 1 of 2 for hostname-based ingress setup (see 10-apply-ingress-
# template.sh for phase 2). Split into two non-interactive scripts so
# this can be invoked from an automated context (e.g. a Claude skill)
# without ever blocking on a terminal prompt - the previous single-script
# version paused with `read -p` waiting for a human to confirm the CNAME
# record had been added, which hangs indefinitely outside a real
# interactive shell.
#
# This script: forces the ALB into existence via a permanent "keep-alive"
# backend, captures its hostname, and prints the one-time manual CNAME
# record to add - then EXITS. It does not apply the HTTPRouteTemplate.
#
# Run 10-apply-ingress-template.sh next, after the CNAME record has been
# added (immediately, or after enough time has passed for it to
# propagate - that script re-derives everything it needs itself rather
# than depending on state left behind by this one, so it's safe to run
# any time after this script completes, including much later).
#
# See 10-apply-ingress-template.sh's header comment for the full
# background on why HTTPRouteTemplate + a real domain + one manual CNAME
# is the recommended approach here (RTF's native pattern, zero Mule app
# changes) versus the legacy Ingress-template/path-based alternatives
# investigated earlier in this runbook's history.
# =========================================================================

# =========================================================================
# CONFIGURATION - checked in this order:
#   1. rtf-fabric.env, if 07-register-fabric.sh was run (auto-provides
#      DOMAIN if you set it in rtf-config.env beforehand).
#   2. The placeholder default below - edit directly if you're skipping
#      07-register-fabric.sh.
# =========================================================================
NAMESPACE=rtf
GROUP_NAME=rtf-poc-group
KEEPALIVE_NAME=rtf-keepalive
DOMAIN="<your-subdomain.your-domain.com>"
# Must be a domain (or subdomain) you own and can add DNS records for.
# A subdomain (e.g. "rtf.yourcompany.com") is recommended over a bare root
# domain (e.g. "yourcompany.com") if that domain is shared with other
# services - see lesson 9 in README.md for why. Example used throughout
# this runbook's documentation: rtf.mulesoftdemo.com
# =========================================================================

if [ -f rtf-fabric.env ]; then
  echo "=== Found rtf-fabric.env from 07-register-fabric.sh - checking for DOMAIN ==="
  source rtf-fabric.env
  if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "<your-subdomain.your-domain.com>" ]; then
    echo "Using DOMAIN from rtf-fabric.env: $DOMAIN"
  else
    echo "DOMAIN not set in rtf-fabric.env - falling back to the placeholder"
    echo "above. Set DOMAIN in rtf-config.env and re-run"
    echo "07-register-fabric.sh, or edit DOMAIN directly in this script."
    DOMAIN="<your-subdomain.your-domain.com>"
  fi
fi

if [ "$DOMAIN" == "<your-subdomain.your-domain.com>" ]; then
  echo "ERROR: DOMAIN is still the placeholder value. Either set DOMAIN in"
  echo "rtf-config.env and re-run 07-register-fabric.sh, or edit the top"
  echo "of this script and set it directly before running."
  exit 1
fi

echo "=== Verifying AWS credentials ==="
aws sts get-caller-identity || { echo "ERROR: AWS credentials expired - run 'aws sso login'"; exit 1; }

echo "=== Ensuring rtf namespace exists ==="
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

echo "=== Confirming httproutetemplates CRD is installed ==="
# Installed automatically by the RTF Helm chart when global.crds.install
# is true in values.yaml (the default in the values.yaml downloaded from
# Anypoint). If this fails, confirm 08-install-rtf.sh completed
# successfully first.
kubectl get crd httproutetemplates.rtf.mulesoft.com

echo "=== Deploying keep-alive backend (forces ALB creation, stays up permanently) ==="
cat > rtf-keepalive.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $KEEPALIVE_NAME
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $KEEPALIVE_NAME
  template:
    metadata:
      labels:
        app: $KEEPALIVE_NAME
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: $KEEPALIVE_NAME
  namespace: $NAMESPACE
spec:
  selector:
    app: $KEEPALIVE_NAME
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $KEEPALIVE_NAME
  namespace: $NAMESPACE
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/group.name: $GROUP_NAME
    alb.ingress.kubernetes.io/backend-protocol: HTTP
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /rtf-keepalive
        pathType: Prefix
        backend:
          service:
            name: $KEEPALIVE_NAME
            port:
              number: 80
EOF
kubectl apply -f rtf-keepalive.yaml

echo "=== Waiting for ALB to provision (up to 5 min) ==="
ALB_HOSTNAME=""
for i in $(seq 1 30); do
  ALB_HOSTNAME=$(kubectl get ingress $KEEPALIVE_NAME -n $NAMESPACE \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -n "$ALB_HOSTNAME" ]; then
    break
  fi
  echo "  ...still waiting ($i/30)"
  sleep 10
done

if [ -z "$ALB_HOSTNAME" ]; then
  echo "ERROR: ALB hostname did not appear after 5 minutes."
  echo "Check controller logs:"
  echo "  kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50"
  exit 1
fi

echo "ALB hostname captured: $ALB_HOSTNAME"

# Derive the CNAME "Name" field from DOMAIN: if DOMAIN has more than two
# labels (e.g. "rtf.mulesoftdemo.com"), it's a subdomain of a root domain
# and the record name is "*.<first label>" (e.g. "*.rtf"). If DOMAIN is
# itself a bare root domain (e.g. "mulesoftdemo.com"), the record name is
# just "*".
LABEL_COUNT=$(echo "$DOMAIN" | awk -F. '{print NF}')
if [ "$LABEL_COUNT" -gt 2 ]; then
  CNAME_NAME="*.$(echo "$DOMAIN" | cut -d. -f1)"
else
  CNAME_NAME="*"
fi

echo ""
echo "================================================================="
echo "MANUAL DNS STEP REQUIRED (one-time only, not per-app):"
echo ""
echo "  In your DNS provider, add:"
echo "    Type: CNAME"
echo "    Name: $CNAME_NAME"
echo "    Data: $ALB_HOSTNAME"
echo ""
echo "This ALB hostname is STABLE as long as rtf-keepalive is not deleted -"
echo "this is genuinely a one-time step, not something to repeat per app."
echo ""
echo "Once the CNAME record above has been added, run:"
echo "  ./10-apply-ingress-template.sh"
echo "================================================================="
