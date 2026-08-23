#!/usr/bin/env bash
export KUBECONFIG=$HOME/.kube/config; export PATH=$HOME/.local/bin:$PATH
# symptom = recommendation emits products_list / AttributeError; cleared = 0 over window
kubectl logs deploy/recommendation -n otel-demo --since=45s 2>/dev/null | grep -cE "products_list|has no attribute|ListRecommendations.*[Ee]rror"
