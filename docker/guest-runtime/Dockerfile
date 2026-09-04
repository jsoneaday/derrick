# Offline guest runtime for script_exec and plugin.invoke (Python primary).
# Build: docker build -f docker/guest-runtime/Dockerfile -t derrick-guest-runtime:python-v1 .
FROM python:3.14.7

RUN useradd --create-home --uid 10001 guest

# uv — fast, lockfile-friendly dependency installs inside the guest image.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /home/guest
USER guest

# Guests run with --network none; deps are baked into the image or installed at build time.
ENV UV_LINK_MODE=copy \
    PYTHONUNBUFFERED=1
