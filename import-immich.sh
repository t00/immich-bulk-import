#!/bin/sh
# Runs INSIDE the image. Imports /import into Immich, using subdirectory
# names as album names. POSIX sh -- node:alpine has BusyBox ash, not bash.
#
#   --go      actually upload (default is a dry run)
#   --flat    album = each file's immediate parent dir
#   --top     album = top-level subdir of /import  (default)
#   --check   just print server info and exit
#   --verify  report which local files are NOT on the server, then exit
#   --        everything after this is passed straight to `immich upload`
set -eu

DRY="--dry-run"
MODE="top"
SRC="${IMPORT_DIR:-/import}"

while [ $# -gt 0 ]; do
  case "$1" in
    --go)    DRY=""      ; shift ;;
    --flat)  MODE="flat" ; shift ;;
    --top)   MODE="top"  ; shift ;;
    --check)  exec immich server-info ;;
    --verify) MODE="verify" ; shift ;;
    --help)  sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
    --)      shift; break ;;
    *)       break ;;
  esac
done
# whatever remains in "$@" is forwarded to immich upload

[ -d "$SRC" ] || { echo "error: $SRC not mounted" >&2; exit 1; }

# The CLI falls back to .well-known/immich discovery, so a bare host URL often
# still works -- warn rather than refuse.
case "${IMMICH_INSTANCE_URL:-}" in
  "")    echo "error: IMMICH_INSTANCE_URL not set in .env" >&2; exit 1 ;;
  */api) ;;
  *)     echo "note: IMMICH_INSTANCE_URL does not end in /api; relying on .well-known discovery" >&2 ;;
esac
if [ -n "$DRY" ] && [ "$MODE" != "verify" ]; then
  echo ">>> DRY RUN -- pass --go to actually upload"
fi

if [ "$MODE" = "verify" ]; then
  echo "Hashing every file under $SRC and comparing with the server." >&2
  echo "On a large library this takes a while." >&2

  # No --album/--album-name here: updateAlbums() returns early without them,
  # which keeps this pass strictly read-only.
  #
  # --no-progress because the CLI's progress bars only render on a TTY, and
  # capturing output for parsing makes stdout a pipe. Without it there is no
  # feedback at all during the hash. tee keeps a copy for the parser while awk
  # forwards the chatter live, dropping the JSON block (which would otherwise
  # dump every filename to the terminal).
  out=$(mktemp)
  immich upload --recursive --dry-run --json-output --no-progress "$@" "$SRC" 2>&1 \
    | tee "$out" \
    | awk '/^\{$/ { injson = 1 } injson { if (/^\}$/) injson = 0; next } NF' >&2

  node /opt/immich/verify.mjs <"$out"
  rc=$?
  rm -f "$out"
  exit $rc
fi

if [ "$MODE" = "flat" ]; then
  # --album derives the name from each file's immediate parent directory, so
  # nested trees land in albums named after the DEEPEST folder.
  # shellcheck disable=SC2086
  exec immich upload --recursive $DRY --album "$@" "$SRC"
fi

# --- top mode --------------------------------------------------------------
# One `immich upload` per top-level folder with an explicit --album-name, so
# everything nested below it still lands in the top-level album.
found=0
failed=0
for dir in "$SRC"/*/; do
  [ -d "$dir" ] || continue          # no-match glob stays literal in sh
  found=$((found + 1))
  album=$(basename "$dir")
  echo "=== $album ==="
  # Don't let one bad folder abort a long import; report at the end instead.
  # shellcheck disable=SC2086
  if ! immich upload --recursive $DRY --album-name "$album" "$@" "$dir"; then
    echo "!!! FAILED: $album" >&2
    failed=$((failed + 1))
  fi
done

if [ "$found" -eq 0 ]; then
  echo "error: no subdirectories in $SRC -- use --flat for loose files" >&2
  exit 1
fi

# Loose files directly in $SRC have no album and are silently skipped in top
# mode; say so rather than letting them go missing quietly.
loose=$(find "$SRC" -maxdepth 1 -type f | wc -l)
[ "$loose" -gt 0 ] && echo "note: $loose file(s) directly in $SRC were skipped (no album). Use --flat for those."

echo "done: $found album(s), $failed failed"
[ "$failed" -eq 0 ] || exit 1