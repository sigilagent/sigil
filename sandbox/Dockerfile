# Prometheus core — sandboxed test image.
# The crystallized agents AUTHOR AND RUN arbitrary model-written Python. Running that
# inside this container (not on the host) is the point: the only thing it can touch is
# the container filesystem, and the only network it needs is the model API.
FROM python:3.13-slim

# Core runtime only (no jac-client/scale/super — those are just for the Observatory UI).
# Pinned to the versions the loop is verified against.
RUN pip install --no-cache-dir \
    jaclang==0.16.7 \
    byllm==0.6.18 \
    litellm==1.82.6 \
    "mcp==1.27.2" \
    tiktoken==0.12.0 \
    PyYAML==6.0.3 \
    croniter \
    requests

# A few libs the crystallized scripts commonly reach for (extend as needed).
RUN pip install --no-cache-dir reportlab openpyxl || true

WORKDIR /app
COPY . /app
RUN chmod +x sandbox/entrypoint.sh

# non-root: the model-written script runs as this user, with no host access
RUN useradd -m runner && mkdir -p /app/out && chown -R runner /app
USER runner

# the whole test sequence runs in ONE container so the session persists
ENTRYPOINT ["bash", "sandbox/entrypoint.sh"]
CMD ["write a haiku about the ocean and save it to haiku.txt"]
