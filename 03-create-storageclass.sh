#!/bin/bash
set -e

SC_NAME=auto-ebs-sc
PROVISIONER=ebs.csi.eks.amazonaws.com

# EKS Auto Mode enables the block storage capability but does NOT create a
# StorageClass for you. Without one, every PVC (RTF's and any Mule app's)
# stays Pending. See:
# https://docs.aws.amazon.com/eks/latest/userguide/create-storage-class.html

echo "=== Verifying cluster connectivity ==="
kubectl cluster-info >/dev/null 2>&1 || {
  echo "ERROR: cannot reach the cluster."
  echo "Run: aws eks update-kubeconfig --name <cluster-name> --region <region>"
  exit 1
}

echo "=== Verifying Auto Mode block storage capability is live ==="
if kubectl get csidriver "$PROVISIONER" >/dev/null 2>&1; then
  echo "OK: CSI driver $PROVISIONER is registered"
else
  echo "ERROR: CSI driver $PROVISIONER not found."
  echo "storageConfig.blockStorage is not enabled on this cluster, or Auto Mode is off."
  echo "Check: aws eks describe-cluster --name <cluster-name> --region <region> \\"
  echo "         --query cluster.storageConfig"
  exit 1
fi

echo "=== Checking for a conflicting default StorageClass ==="
# Two classes both marked default is an error state - Kubernetes picks
# arbitrarily and PVC behaviour becomes non-deterministic.
EXISTING_DEFAULT=$(kubectl get storageclass --no-headers 2>/dev/null \
  | awk '/\(default\)/ {print $1}' \
  | grep -v "^${SC_NAME}$" || true)

if [ -n "$EXISTING_DEFAULT" ]; then
  echo "WARNING: another StorageClass is already marked default:"
  echo "$EXISTING_DEFAULT" | sed 's/^/  - /'
  echo "Applying $SC_NAME would leave two default classes."
  echo "Remove the annotation from the other class first:"
  echo "  kubectl patch storageclass <name> -p \\"
  echo "    '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"false\"}}}'"
  exit 1
fi

echo "=== Applying StorageClass $SC_NAME ==="
kubectl apply -f auto-ebs-sc.yaml

echo "=== Verifying ==="
ACTUAL_PROVISIONER=$(kubectl get storageclass "$SC_NAME" -o jsonpath='{.provisioner}')
if [ "$ACTUAL_PROVISIONER" != "$PROVISIONER" ]; then
  echo "ERROR: $SC_NAME has provisioner '$ACTUAL_PROVISIONER', expected '$PROVISIONER'"
  exit 1
fi

kubectl get storageclass
echo ""
echo "OK: $SC_NAME created as the default class, backed by Auto Mode block storage."
echo ""
echo "NOTE: volumeBindingMode is WaitForFirstConsumer, so no EBS volume is"
echo "provisioned until a pod actually mounts a PVC. Nothing is billed yet."
