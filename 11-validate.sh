#!/bin/bash
CONFIG_FILE="$(dirname "$0")/rtf-automode-v3.yaml"
CLUSTER_NAME=$(awk '/^metadata:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/name:/{print $2;exit}' "$CONFIG_FILE")
REGION=$(awk '/^metadata:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/region:/{print $2;exit}' "$CONFIG_FILE")

if [ -z "$CLUSTER_NAME" ] || [ -z "$REGION" ]; then
  echo "ERROR: could not read metadata.name / metadata.region from $CONFIG_FILE"
  exit 1
fi

echo "=== 1. Cluster Status ==="
aws eks describe-cluster \
  --name $CLUSTER_NAME --region $REGION \
  --query "cluster.status" --output text

echo "=== 2. Auto Mode Compute ==="
aws eks describe-cluster \
  --name $CLUSTER_NAME --region $REGION \
  --query "cluster.computeConfig"

echo "=== 3. ALB Enabled ==="
aws eks describe-cluster \
  --name $CLUSTER_NAME --region $REGION \
  --query "cluster.kubernetesNetworkConfig.elasticLoadBalancing"

echo "=== 4. Node Pools ==="
kubectl get nodepools

echo "=== 5. IngressClasses (expect 'alb' only - no 'rtf-alb' needed with HTTPRouteTemplate) ==="
kubectl get ingressclass

echo "=== 6. Storage Classes (expect a default class using ebs.csi.eks.amazonaws.com) ==="
# Auto Mode does NOT ship a StorageClass - without one, every PVC stays Pending.
kubectl get storageclass
AUTO_SC=$(kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.provisioner}{"\n"}{end}' 2>/dev/null \
  | awk '$2=="ebs.csi.eks.amazonaws.com" {print $1}')
if [ -z "$AUTO_SC" ]; then
  echo "FAIL: no StorageClass uses ebs.csi.eks.amazonaws.com - run ./03-create-storageclass.sh"
elif ! kubectl get storageclass --no-headers 2>/dev/null | grep -q '(default)'; then
  echo "FAIL: found Auto Mode StorageClass ($AUTO_SC) but no class is marked default -"
  echo "      PVCs that omit storageClassName will stay Pending"
else
  echo "OK: Auto Mode StorageClass present ($AUTO_SC) and a default class is set"
fi

echo "=== 6b. Auto Mode block storage capability ==="
kubectl get csidriver ebs.csi.eks.amazonaws.com >/dev/null 2>&1 \
  && echo "OK: CSI driver ebs.csi.eks.amazonaws.com registered" \
  || echo "FAIL: CSI driver missing - storageConfig.blockStorage not enabled"

echo "=== 7. Node Architecture (expect both amd64 and arm64) ==="
kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.architecture}'
echo ""

echo "=== 8. ALB Controller Pods ==="
kubectl get pods -n kube-system | grep aws-load-balancer

echo "=== 9. ALB Controller - checking for credential errors ==="
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50 | grep -i "IMDS\|credential" && echo "WARNING: credential errors found - check IRSA setup" || echo "No credential errors - IRSA working"

echo "=== 10. RTF Pods ==="
kubectl get pods -n rtf 2>/dev/null || echo "rtf namespace not found - has 08-install-rtf.sh run?"

echo "=== 11. HTTPRouteTemplate (RTF's ingress mechanism - expect rtf-poc-route-template) ==="
kubectl get httproutetemplates -n rtf 2>/dev/null \
  || echo "FAIL: no HTTPRouteTemplate found - run 09-setup-ingress-template.sh then 10-apply-ingress-template.sh"

echo "=== 11b. Keep-alive Ingress (host should show a real *.elb.amazonaws.com hostname) ==="
kubectl get ingress rtf-keepalive -n rtf 2>/dev/null \
  || echo "FAIL: rtf-keepalive Ingress not found - run 09-setup-ingress-template.sh"

echo "=== 12. Anypoint Connectivity ==="
kubectl run connectivity-test \
  --image=curlimages/curl \
  --restart=Never \
  --command -- curl -s -o /dev/null -w "%{http_code}" \
  https://anypoint.mulesoft.com
sleep 5
kubectl logs connectivity-test
kubectl delete pod connectivity-test --ignore-not-found

echo "=== 13. RTF Registry Connectivity ==="
kubectl run registry-test \
  --image=curlimages/curl \
  --restart=Never \
  --command -- curl -s -o /dev/null -w "%{http_code}" \
  https://rtf-runtime-registry.kprod.msap.io
sleep 5
kubectl logs registry-test
kubectl delete pod registry-test --ignore-not-found

echo "=== All checks complete ==="
