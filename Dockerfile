# syntax=docker/dockerfile:1.7
FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

# ---- Build/runtime deps for CPython on Debian ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl git \
    build-essential pkg-config \
    zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
    libssl-dev libffi-dev liblzma-dev \
    libncursesw5-dev tk-dev xz-utils \
    coreutils findutils wget tar \
  && rm -rf /var/lib/apt/lists/*

# ---- pyenv ----
ENV PYENV_ROOT=/opt/pyenv
ENV PATH=$PYENV_ROOT/bin:$PYENV_ROOT/shims:/usr/local/bin:$PATH
RUN git clone --depth 1 https://github.com/pyenv/pyenv.git "$PYENV_ROOT"
ENV PYTHON_CONFIGURE_OPTS="--enable-optimizations"
ENV MAKEFLAGS="-j$(nproc)"

# Preinstall multiple Python versions; override at build time
ARG PYTHON_VERSIONS="3.12.5 3.11.10"
RUN set -eux; \
    eval "$(pyenv init -)"; \
    for v in $PYTHON_VERSIONS; do pyenv install -s "$v"; done; \
    pyenv global $PYTHON_VERSIONS; \
    pyenv rehash; \
    python -VV

# ---- uv (fast installer/resolver) ----
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# ---- Runtime env knobs ----
ENV PYTHON_REQUIREMENTS=""       
ENV PYTHON_VERSION=""            
ENV COMMAND=""                   
ENV VENV_PATH="/opt/venv"
ENV SSL_CERT_DIR=/etc/ssl/certs SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# ---- Entrypoint ----
COPY <<'ENTRYPOINT_SH' /entrypoint.sh
#!/usr/bin/env bash
set -euo pipefail

export PYENV_ROOT="${PYENV_ROOT:-/opt/pyenv}"
export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:/usr/local/bin:$PATH"
eval "$(pyenv init -)"

resolve_python_version() {
  local req="${1:-}"

  # List installed CPython versions as plain numbers
  mapfile -t installed < <(pyenv versions --bare | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || true)
  if [[ "${#installed[@]}" -eq 0 ]]; then
    echo "No Python versions installed under pyenv." >&2
    return 1
  fi

  if [[ -z "$req" ]]; then
    command -v python
    return 0
  fi

  # Exact match?
  for v in "${installed[@]}"; do
    if [[ "$v" == "$req" ]]; then
      echo "$PYENV_ROOT/versions/$v/bin/python"
      return 0
    fi
  done

  # Prefix match (e.g., 3.12 -> highest 3.12.x)
  mapfile -t matches < <(printf "%s\n" "${installed[@]}" | grep -E "^${req//./\\.}(\.|$)" || true)
  if [[ "${#matches[@]}" -eq 0 ]]; then
    echo "Requested PYTHON_VERSION='$req' not found. Installed: ${installed[*]}" >&2
    return 1
  fi
  local best
  best="$(printf "%s\n" "${matches[@]}" | sort -V | tail -1)"
  echo "$PYENV_ROOT/versions/$best/bin/python"
}

main() {
  TARGET_PY="$(resolve_python_version "${PYTHON_VERSION:-}")"

  # If a specific version was requested, set PYENV_VERSION so bare 'python' uses it
  if [[ -n "${PYTHON_VERSION:-}" ]]; then
    canon_ver="$(echo "$TARGET_PY" | sed -E 's#.*/versions/([^/]+)/bin/python#\1#')"
    export PYENV_VERSION="$canon_ver"
  fi

  # If requirements provided, create a venv for the chosen interpreter and install
  if [[ -n "${PYTHON_REQUIREMENTS:-}" ]]; then
    uv venv "${VENV_PATH}" --python "${TARGET_PY}"
    export PATH="${VENV_PATH}/bin:${PATH}"
    tmpreq="$(mktemp)"
    printf "%s\n" "${PYTHON_REQUIREMENTS}" | tr ' ,;' '\n' | sed -E '/^\s*$/d' > "${tmpreq}"
    uv pip install --python "${VENV_PATH}/bin/python" -r "${tmpreq}"
    rm -f "${tmpreq}"
  fi

  if [[ -z "${COMMAND:-}" ]]; then
    echo "[info] No COMMAND provided; opening shell."
    python -V || true
    which python || true
    pyenv versions || true
    exec bash
  else
    echo "[info] Executing COMMAND: ${COMMAND}"
    exec bash -lc "${COMMAND}"
  fi
}

main "$@"
ENTRYPOINT_SH

RUN chmod +x /entrypoint.sh
SHELL ["/bin/bash", "-lc"]
ENTRYPOINT ["/entrypoint.sh"]

