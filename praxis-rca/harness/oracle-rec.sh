#!/usr/bin/env bash
export KUBECONFIG=$HOME/.kube/config; export PATH=$HOME/.local/bin:$PATH
kubectl logs deploy/recommendation -n otel-demo --since=45s 2>/dev/null | grep -icE "error|exception|traceback|abort|no attribute|failed"
