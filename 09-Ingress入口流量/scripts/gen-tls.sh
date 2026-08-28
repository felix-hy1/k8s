#!/usr/bin/env bash
# 生成自签证书并创建 kubernetes.io/tls 类型 Secret
# 用法: gen-tls.sh <域名>   (默认 demo.local,创建在 ing-lab 命名空间)
set -euo pipefail
DOMAIN=${1:-demo.local}
NS=${2:-ing-lab}

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=${DOMAIN}" \
  -addext "subjectAltName=DNS:${DOMAIN}"

kubectl create secret tls demo-tls --cert=tls.crt --key=tls.key -n "$NS" --dry-run=client -o yaml | kubectl apply -f -
rm -f tls.key tls.crt
echo "✅ Secret demo-tls 已创建(CN=${DOMAIN},有效期 365 天)"
