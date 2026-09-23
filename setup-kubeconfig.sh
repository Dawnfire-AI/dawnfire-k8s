#!/usr/bin/env bash
# Add the B300 training cluster to ~/.kube/config as the context "training", logging in
# through SSO (sso.dawnfire.ai), and make it the current context. Other contexts are left
# alone. Nothing here is a secret, and running it again is harmless.
#
# Needs kubectl and kubelogin:  brew install kubectl kubelogin
# On a machine with no browser: DEVICE_CODE=1 ./setup-kubeconfig.sh
set -euo pipefail

command -v kubectl >/dev/null || { echo "kubectl not found: brew install kubectl"; exit 1; }
kubectl oidc-login --help >/dev/null 2>&1 || { echo "kubelogin not found: brew install kubelogin"; exit 1; }

EXTRA=()
[[ -n "${DEVICE_CODE:-}" ]] && EXTRA=(--exec-arg=--grant-type=device-code)

kubectl config set-cluster training --server=https://training-k8s.dawnfire.ai

kubectl config set-credentials training-sso \
  --exec-api-version=client.authentication.k8s.io/v1 \
  --exec-command=kubectl \
  --exec-arg=oidc-login --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://sso.dawnfire.ai/application/o/poc-training-cluster/ \
  --exec-arg=--oidc-client-id=poc-training-cluster \
  --exec-arg=--oidc-extra-scope=groups \
  --exec-arg=--oidc-extra-scope=email \
  --exec-arg=--oidc-extra-scope=offline_access \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  --exec-interactive-mode=IfAvailable

kubectl config set-context training --cluster=training --user=training-sso --namespace=training
kubectl config use-context training

echo
echo "Done. Log in (opens your browser the first time):"
echo "  kubectl auth whoami"
