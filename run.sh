#!/bin/sh
# Import photos into Immich. The LAST argument is the photo directory;
# everything before it is forwarded to import-immich.sh inside the image.
# POSIX sh -- must run on hosts without bash (Alpine, minimal NAS/LXC).
#
#   ./run.sh /srv/photos                 # DRY RUN, album = top-level subdir
#   ./run.sh --go /srv/photos            # do it
#   ./run.sh --flat --go ./photos        # album = each file's parent dir
#   ./run.sh --go -- --ignore '**/Raw/**' /srv/photos
#   ./run.sh --verify /srv/photos        # report which files are NOT on server
#   ./run.sh --check                     # test url + key + mTLS, no dir needed
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

usage() {
  echo "usage: $0 [--go] [--flat] [-- <immich flags>] <photo-dir>" >&2
  echo "       $0 --verify <photo-dir>" >&2
  echo "       $0 --check" >&2
  exit 1
}
[ $# -gt 0 ] || usage

# Split off the last positional: POSIX has no ${!#}, so rotate the args.
n=$#; i=1; SRC_IN=
while [ $i -le $n ]; do
  a=$1; shift
  if [ $i -eq $n ]; then SRC_IN=$a; else set -- "$@" "$a"; fi
  i=$((i + 1))
done

# A flag in last position means no directory was given -- only OK for --check.
case $SRC_IN in
  -*)
    set -- "$@" "$SRC_IN"
    SRC_IN=
    ok=0
    for a in "$@"; do
      if [ "$a" = "--check" ]; then ok=1; break; fi
    done
    if [ "$ok" -ne 1 ]; then
      echo "error: last argument must be the photo directory" >&2
      usage
    fi
    ;;
esac

# .env can live anywhere. cwd is deliberately NOT searched: unrelated projects
# commonly have a .env, and this file gets sourced. Use IMMICH_ENV_FILE.
for c in "${IMMICH_ENV_FILE:-}" "$HERE/.env" "${XDG_CONFIG_HOME:-$HOME/.config}/immich/.env"; do
  if [ -n "$c" ] && [ -f "$c" ]; then
    ENV_FILE=$(CDPATH= cd -- "$(dirname -- "$c")" && pwd)/${c##*/}
    break
  fi
done
: "${ENV_FILE:?no .env found (looked beside this script and in ~/.config/immich/; or set IMMICH_ENV_FILE)}"

set -a; . "$ENV_FILE"; set +a

# docker -v demands an absolute path and won't expand ~. $2 is the base a
# relative path resolves against.
abs() {
  p=$1
  case $p in "~/"*) p="$HOME/${p#\~/}" ;; esac
  case $p in /*) ;; *) p="$2/$p" ;; esac
  (CDPATH= cd -- "$p" 2>/dev/null && pwd)
}

# No arrays in POSIX sh: prepend the image name, then each mount, so the final
# order is `docker run <opts> <mounts> <image> <args>`.
set -- "${IMMICH_IMAGE:-immich-cli}" "$@"

if [ -n "${IMMICH_CERT_DIR:-}" ]; then
  # From .env, so relative resolves against the .env's directory.
  if ! CERTS=$(abs "$IMMICH_CERT_DIR" "${ENV_FILE%/*}"); then
    echo "error: no such directory: $IMMICH_CERT_DIR" >&2; exit 1
  fi
  set -- -v "$CERTS:/certs:ro" "$@"
fi

if [ -n "$SRC_IN" ]; then
  # Typed on the command line, so relative resolves against the cwd.
  if ! SRC=$(abs "$SRC_IN" "$PWD"); then
    echo "error: no such directory: $SRC_IN" >&2; exit 1
  fi
  set -- -v "$SRC:/import:ro" "$@"
fi

# -t without a terminal (cron, CI) makes docker refuse to start.
if [ -t 0 ]; then TTY=-it; else TTY=; fi

exec docker run --rm --init $TTY --env-file "$ENV_FILE" "$@"
