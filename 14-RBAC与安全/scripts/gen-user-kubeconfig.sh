#!/usr/bin/env bash
# 基于 ServiceAccount 生成受限 kubeconfig(交付给第三方/开发者的只读凭证)
# 用法: gen-user-kubeconfig.sh <namespace> <serviceaccount> [有效期]
set -euo pipefail
NS=${1:-rbac-lab}
SA=${2:-pod-reader}
DURATION=${3:-24h}

SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
TOKEN=$(kubectl create token -n "$NS" "$SA" --duration="$DURATION")
OUT="${SA}.kubeconfig"

cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: kind-k8s-learning
  cluster:
    server: ${SERVER}
    certificate-authority-data: ${CA}
contexts:
- name: ${SA}@kind
  context:
    cluster: kind-k8s-learning
    user: ${SA}
    namespace: ${NS}
current-context: ${SA}@kind
users:
- name: ${SA}
  user:
    token: ${TOKEN}
EOF

echo "✅ 已生成 ${OUT}(身份: system:serviceaccount:${NS}:${SA},有效期 ${DURATION})"
echo "   验证: kubectl --kubeconfig ${OUT} get pods -n ${NS}"
