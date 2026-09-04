#!/bin/bash
set -e

CLUSTER_NAME=rtf-automode-poc
REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"

echo "=== Verifying AWS credentials ==="
aws sts get-caller-identity || { echo "ERROR: AWS credentials expired - run 'aws sso login'"; exit 1; }

echo "=== Getting VPC ID ==="
VPC_ID=$(aws eks describe-cluster \
  --name $CLUSTER_NAME --region $REGION \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)
echo "VPC: $VPC_ID"

echo "=== Checking for existing IAM policy ==="
if ! aws iam get-policy --policy-arn $POLICY_ARN >/dev/null 2>&1; then
  echo "Creating IAM policy..."
  curl -s -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
  aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json
else
  echo "IAM policy already exists, skipping creation."
fi

echo "=== Creating IRSA service account ==="
# NOTE: Requires OIDC provider to already be associated (run 04-setup-oidc.sh first)
# NOTE: EKS Auto Mode blocks pod-level IMDS access, so the node role alone is NOT
#       sufficient - IRSA is required for the ALB controller to authenticate to AWS.
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=$POLICY_ARN \
  --approve \
  --override-existing-serviceaccounts

echo "=== Adding Helm repo ==="
helm repo add eks https://aws.github.io/eks-charts
helm repo update

echo "=== Installing ALB controller (serviceAccount.create=false since IRSA already created it) ==="
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$REGION \
  --set vpcId=$VPC_ID

echo "=== Waiting for controller rollout ==="
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system

echo "=== IngressClass ==="
kubectl get ingressclass

echo "=== Controller logs (checking for IMDS/credential errors) ==="
sleep 10
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=20 | grep -i error || echo "No errors found - clean startup"
