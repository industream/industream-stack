#!/usr/bin/env bash
# Refuses a deploy that would start a newer Postgres major on an existing volume.
#
# Postgres cannot open a data directory written by another major: the new
# server exits at boot and the service crash-loops. An image bump that crosses a
# major (TimescaleDB 2.17.2-pg17 → 2.30.2-pg18) therefore needs a dump/restore
# that a deploy must not run on its own. This check stops BEFORE the stack is
# touched and tells the operator how to stay put or how to migrate.
#
# The image's major is read from its PG_MAJOR and the data's from PG_VERSION,
# with the target image itself (already loaded, so it works air-gapped).
set -euo pipefail

VOLUME="" IMAGE="" DATA_SUBDIR="pgdata"

die() { printf '\033[0;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --volume) VOLUME="$2"; shift 2 ;;
    --image)  IMAGE="$2"; shift 2 ;;
    --data-subdir) DATA_SUBDIR="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$VOLUME" && -n "$IMAGE" ]] || die "usage: check-postgres-major.sh --volume <name> --image <ref> [--data-subdir pgdata]"

# Fresh install: nothing written yet, any major is fine.
docker volume inspect "$VOLUME" >/dev/null 2>&1 || exit 0

data_major="$(docker run --rm --entrypoint cat -v "$VOLUME:/v:ro" "$IMAGE" "/v/$DATA_SUBDIR/PG_VERSION" 2>/dev/null | tr -d '[:space:]')" || data_major=""
[[ -n "$data_major" ]] || exit 0

image_major="$(docker image inspect "$IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
  | sed -n 's/^PG_MAJOR=//p' | head -1)"
[[ -n "$image_major" ]] || die "cannot read PG_MAJOR from $IMAGE — is the image loaded?"
[[ "$data_major" == "$image_major" ]] && exit 0

stay_line="TIMESCALE_TIMESCALEDB_IMAGE=${IMAGE%-pg*}-pg${data_major}"
[[ "$IMAGE" =~ -pg[0-9]+$ ]] || stay_line="<the image variable>=<same image, PostgreSQL ${data_major} build>"

cat >&2 <<EOF

⚠ ============================================================================
⚠  Deploy stopped: PostgreSQL major upgrade on existing data
⚠ ============================================================================
   Volume  : ${VOLUME}  holds PostgreSQL ${data_major} data
   Image   : ${IMAGE}  runs PostgreSQL ${image_major}

   PostgreSQL ${image_major} cannot open a PostgreSQL ${data_major} data directory: the
   service would crash-loop. Nothing has been deployed or changed.

   Option 1 — stay on PostgreSQL ${data_major} (no data move). Add to .env.<env>:
       ${stay_line}
     then run the deploy again.

   Option 2 — migrate the data to PostgreSQL ${image_major} manually:
     1. stop the service, back up the volume (copy it to a new volume)
     2. on PostgreSQL ${data_major}: ALTER EXTENSION timescaledb UPDATE, then pg_dump
     3. on PostgreSQL ${image_major} with an empty volume: timescaledb_pre_restore(),
        pg_restore, timescaledb_post_restore()
     4. check row counts, then deploy again
   The TimescaleDB extension version must match on both sides of the dump.
EOF
exit 1
