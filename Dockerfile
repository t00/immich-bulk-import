# syntax=docker/dockerfile:1
#
# Reusable Immich CLI image with mTLS support and the import logic baked in.
# Build with ./build.sh; invoke with ./run.sh.
#
# No credentials are baked in. The API key and client cert are supplied at
# runtime, so this image is safe to rebuild, tag, or push.

ARG NODE_VERSION=22-alpine
FROM node:${NODE_VERSION}

# Must match your SERVER's API generation -- set IMMICH_CLI_VERSION in .env.
# CLI 3.x dropped deviceAssetId/deviceId from the upload form; an older server
# still requires them and rejects 3.x uploads with HTTP 400.
ARG CLI_VERSION=2.7.5
ARG UNDICI_VERSION=8.9.0

# Non-secret defaults from .env. .env is passed again at runtime and wins.
ARG IMMICH_URL=https://immich.example.com/api
ARG UPLOAD_CONCURRENCY=6

RUN npm i -g @immich/cli@${CLI_VERSION} && npm cache clean --force

# undici must live here rather than being installed globally: Node's ESM
# loader ignores global node_modules, so the bare "undici" import in
# mtls.mjs would not resolve.
WORKDIR /opt/immich
RUN npm i undici@${UNDICI_VERSION} --omit=dev && npm cache clean --force

COPY mtls.mjs /opt/immich/mtls.mjs
COPY verify.mjs /opt/immich/verify.mjs
COPY import-immich.sh /opt/immich/import-immich.sh
RUN chmod +x /opt/immich/import-immich.sh

# Preload that injects a client cert into Node's global fetch.
ENV NODE_OPTIONS="--import /opt/immich/mtls.mjs"

# Fixed in-container cert locations. run.sh mounts a host dir at /certs.
# Missing files mean "no mTLS" -- the preload self-disables, so the image
# works unchanged against a plain non-mTLS server.
ENV IMMICH_CLIENT_CERT=/certs/client.crt \
    IMMICH_CLIENT_KEY=/certs/client.key \
    IMMICH_CA_CERT=/certs/ca.crt

ENV IMMICH_INSTANCE_URL=${IMMICH_URL}
# The CLI's real default is 1, which is painfully slow for a bulk import.
ENV IMMICH_UPLOAD_CONCURRENCY=${UPLOAD_CONCURRENCY}
ENV IMMICH_INCLUDE_HIDDEN=false

WORKDIR /import
ENTRYPOINT ["/opt/immich/import-immich.sh"]
