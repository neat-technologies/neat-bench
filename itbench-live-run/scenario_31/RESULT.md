# scenario_31 — ingress-port-blocking NetworkPolicy on frontend — INVALID (fault inert on this cluster)
groundtruth: Deployment frontend (via NetworkPolicy frontend-ingress)
FINDING: KinD's default CNI (kindnet) does NOT enforce NetworkPolicies -> the injected netpol is INERT. Both arms empirically confirmed storefront returns 200 through frontend-proxy; netpol has no effect. NOT a NEAT result. Netpol/istio-enforcement faults are un-runnable without a policy-enforcing CNI (Calico/Cilium). SKIP class: 31 (+ any netpol/istio-mesh fault).
