# syntax=docker/dockerfile:1.7
#
# Bookmarks — one image for local, Railway, and NixOS-with-Docker (plan todo 35).
#
# Multi-stage:
#   builder — ghcr.io/astral-sh/uv resolves the pinned uv.lock into a venv
#   runtime — python:3.12-slim + that venv + the source tree + monolith binary
#
# The project itself is deliberately NOT installed into the venv
# (--no-install-project): the runtime copies the source tree next to the venv
# and imports `app` via PYTHONPATH. app/main.py resolves ROOT from __file__,
# so templates/ + static/ live at /app/{templates,static}.
#
# EMPTY-VOLUME MECHANISM (todo 35) — pin the order:
#   PRIMARY: app/config.py creates BOOKMARKS_DB's parent dir at import time.
#            A volume mounted at /app/data shadows this image's /app/data AND
#            its build-time ownership, so the image-level chown does NOT apply
#            to the mount; the import-time mkdir runs against the live volume.
#   SECONDARY: the `mkdir -p /app/data && chown -R app:app /app/data` RUN
#            below, for the no-volume case (image-owned data dir).
#
# No SECRET_KEY or any secret is baked in — config.py reads it from the
# environment at runtime. Runs as the non-root `app` user. Snapshots use the
# monolith binary on demand; there is no always-on headless Chrome.

FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS builder

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /app

# Lock-first dependency layer: cached against pyproject.toml + uv.lock alone.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev

# Source tree + packaged assets for the runtime stage.
COPY app/ app/
COPY templates/ templates/
COPY static/ static/

FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# curl/ca-certificates for the monolith download; passwd for useradd/groupadd.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl passwd \
  && rm -rf /var/lib/apt/lists/*

# monolith binary — subprocess-on-demand full-page snapshots (no Chrome).
# Pinned GitHub release y2z/monolith v2.10.1. TARGETARCH (BuildKit build arg)
# selects the matching asset so multi-arch builds stay correct.
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) monolith_arch="x86_64" ;; \
      arm64) monolith_arch="aarch64" ;; \
      arm)   monolith_arch="armhf" ;; \
      *) echo "unsupported TARGETARCH ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL \
      "https://github.com/y2z/monolith/releases/download/v2.10.1/monolith-gnu-linux-${monolith_arch}" \
      -o /usr/local/bin/monolith; \
    chmod +x /usr/local/bin/monolith; \
    monolith --version

# Non-root runtime user — must exist before the --chown=app:app COPYs.
RUN groupadd -r app && useradd -r -g app -d /app app

# Runtime layout: venv + source tree + assets, all owned by `app`.
COPY --from=builder --chown=app:app /app/.venv /app/.venv
COPY --from=builder --chown=app:app /app/app /app/app
COPY --from=builder --chown=app:app /app/templates /app/templates
COPY --from=builder --chown=app:app /app/static /app/static

# Empty-volume mechanism, SECONDARY (non-volume case): image-owned data dir.
# The PRIMARY fix is the import-time mkdir in app/config.py.
RUN mkdir -p /app/data && chown -R app:app /app/data

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONPATH=/app \
    PORT=8000

WORKDIR /app
USER app

EXPOSE 8000

# /health is auth-exempt and side-effect-free (SELECT 1 round-trip) — probe it.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=5).status == 200 else 1)"

# Shell form so ${PORT:-8000} expands at container start (set -e PORT=...).
CMD uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}
