# Box-local shim: the upstream image ships Java 11, whose cgroup v2 reader throws on this kernel
# and kills the broker at startup. Same broker, container detection off. Upstream kept as :2023.5-upstream.
FROM hivemq/hivemq-ce:2023.5-upstream
ENV JAVA_TOOL_OPTIONS=-XX:-UseContainerSupport
