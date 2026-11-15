# Paperless-ngx 2.15.3 + NEAT's Python attachment (adapted from paperless-Dockerfile).
# UNVALIDATED: 2.15.3 base image layout differs from 3.4.2 (granian vs gunicorn s6 webserver).
# The only delta from upstream: neat-otel + the OTel instrumentations Paperless's stack needs,
# auto-instrumented through sitecustomize on PYTHONPATH. Unlike the 3.4.2 Dockerfile, PYTHONPATH's
# site-packages segment is NOT baked in (python3.14 was hard-coded there and is wrong for 2.15.3);
# the harness derives it at run time from /neat-otel-autopath (see paperless-fresh.sh).
FROM ghcr.io/paperless-ngx/paperless-ngx:2.15.3
COPY python/neat-otel /tmp/neat-otel
# pip-audit is baked IN (the host has no pip + PEP 668); the grader docker-exec's it at grade time as
# the INDEPENDENT PyPI cross-check against the live checkout lock (OSV host-query stays PRIMARY).
RUN uv pip install --system --no-cache --prerelease=allow /tmp/neat-otel \
      opentelemetry-instrumentation-django opentelemetry-instrumentation-asgi \
      opentelemetry-instrumentation-psycopg opentelemetry-instrumentation-redis \
      opentelemetry-instrumentation-celery opentelemetry-instrumentation-requests \
      opentelemetry-instrumentation-httpx \
      pip-audit \
 && python3 -c "import opentelemetry.instrumentation.auto_instrumentation as a, os; print(os.path.dirname(a.__file__))" > /neat-otel-autopath
# Settings module is named up front (the Django instrumentor touches settings from sitecustomize,
# before the script dir is on sys.path). PYTHONPATH's site-packages segment is injected at run time.
ENV DJANGO_SETTINGS_MODULE=paperless.settings
