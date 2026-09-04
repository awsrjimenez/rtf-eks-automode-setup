#!/bin/bash
set -e

# =========================================================================
# Phase 2 of 2 for hostname-based ingress setup (see
# 09-setup-ingress-template.sh for phase 1, which must be run first at
# least once). Run this after adding the manual CNAME record that phase 1
# printed - immediately, or any time later.
#
# This script does NOT depend on phase 1 having *just* run - it
# re-derives the ALB hostname itself from the still-running keep-alive
# Ingress, rather than relying on any state left behind by phase 1. That
# makes it safe to run standalone, re-run to pick up template changes, or
# invoke from an automated context (e.g. a Claude skill) without needing
# to track cross-script state.
#
# Hostname-based ingress setup using RTF's HTTPRouteTemplate CRD (the
# officially recommended mechanism as of RTF 3.0.102+) plus a real,
# owned domain and ONE manually-created wildcard CNAME record.
#
# This replaces an earlier version of this runbook that hand-wrote a raw
# Kubernetes Ingress object as the RTF template, using a fake "rtf-alb"
# IngressClass purely to satisfy the AWS Load Balancer Controller's
# admission webhook, and relying on RTF's older, informal literal-string
# substitution of tokens like "app-name"/"service-name". That approach
# still works (RTF supports both old and new template styles), but
# MuleSoft's docs recommend HTTPRouteTemplate going forward:
#   https://docs.mulesoft.com/runtime-fabric/latest/configure-ingress-http-resource
#
# HTTPRouteTemplate advantages over the legacy approach:
#   - Uses the REAL ingressClassName (e.g. "alb") directly - no fake
#     placeholder IngressClass needed, since "resources" entries are
#     consumed as-is and only interpreted by RTF for its own placeholder
#     substitution, not gated by a Kubernetes admission webhook the way a
#     raw Ingress object watched by the real ALB controller would be.
#   - Uses explicit, documented Handlebars-style placeholders
#     ({{ .Host }}, {{ .Path }}, {{ .Service.Name }}, etc.) instead of
#     undocumented literal-string substitution of tokens like "app-name".
#   - Supports multiple routing resource kinds (Ingress, OpenShift Route,
#     Gateway API HTTPRoute) from one template mechanism.
#
# This is RTF's NATIVE, intended pattern: every deployed app gets its own
# subdomain (e.g. https://demo-rtf-customer-api.mulesoftdemo.com/) and
# listens unmodified at "/" - no basePath change, no URL rewrite, no app
# code changes of any kind.
#
# DNS APPROACH - MANUAL, ONE-TIME, NOT PER-APP:
# An earlier version of this runbook automated a Route 53 wildcard ALIAS
# record via NS-delegating a subdomain to Route 53. That was abandoned
# after confirming (via direct queries against the domain's own
# authoritative nameservers, with a delete-and-recreate retry) that the
# registrar used for the original demo domain (Squarespace, on top of
# Google Cloud DNS) accepts NS records in its UI but does not actually
# serve them - a real platform limitation, not a configuration mistake.
#
# The fix is simpler than the automation it replaces: since the ALB's
# hostname is STABLE across every app deployment (that's the entire point
# of the keep-alive trick in phase 1), only ONE manual DNS record is ever
# needed, created ONCE, not per-app. This is a one-time setup step
# identical in spirit to pointing a custom domain at any SaaS platform -
# it is NOT the "add a record per app" pattern that would be unreasonable
# to ask of customers. Every app deployed after this one record exists
# just works, with zero further DNS changes required.
#
# If your registrar DOES support NS delegation correctly, delegating a
# subdomain to a Route 53 hosted zone and automating the wildcard ALIAS
# record is a reasonable alternative to the manual CNAME approach here -
# see this runbook's git history for that version if needed.
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
# Must match whatever was used when running 09-setup-ingress-template.sh.
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

echo "=== Re-deriving the ALB hostname from the keep-alive Ingress ==="
# Not read from any file left behind by 09-setup-ingress-template.sh -
# queried fresh from the cluster, so this script works even if run long
# after phase 1, or without phase 1 having been run in this same session.
ALB_HOSTNAME=$(kubectl get ingress $KEEPALIVE_NAME -n $NAMESPACE \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

if [ -z "$ALB_HOSTNAME" ]; then
  echo "ERROR: could not find the ALB hostname - is the '$KEEPALIVE_NAME'"
  echo "Ingress present in the '$NAMESPACE' namespace? Run"
  echo "09-setup-ingress-template.sh first if not."
  exit 1
fi
echo "ALB hostname: $ALB_HOSTNAME"

echo "=== Checking whether the CNAME has propagated (informational only) ==="
CHECK_HOST="probe.$DOMAIN"
kubectl delete pod dns-check-ingress --ignore-not-found > /dev/null 2>&1
kubectl run dns-check-ingress --image=busybox:1.36 --restart=Never \
  --command -- nslookup "$CHECK_HOST" > /dev/null 2>&1 || true
sleep 10
RESOLVED=$(kubectl logs dns-check-ingress 2>/dev/null | grep -A1 "^Name:" || true)
kubectl delete pod dns-check-ingress --ignore-not-found > /dev/null 2>&1

if [ -z "$RESOLVED" ]; then
  echo "WARNING: $CHECK_HOST does not appear to resolve yet. The CNAME may"
  echo "still be propagating. This is informational only - proceeding to"
  echo "apply the HTTPRouteTemplate regardless, since that step doesn't"
  echo "depend on DNS. Public access to deployed apps won't work until DNS"
  echo "resolves; re-check manually later if needed:"
  echo "  kubectl run dns-check --image=busybox:1.36 --restart=Never -- nslookup $CHECK_HOST"
  echo "  kubectl logs dns-check; kubectl delete pod dns-check"
else
  echo "DNS appears to be resolving. Good."
fi

echo "=== Applying HTTPRouteTemplate (RTF's modern ingress mechanism) ==="
# Lives in the "rtf" namespace. Unlike the legacy Ingress-template
# approach, this uses the REAL ingressClassName ("alb") directly - no
# placeholder IngressClass needed. RTF's agent resolves the Handlebars
# placeholders below per-deployment based on what's chosen in Runtime
# Manager's Ingress tab (or supplied programmatically).
#
# baseEndpoints tells Runtime Manager which host patterns are available
# to choose from when configuring an app's public endpoint.
cat > rtf-http-route-template.yaml << EOF
apiVersion: rtf.mulesoft.com/v1
kind: HTTPRouteTemplate
metadata:
  name: rtf-poc-route-template
  namespace: $NAMESPACE
spec:
  baseEndpoints:
    - http://*.$DOMAIN
  resources:
    - |
      apiVersion: networking.k8s.io/v1
      kind: Ingress
      metadata:
        name: {{ .ResourceName }}
        namespace: {{ .Namespace }}
        annotations:
          alb.ingress.kubernetes.io/scheme: internet-facing
          alb.ingress.kubernetes.io/target-type: ip
          alb.ingress.kubernetes.io/group.name: $GROUP_NAME
          alb.ingress.kubernetes.io/backend-protocol: HTTP
          alb.ingress.kubernetes.io/healthcheck-path: /healthcheck
      spec:
        ingressClassName: alb
        rules:
        - host: {{ .Host }}
          http:
            paths:
            - pathType: Prefix
              path: {{ .Path }}
              backend:
                service:
                  name: {{ .Service.Name }}
                  port:
                    name: {{ .Service.PortName }}
EOF
kubectl apply -f rtf-http-route-template.yaml

echo "=== HTTPRouteTemplate applied ==="
kubectl get httproutetemplates -n $NAMESPACE

echo ""
echo "=== Setup complete ==="
echo "Apps deployed through Runtime Manager will be reachable at:"
echo "  http://<app-name-or-chosen-subdomain>.$DOMAIN/"
echo "with NO Host header override and NO app code changes needed."
echo ""
echo "STABILITY NOTE: do not delete the rtf-keepalive Ingress/Service/"
echo "Deployment in the rtf namespace - it keeps the ALB (and therefore"
echo "the CNAME's target) alive. If it's ever removed and the ALB is torn"
echo "down, re-run 09-setup-ingress-template.sh to force a new one, update"
echo "the CNAME record to the new ALB hostname, then re-run this script."
echo ""
echo "NOTE: this is HTTP only for now. For a customer-facing demo, add TLS"
echo "by importing/issuing a wildcard ACM certificate for *.$DOMAIN, adding"
echo "a 'tls:' block referencing a Kubernetes TLS secret to the Ingress"
echo "resource above, and switching baseEndpoints to https://*.$DOMAIN."
