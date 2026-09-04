#!/bin/bash
set -e

echo "=== Adding amd64 NodePool (RTF requires amd64; Auto Mode defaults to arm64/Graviton) ==="
kubectl apply -f amd64-nodepool.yaml

echo "=== Node pools ==="
kubectl get nodepools
