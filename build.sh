#!/bin/sh
# Build the image. Reads non-secret defaults from .env; no credentials are
# baked in. Extra args go to docker build, e.g. ./build.sh --no-cache
# POSIX sh -- must run on hosts without bash.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Same lookup order as run.sh.
for c in "${IMMICH_ENV_FILE:-}" "$HERE/.env" "${XDG_CONFIG_HOME:-$HOME/.config}/immich/.env"; do
  if [ -n "$c" ] && [ -f "$c" ]; then
    ENV_FILE=$(CDPATH= cd -- "$(dirname -- "$c")" && pwd)/${c##*/}
    break
  fi
done
: "${ENV_FILE:?no .env found (looked beside this script and in ~/.config/immich/; or set IMMICH_ENV_FILE)}"

set -a; . "$ENV_FILE"; set +a

# "$HERE" is both the build context and where the Dockerfile lives, so no cd.
exec docker build -t "${IMMICH_IMAGE:-immich-cli}" \
  --build-arg IMMICH_URL="${IMMICH_INSTANCE_URL:?not set in .env}" \
  --build-arg UPLOAD_CONCURRENCY="${IMMICH_UPLOAD_CONCURRENCY:-6}" \
  "$@" "$HERE"