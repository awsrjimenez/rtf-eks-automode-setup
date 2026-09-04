#!/bin/bash
set -e

# =========================================================================
# FALLBACK VALUES - overridden automatically below if rtf-fabric.env
# exists (written by 07-register-fabric.sh). Only edit these directly if
# you're skipping 07-register-fabric.sh and doing fabric registration
# manually via Runtime Manager's UI instead.
# =========================================================================
NAMESPACE=rtf
ACTIVATION_DATA="<your-activation-data-from-anypoint>"
RTF_REGISTRY=rtf-runtime-registry.kprod.msap.io
RTF_VERSION=3.0.277
REGISTRY_USER="<your-registry-username>"
REGISTRY_PASS="<your-registry-password>"
# license.b64 must exist in this directory:
#   base64 -i license.lic | tr -d '\n' > license.b64
# =========================================================================

if [ -f rtf-fabric.env ]; then
  echo "=== Found rtf-fabric.env from 07-register-fabric.sh - using it ==="
  source rtf-fabric.env
  if [ -n "$REGISTRY_USER" ] && [ -n "$REGISTRY_PASS" ]; then
    echo "Using auto-fetched ACTIVATION_DATA, RTF_REGISTRY, and registry credentials."
  else
    echo "ACTIVATION_DATA/RTF_REGISTRY auto-fetched, but registry credentials"
    echo "were not - fill REGISTRY_USER/REGISTRY_PASS in manually above."
  fi
else
  echo "=== No rtf-fabric.env found - using manual placeholders above ==="
  echo "(run 07-register-fabric.sh first to automate this, or fill in the"
  echo "placeholders in this script's FALLBACK VALUES section manually)"
fi

echo "=== Verifying AWS credentials ==="
aws sts get-caller-identity || { echo "ERROR: AWS credentials expired - run 'aws sso login'"; exit 1; }

if [ "$ACTIVATION_DATA" == "<your-activation-data-from-anypoint>" ]; then
  echo "ERROR: ACTIVATION_DATA is still a placeholder. Either run"
  echo "./07-register-fabric.sh first, or fill in the FALLBACK VALUES"
  echo "section at the top of this script manually."
  exit 1
fi

if [ ! -f license.b64 ]; then
  if [ -f license.lic ]; then
    echo "license.b64 not found but license.lic is present - generating it..."
    base64 -i license.lic | tr -d '\n' > license.b64
    echo "Generated license.b64."
  else
    echo "ERROR: neither license.b64 nor license.lic found in this directory."
    echo "Place your Mule Enterprise license file (license.lic) here and re-run,"
    echo "or generate license.b64 yourself: base64 -i license.lic | tr -d '\n' > license.b64"
    exit 1
  fi
fi
MULE_LICENSE=$(cat license.b64)

echo "=== Step 1: Creating RTF namespace ==="
kubectl create ns $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

echo "=== Step 2: Creating pull secret ==="
kubectl create secret docker-registry rtf-pull-secret \
  --namespace $NAMESPACE \
  --docker-server=$RTF_REGISTRY \
  --docker-username=$REGISTRY_USER \
  --docker-password=$REGISTRY_PASS \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== Step 3: Adding RTF Helm repo ==="
helm repo add rtf https://$RTF_REGISTRY/charts \
  --username $REGISTRY_USER \
  --password $REGISTRY_PASS \
  --force-update
helm repo update

echo "=== Step 4: Preparing values.yaml ==="
if [ -f values.yaml ]; then
  echo "Found existing values.yaml (manually downloaded) - using it as the base."
  cp values.yaml values-filled.yaml
  sed -i '' "s|activationData: \*\*\*|activationData: $ACTIVATION_DATA|g" values-filled.yaml
  sed -i '' "s|muleLicense:|muleLicense: $MULE_LICENSE|g" values-filled.yaml
else
  echo "No values.yaml found - generating one automatically instead of"
  echo "requiring a manual download from Anypoint."
  echo ""
  echo "Source: MuleSoft's official 'Installing Runtime Fabric Using Helm'"
  echo "Values.yml Reference and Optional Parameters table -"
  echo "https://docs.mulesoft.com/runtime-fabric/latest/install-helm - not"
  echo "a guess. All required fields (activationData, muleLicense,"
  echo "rtfRegistry, pullSecretName) are populated from values this runbook"
  echo "already automated (07-register-fabric.sh / license.b64)."
  echo ""
  echo "If your fabric needs OPTIONAL parameters not covered here"
  echo "(authorizedNamespaces: true, fipsEnabled, a custom proxy,"
  echo "nodeWatcherEnabled/deploymentRateLimitPerSecond overrides, etc.),"
  echo "download the real values.yaml from Anypoint Runtime Manager ->"
  echo "Runtime Fabrics -> Helm install method and place it in this"
  echo "directory instead - a real downloaded file, if present, always"
  echo "takes precedence over this generated one (see the check above)."
  cat > values-filled.yaml << EOF
activationData: $ACTIVATION_DATA
proxy:
  http_proxy:
  http_no_proxy:
  monitoring_proxy:
muleLicense: $MULE_LICENSE
customLog4jEnabled: false
global:
  crds:
    install: true
  authorizedNamespaces: false
  image:
    rtfRegistry: $RTF_REGISTRY
    pullSecretName: rtf-pull-secret
  containerLogPaths:
  - /var/lib/docker/containers
  - /var/log/containers
  - /var/log/pods
EOF
  echo "Generated values-filled.yaml."
fi

echo "=== Step 5: Installing RTF agent ==="
helm upgrade --install runtime-fabric rtf/rtf-agent \
  -f values-filled.yaml \
  --version $RTF_VERSION \
  -n $NAMESPACE

echo "=== Step 6: Watching rollout ==="
kubectl rollout status deployment -n $NAMESPACE --timeout=600s

echo "=== RTF Pod Status ==="
kubectl get pods -n rtf

echo "=== RTF Events ==="
kubectl get events -n rtf --sort-by='.lastTimestamp' | tail -20
