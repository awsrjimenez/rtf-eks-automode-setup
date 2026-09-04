#!/bin/bash
set -e

CLUSTER_NAME=rtf-automode-poc
REGION=us-east-1

echo "=== Verifying AWS credentials ==="
aws sts get-caller-identity || { echo "ERROR: AWS credentials expired - run 'aws sso login'"; exit 1; }

echo "=== Associating IAM OIDC provider (required for IRSA) ==="
eksctl utils associate-iam-oidc-provider \
  --region=$REGION \
  --cluster=$CLUSTER_NAME \
  --approve

echo "=== OIDC provider associated ==="
