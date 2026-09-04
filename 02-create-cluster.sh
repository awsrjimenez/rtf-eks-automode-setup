#!/bin/bash
set -e

CONFIG_FILE=rtf-automode-v3.yaml

# autoModeConfig requires eksctl 0.195.0+. On older versions the field is
# rejected as unknown and the cluster comes up WITHOUT Auto Mode.
# https://docs.aws.amazon.com/eks/latest/userguide/automode-get-started-eksctl.html
REQUIRED_EKSCTL=0.195.0

# Cluster name and region live in exactly one place: the eksctl config file.
# eksctl reads them from there, so hardcoding them here too means a rename
# (which the README tells shared-account users to do) silently breaks the
# update-kubeconfig call below after a successful 20-minute create.
CLUSTER_NAME=$(awk '/^metadata:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/name:/{print $2;exit}' "$CONFIG_FILE")
REGION=$(awk '/^metadata:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/region:/{print $2;exit}' "$CONFIG_FILE")

if [ -z "$CLUSTER_NAME" ] || [ -z "$REGION" ]; then
  echo "ERROR: could not read metadata.name / metadata.region from $CONFIG_FILE"
  exit 1
fi
echo "Cluster: $CLUSTER_NAME  Region: $REGION  (from $CONFIG_FILE)"

echo "=== Verifying eksctl version ==="
EKSCTL_VERSION=$(eksctl version 2>/dev/null | sed 's/-.*//')
if [ "$(printf '%s\n%s\n' "$REQUIRED_EKSCTL" "$EKSCTL_VERSION" | sort -V | head -1)" != "$REQUIRED_EKSCTL" ]; then
  echo "ERROR: eksctl $EKSCTL_VERSION found, need >= $REQUIRED_EKSCTL for autoModeConfig."
  echo "Upgrade with: brew upgrade eksctl"
  exit 1
fi
echo "OK: eksctl $EKSCTL_VERSION"

echo "=== Verifying AWS credentials ==="
aws sts get-caller-identity || { echo "ERROR: AWS credentials expired - run 'aws sso login'"; exit 1; }

echo "=== Checking whether the cluster already exists ==="
# Without this, re-running after a partial failure (or on a new machine where
# only the kubeconfig is missing) hits an "already exists" error, and set -e
# aborts before kubeconfig is ever written.
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "Cluster $CLUSTER_NAME already exists - skipping create."
else
  echo "=== Creating cluster (~15-20 min) ==="
  # eksctl defaults to a 25m timeout, which is uncomfortably close to the
  # observed Auto Mode create time. On timeout the CloudFormation stack keeps
  # building, leaving the orphaned-stack mess described in README lesson 7.
  eksctl create cluster -f "$CONFIG_FILE" --timeout=40m
fi

echo "=== Updating kubeconfig ==="
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "=== Verifying Auto Mode is enabled ==="
aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query '{compute:cluster.computeConfig.enabled,loadBalancing:cluster.kubernetesNetworkConfig.elasticLoadBalancing.enabled,blockStorage:cluster.storageConfig.blockStorage.enabled}' \
  --output table

echo "=== Verifying Kubernetes API is reachable ==="
kubectl cluster-info >/dev/null 2>&1 || {
  echo "ERROR: cluster created but Kubernetes API is not reachable."
  echo "Check your EKS access entry for this IAM role."
  exit 1; }
kubectl get nodes 2>/dev/null || echo "(no nodes yet - Auto Mode provisions them on first workload)"

echo ""
echo "=== Cluster created and kubeconfig updated ==="
echo "NEXT: ./03-create-storageclass.sh (Auto Mode ships no StorageClass)"
