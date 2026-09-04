#!/bin/bash
set -e

CLUSTER_NAME=rtf-automode-poc
REGION=us-east-1

echo "=== Verifying AWS credentials ==="
aws sts get-caller-identity || { echo "ERROR: AWS credentials expired - run 'aws sso login'"; exit 1; }

echo "=== Verifying kubeconfig points at the right cluster ==="
if kubectl config current-context 2>/dev/null | grep -q "$CLUSTER_NAME"; then

  echo "=== Deleting all Ingress objects (releases ALBs cleanly) ==="
  # If an ALB-backed Ingress is not deleted before the cluster, the ALB and
  # its target groups/security groups become orphaned in AWS - you keep
  # paying for them, and eksctl delete cluster can hang or fail trying to
  # delete a VPC that still has a dependent ALB/security group attached.
  kubectl delete ingress --all --all-namespaces --ignore-not-found --timeout=60s || true

  echo "=== Deleting all type=LoadBalancer Services (releases NLBs/CLBs cleanly) ==="
  kubectl get svc --all-namespaces -o json \
    | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns name; do
        echo "Deleting service $name in namespace $ns"
        kubectl delete svc "$name" -n "$ns" --ignore-not-found --timeout=60s || true
      done

  echo "=== Waiting 60s for ALB/NLB controller to finish deprovisioning ==="
  sleep 60

  echo "=== Checking for lingering PersistentVolumeClaims (EBS-backed, won't auto-delete) ==="
  kubectl get pvc --all-namespaces || true
  echo "NOTE: if any PVCs are listed above, delete them manually if you don't need the data:"
  echo "  kubectl delete pvc <name> -n <namespace>"

else
  echo "kubectl context does not point at $CLUSTER_NAME (or cluster is already gone) - skipping in-cluster cleanup"
fi

echo "=== Deleting cluster ==="
eksctl delete cluster \
  --name $CLUSTER_NAME \
  --region $REGION

echo "=== Verifying CloudFormation stack is gone ==="
aws cloudformation wait stack-delete-complete \
  --stack-name eksctl-${CLUSTER_NAME}-cluster \
  --region $REGION 2>/dev/null || echo "Stack already gone"

echo "=== Checking for orphaned ALBs/NLBs left behind (should be empty) ==="
aws elbv2 describe-load-balancers \
  --region $REGION \
  --query "LoadBalancers[?contains(LoadBalancerName, 'rtf')].{Name:LoadBalancerName,DNS:DNSName,State:State.Code}" \
  --output table

echo "=== NOTE: the following are NOT deleted by this script and persist across runs (by design) ==="
echo "  - IAM policy: AWSLoadBalancerControllerIAMPolicy (shared/reused across clusters - see 05-install-alb.sh)"
echo "  - Mule Enterprise license and Anypoint Runtime Fabric registration (delete manually in Anypoint if no longer needed)"

echo "=== Cluster fully deleted - safe to recreate ==="
