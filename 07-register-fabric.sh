#!/bin/bash
set -e

# =========================================================================
# Automates Runtime Fabric registration AND environment association via
# the Anypoint Runtime Fabric API, replacing two manual UI steps:
#   1. "Runtime Manager -> Runtime Fabrics -> Create Runtime Fabric"
#   2. Associating that fabric with an Anypoint Environment
# Writes the returned activation data (and fabric ID) to rtf-fabric.env,
# which 08-install-rtf.sh, 09-setup-ingress-template.sh, and 10-apply-ingress-template.sh source
# automatically if present.
#
# Sources:
# - Fabric creation: a working example from a colleague (fabric creation
#   request/response confirmed working).
# - Environment association: confirmed via an internal support swarm
#   thread (Slack) on the same topic - see comments near that section
#   below for the two gotchas noted there.
# - Environment name->ID lookup: GET /accounts/api/organizations/{orgId}/
#   environments, corroborated by multiple independent public sources
#   (MuleSoft help articles, third-party walkthroughs) - but the exact
#   response shape (bare array vs. wrapped in "data") was inconsistent
#   across those sources, so the parsing below tries both. Defaults to
#   looking up "Sandbox" by name; override ENVIRONMENT_NAME or set
#   ENVIRONMENT_ID directly to target a different/known environment.
#
# VENDOR VALUE - NEEDS VERIFICATION: the fabric-creation example this
# script is based on used vendor: "aks" (Azure). "eks" is used below by
# the same naming convention (matching Runtime Manager's UI options:
# "Amazon Elastic Kubernetes Service" / "Azure Kubernetes Service" /
# "Google Kubernetes Engine"), but this has NOT been independently
# confirmed against the API's actual accepted enum values. Verify this
# works on first run - if the API rejects "eks", check the interactive
# API reference in Exchange for the correct value.
# =========================================================================

# =========================================================================
# CONFIGURATION - three ways to supply this, checked in this order:
#   1. Shell environment variables already exported (e.g. in your shell
#      profile) - takes precedence if set.
#   2. rtf-config.env in this directory - copy rtf-config.env.example to
#      rtf-config.env and fill it in once; reused across runs and across
#      re-downloads of this script.
#   3. The placeholder defaults below - will fail the check further down
#      if neither of the above supplied real values.
# =========================================================================
if [ -f rtf-config.env ]; then
  echo "=== Loading rtf-config.env ==="
  source rtf-config.env
fi

ORG_ID="${ORG_ID:-<your-anypoint-organization-id>}"
CLIENT_ID="${CLIENT_ID:-<connected-app-client-id>}"
CLIENT_SECRET="${CLIENT_SECRET:-<connected-app-client-secret>}"
# A Connected App with Runtime Fabric management scope is required to get
# an access token via client_credentials grant. Create one in Anypoint:
#   Access Management -> Connected Apps -> Create App -> App acts on its
#   own behalf (client credentials) -> grant it Runtime Manager /
#   Runtime Fabric scopes.
FABRIC_NAME="${FABRIC_NAME:-rtf-automode-poc}"
REGION="${REGION:-us-east-1}"
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-Sandbox}"
# Looked up by name via the Environments API and resolved to an ID
# automatically below - change this if you want a different environment
# (e.g. "Design", "Production"). Must match the environment's name
# exactly as it appears in Anypoint (case-sensitive).
ENVIRONMENT_ID="${ENVIRONMENT_ID:-}"
# Leave blank to resolve ENVIRONMENT_NAME automatically. Set this directly
# instead (a UUID, not a name) to skip the name lookup entirely - useful
# if you already know the ID or the name lookup isn't working for some
# reason.
DOMAIN="${DOMAIN:-<your-subdomain.your-domain.com>}"
# Not used by this script directly - just passed through into
# rtf-fabric.env so 09-setup-ingress-template.sh and 10-apply-ingress-template.sh can pick it up
# automatically too. Not required to run this script; only a soft
# warning is printed below if it's still a placeholder.
# =========================================================================

if [ "$ORG_ID" == "<your-anypoint-organization-id>" ] || \
   [ "$CLIENT_ID" == "<connected-app-client-id>" ] || \
   [ "$CLIENT_SECRET" == "<connected-app-client-secret>" ]; then
  echo "ERROR: ORG_ID/CLIENT_ID/CLIENT_SECRET are still placeholder values."
  echo ""
  echo "Fix this by either:"
  echo "  1. cp rtf-config.env.example rtf-config.env, then edit"
  echo "     rtf-config.env and fill in the real values, or"
  echo "  2. export ORG_ID=... CLIENT_ID=... CLIENT_SECRET=... in your"
  echo "     shell before running this script."
  exit 1
fi

if [ "$DOMAIN" == "<your-subdomain.your-domain.com>" ]; then
  echo "NOTE: DOMAIN is still a placeholder - fine for now, but set it in"
  echo "rtf-config.env before running 09-setup-ingress-template.sh later."
fi

echo "=== Requesting Anypoint access token ==="
TOKEN_RESPONSE=$(curl -s --location 'https://anypoint.mulesoft.com/accounts/api/v2/oauth2/token' \
  --header 'Content-Type: application/json' \
  --data "{
    \"grant_type\": \"client_credentials\",
    \"client_id\": \"$CLIENT_ID\",
    \"client_secret\": \"$CLIENT_SECRET\"
  }")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')

if [ -z "$ACCESS_TOKEN" ]; then
  echo "ERROR: failed to obtain access token. Response was:"
  echo "$TOKEN_RESPONSE"
  exit 1
fi
echo "Access token obtained."

if [ -z "$ENVIRONMENT_ID" ]; then
  echo "=== Resolving environment '$ENVIRONMENT_NAME' to an ID ==="
  # Endpoint: GET /accounts/api/organizations/{orgId}/environments
  # RESPONSE SHAPE UNVERIFIED AGAINST THE OFFICIAL API REFERENCE: sources
  # disagree on whether this returns a bare array or one wrapped in a
  # "data" field. The jq filter below tries both.
  ENV_RESPONSE=$(curl -s --location "https://anypoint.mulesoft.com/accounts/api/organizations/$ORG_ID/environments" \
    --header "Authorization: Bearer $ACCESS_TOKEN")

  ENVIRONMENT_ID=$(echo "$ENV_RESPONSE" | jq -r --arg name "$ENVIRONMENT_NAME" \
    '(.data // .) | (if type=="array" then . else empty end) | .[] | select(.name==$name) | .id' \
    | head -n1)

  if [ -z "$ENVIRONMENT_ID" ]; then
    echo "ERROR: could not find an environment named '$ENVIRONMENT_NAME'."
    echo "Full response (check the actual environment names/shape here):"
    echo "$ENV_RESPONSE" | jq '.' 2>/dev/null || echo "$ENV_RESPONSE"
    echo ""
    echo "Fix ENVIRONMENT_NAME at the top of this script to match an actual"
    echo "environment name exactly, or set ENVIRONMENT_ID directly instead"
    echo "to skip this lookup."
    exit 1
  fi
  echo "Resolved '$ENVIRONMENT_NAME' -> $ENVIRONMENT_ID"
else
  echo "=== Using explicitly set ENVIRONMENT_ID (skipping name lookup) ==="
fi

echo "=== Registering Runtime Fabric '$FABRIC_NAME' (vendor=eks, region=$REGION) ==="
FABRIC_RESPONSE=$(curl -s --location "https://anypoint.mulesoft.com/runtimefabric/api/organizations/$ORG_ID/fabrics" \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header 'Content-Type: application/json' \
  --data "{
    \"name\": \"$FABRIC_NAME\",
    \"vendor\": \"eks\",
    \"region\": \"$REGION\"
  }")

FABRIC_ID=$(echo "$FABRIC_RESPONSE" | jq -r '.id // empty')
ACTIVATION_DATA=$(echo "$FABRIC_RESPONSE" | jq -r '.activationData // empty')
FABRIC_STATUS=$(echo "$FABRIC_RESPONSE" | jq -r '.status // empty')

if [ -z "$FABRIC_ID" ] || [ -z "$ACTIVATION_DATA" ]; then
  echo "ERROR: fabric registration failed or response shape was unexpected."
  echo "Full response:"
  echo "$FABRIC_RESPONSE" | jq '.' 2>/dev/null || echo "$FABRIC_RESPONSE"
  echo ""
  echo "If this is a 4xx error about 'vendor', the accepted value for EKS"
  echo "may not be \"eks\" - check the interactive API reference in Exchange:"
  echo "  https://anypoint.mulesoft.com/exchange/f1e97bc6-315a-4490-82a7-23abe036327a.anypoint-platform/runtime-fabric/"
  exit 1
fi

echo "Fabric registered: id=$FABRIC_ID status=$FABRIC_STATUS"

echo "=== Writing rtf-fabric.env for 08-install-rtf.sh to source ==="

echo "=== Fetching Helm registry credentials (helmrepoproperties API) ==="
# Source: docs.mulesoft.com "Installing Runtime Fabric Using Helm" -
# GET .../runtimefabric/api/organizations/<ORG_ID>/helmrepoproperties
# CONFIRMED field names (verified against a real response on 2026-09-03):
#   RTF_IMAGE_REGISTRY_ENDPOINT, RTF_IMAGE_REGISTRY_USER,
#   RTF_IMAGE_REGISTRY_PASSWORD
HELM_PROPS_RESPONSE=$(curl -s --location "https://anypoint.mulesoft.com/runtimefabric/api/organizations/$ORG_ID/helmrepoproperties" \
  --header "Authorization: Bearer $ACCESS_TOKEN")

RTF_REGISTRY=$(echo "$HELM_PROPS_RESPONSE" | jq -r '.RTF_IMAGE_REGISTRY_ENDPOINT // empty')
REGISTRY_USER=$(echo "$HELM_PROPS_RESPONSE" | jq -r '.RTF_IMAGE_REGISTRY_USER // empty')
REGISTRY_PASS=$(echo "$HELM_PROPS_RESPONSE" | jq -r '.RTF_IMAGE_REGISTRY_PASSWORD // empty')

if [ -z "$REGISTRY_USER" ] || [ -z "$REGISTRY_PASS" ]; then
  echo "WARNING: could not extract registry credentials automatically."
  echo "Full response (field names may have changed from what's expected):"
  echo "$HELM_PROPS_RESPONSE" | jq '.' 2>/dev/null || echo "$HELM_PROPS_RESPONSE"
  echo "You will need to fill REGISTRY_USER/REGISTRY_PASS manually in"
  echo "08-install-rtf.sh instead."
  REGISTRY_USER=""
  REGISTRY_PASS=""
else
  echo "Registry credentials obtained."
fi

cat > rtf-fabric.env << EOF
# Auto-generated by 07-register-fabric.sh - do not edit by hand.
# Sourced automatically by 08-install-rtf.sh and
# 09-setup-ingress-template.sh and 10-apply-ingress-template.sh if present.
FABRIC_ID="$FABRIC_ID"
ACTIVATION_DATA="$ACTIVATION_DATA"
REGISTRY_USER="$REGISTRY_USER"
REGISTRY_PASS="$REGISTRY_PASS"
RTF_REGISTRY="$RTF_REGISTRY"
DOMAIN="$DOMAIN"
EOF
echo "Wrote rtf-fabric.env"

echo ""
echo "=== Associating fabric with environment $ENVIRONMENT_ID ==="
# Confirmed via internal support swarm thread (Slack). Two gotchas noted
# there, both handled below:
#   1. The URL's "groupId" is confusingly named - it's actually the
#      fabric's own "id" from the create-fabric response above, not a
#      separate "group" object. Using $FABRIC_ID for it is correct.
#   2. One person hit a 404 doing GET before ever doing POST - order
#      matters for a fabric that's never been associated before. This
#      script always POSTs first, so that shouldn't bite here, but keep
#      it in mind if you're troubleshooting a GET on an existing
#      association manually later.
ASSOC_RESPONSE=$(curl -s --location "https://anypoint.mulesoft.com/runtimefabric/api/organizations/$ORG_ID/groups/$FABRIC_ID/associations" \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header 'Content-Type: application/json' \
  --data "{
    \"name\": \"$FABRIC_NAME\",
    \"environmentId\": \"$ENVIRONMENT_ID\",
    \"organizationId\": \"$ORG_ID\"
  }")

ASSOC_STATUS=$(echo "$ASSOC_RESPONSE" | jq -r '.deploymentStatus // empty')
ASSOC_ID=$(echo "$ASSOC_RESPONSE" | jq -r '.id // empty')

if [ -z "$ASSOC_ID" ]; then
  echo "ERROR: environment association failed. Full response:"
  echo "$ASSOC_RESPONSE" | jq '.' 2>/dev/null || echo "$ASSOC_RESPONSE"
  echo ""
  echo "Fall back to the manual UI step if needed:"
  echo "  Runtime Manager -> Runtime Fabrics -> $FABRIC_NAME -> associate"
  echo "  with your target Environment -> Save"
  exit 1
fi

echo "Association created: id=$ASSOC_ID status=$ASSOC_STATUS"

echo "=== Verifying association (GET) ==="
VERIFY_RESPONSE=$(curl -s --location "https://anypoint.mulesoft.com/runtimefabric/api/organizations/$ORG_ID/groups/$FABRIC_ID/associations" \
  --header "Authorization: Bearer $ACCESS_TOKEN")
echo "$VERIFY_RESPONSE" | jq '.' 2>/dev/null || echo "$VERIFY_RESPONSE"

echo ""
echo "================================================================="
echo "Fabric '$FABRIC_NAME' registered and associated with environment"
echo "$ENVIRONMENT_ID. No manual UI steps remain before 08-install-rtf.sh."
echo "================================================================="
