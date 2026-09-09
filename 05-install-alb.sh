#!/bin/bash
set -e

CONFIG_FILE="$(dirname "$0")/rtf-automode-v3.yaml"
CLUSTER_NAME=$(awk '/^metadata:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/name:/{print $2;exit}' "$CONFIG_FILE")
REGION=$(awk '/^metadata:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/region:/{print $2;exit}' "$CONFIG_FILE")

if [ -z "$CLUSTER_NAME" ] || [ -z "$REGION" ]; then
  echo "ERROR: could not read metadata.name / metadata.region from $CONFIG_FILE"
  exit 1
fi
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

echo "=== Patching IAM policy (adding DescribeListenerAttributes for ALB controller v3.5+) ==="
# The upstream iam_policy.json from kubernetes-sigs is missing
# elasticloadbalancing:DescribeListenerAttributes, which was added as a
# required API call in ALB controller v3.5+. Without it, the controller
# enters a reconciliation loop (403 AccessDenied) and never populates the
# Ingress hostname. This patch adds it idempotently.
DEFAULT_VER=$(aws iam get-policy --policy-arn $POLICY_ARN --query 'Policy.DefaultVersionId' --output text)
aws iam get-policy-version --policy-arn $POLICY_ARN --version-id $DEFAULT_VER \
  --query 'PolicyVersion.Document' > /tmp/alb-policy-current.json

NEEDS_PATCH=$(python3 -c "
import json
policy = json.load(open('/tmp/alb-policy-current.json'))
found = any('DescribeListenerAttributes' in str(s.get('Action','')) for s in policy.get('Statement',[]))
print('no' if found else 'yes')
")

if [ "$NEEDS_PATCH" = "yes" ]; then
  python3 -c "
import json
policy = json.load(open('/tmp/alb-policy-current.json'))
for stmt in policy.get('Statement', []):
    actions = stmt.get('Action', [])
    if isinstance(actions, list) and any('DescribeListener' in a for a in actions):
        actions.append('elasticloadbalancing:DescribeListenerAttributes')
        break
json.dump(policy, open('/tmp/alb-policy-patched.json','w'), indent=2)
"
  # Delete oldest non-default version if at the 5-version limit
  OLDEST=$(aws iam list-policy-versions --policy-arn $POLICY_ARN \
    --query 'Versions[?!IsDefaultVersion].VersionId | [0]' --output text)
  if [ "$OLDEST" != "None" ] && [ -n "$OLDEST" ]; then
    aws iam delete-policy-version --policy-arn $POLICY_ARN --version-id $OLDEST 2>/dev/null || true
  fi
  aws iam create-policy-version --policy-arn $POLICY_ARN \
    --policy-document file:///tmp/alb-policy-patched.json --set-as-default
  echo "Patched: added DescribeListenerAttributes"
else
  echo "Policy already includes DescribeListenerAttributes, no patch needed."
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
