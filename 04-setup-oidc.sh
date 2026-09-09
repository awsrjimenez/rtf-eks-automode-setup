#!/bin/bash
set -e

CONFIG_FILE="$(dirname "$0")/rtf-automode-v3.yaml"
CLUSTER_NAME=$(awk '/^metadata:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/name:/{print $2;exit}' "$CONFIG_FILE")
REGION=$(awk '/^metadata:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/region:/{print $2;exit}' "$CONFIG_FILE")

if [ -z "$CLUSTER_NAME" ] || [ -z "$REGION" ]; then
  echo "ERROR: could not read metadata.name / metadata.region from $CONFIG_FILE"
  exit 1
fi

echo "=== Verifying AWS credentials ==="
aws sts get-caller-identity || { echo "ERROR: AWS credentials expired - run 'aws sso login'"; exit 1; }

echo "=== Associating IAM OIDC provider (required for IRSA) ==="
eksctl utils associate-iam-oidc-provider \
  --region=$REGION \
  --cluster=$CLUSTER_NAME \
  --approve

echo "=== OIDC provider associated ==="
