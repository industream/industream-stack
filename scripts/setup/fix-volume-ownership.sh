#!/usr/bin/env bash
# Chowns existing named volumes to the uid the images ABOUT to run declare.
#
# Only an update is affected: a fresh install creates volumes empty and Docker
# hands them to the container's user. When an image later changes the user it
# runs as, the data the previous version wrote as root becomes unreadable and
# the service crash-loops with nothing useful in its logs.
#
# The uid is read from each image, never hardcoded — an image that changes its
# user again is followed automatically.
#
# Idempotent: a volume already owned correctly is left alone.
set -euo pipefail

ENV_NAME="${ENV:-prod}"
PROJECT=""
DRY_RUN=false
FILES=()

die()  { printf '\033[0;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
info() { printf '▶ %s\n' "$1"; }
ok()   { printf '\033[0;32m✓ %s\033[0m\n' "$1"; }

usage() {
  cat <<'USAGE'
Usage: fix-volume-ownership.sh [--env <env>] [--dry-run] <compose-file>...

Reads the compose files, resolves each service's image and named volumes, and
chowns any volume whose owner does not match the image's declared user.

  --env <env>       value for ${ENV} when expanding volume names (default: prod)
  --project <name>  compose project, used to resolve volumes declared without a
                    name: (compose prefixes them <project>_<volume>)
  --dry-run         report what would change, change nothing
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)     ENV_NAME="${2:?--env needs a value}"; shift 2 ;;
    --project) PROJECT="${2:?--project needs a value}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        usage >&2; die "unknown option: $1" ;;
    *)         FILES+=("$1"); shift ;;
  esac
done

(( ${#FILES[@]} > 0 )) || { usage >&2; die "at least one compose file is required"; }
command -v docker >/dev/null || die "docker not found"

# service<TAB>image<TAB>volume, one line per mounted named volume. Bind mounts
# are skipped: they belong to the host, and their ownership is the operator's.
mapping="$(ENV="$ENV_NAME" python3 - "${FILES[@]}" <<'PY'
import os, sys, yaml

services, volumes = {}, {}
for path in sys.argv[1:]:
    try:
        doc = yaml.safe_load(open(path)) or {}
    except Exception:
        continue
    for name, spec in (doc.get("services") or {}).items():
        services.setdefault(name, {}).update(spec or {})
    for name, spec in (doc.get("volumes") or {}).items():
        volumes[name] = spec or {}

def expand(value):
    return os.path.expandvars(str(value)) if value is not None else ""

for svc, spec in services.items():
    image = expand(spec.get("image"))
    if not image or "$" in image:
        continue
    for entry in spec.get("volumes") or []:
        # Long syntax carries an explicit type; short syntax is "src:dst[:opts]".
        if isinstance(entry, dict):
            if entry.get("type") != "volume":
                continue
            src = entry.get("source")
        else:
            src = str(entry).split(":")[0]
            # A bind mount starts with / or . — a named volume never does.
            if src.startswith(("/", ".", "~")):
                continue
        if not src:
            continue
        # `name:` pins the real volume name (the swarm overlays do this).
        # Compose does not: it prefixes the project at runtime, so emit the bare
        # key and let the caller try <project>_<key> as well.
        real = expand((volumes.get(src) or {}).get("name", "")) or src
        print(f"{svc}\t{image}\t{real}")
PY
)" || die "could not read the compose files"

[[ -n "$mapping" ]] || { info "no named volumes with a pinned name — nothing to check"; exit 0; }

# The image's declared user, resolved to a numeric uid. An image that declares
# a NAME (e.g. "node") is asked for the uid from inside itself, so this never
# depends on a mapping maintained here.
image_uid() {
  local image="$1" user
  user="$(docker image inspect "$image" --format '{{.Config.User}}' 2>/dev/null)" || return 1
  user="${user%%:*}"
  [[ -z "$user" ]] && { echo 0; return 0; }
  [[ "$user" =~ ^[0-9]+$ ]] && { echo "$user"; return 0; }
  docker run --rm --entrypoint sh "$image" -c "id -u $user" 2>/dev/null || return 1
}

fixed=0 checked=0
while IFS=$'\t' read -r svc image vol; do
  [[ -z "$vol" ]] && continue
  # A compose volume exists under <project>_<name>; a swarm one under the pinned
  # name. Try the literal first, then the project prefix.
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    if [[ -n "$PROJECT" ]] && docker volume inspect "${PROJECT}_${vol}" >/dev/null 2>&1; then
      vol="${PROJECT}_${vol}"
    else
      continue   # fresh install, or a volume this runtime names differently
    fi
  fi
  checked=$((checked + 1))

  uid="$(image_uid "$image")" || { echo "  ⚠ $svc: cannot read the user of $image — skipped" >&2; continue; }

  # A root process reads any ownership, so there is nothing to repair — and
  # rewriting the volume to root would undo ownership the service is running
  # with. The first version of this script did exactly that to influxdb and
  # cdn-server, whose images declare no user.
  [[ "$uid" == 0 ]] && continue

  owner="$(docker run --rm -v "$vol":/v alpine:3.24.1 stat -c '%u:%g' /v 2>/dev/null)" || {
    echo "  ⚠ $svc: cannot stat volume $vol — skipped" >&2; continue; }

  if [[ "$owner" == "${uid}:${uid}" ]]; then
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    info "would chown $vol: $owner → ${uid}:${uid}  ($svc)"
  else
    info "chown $vol: $owner → ${uid}:${uid}  ($svc)"
    docker run --rm -v "$vol":/v alpine:3.24.1 chown -R "${uid}:${uid}" /v \
      || { echo "  ⚠ $svc: chown of $vol failed" >&2; continue; }
  fi
  fixed=$((fixed + 1))
done <<< "$mapping"

if (( fixed == 0 )); then
  ok "$checked existing volume(s) already match their image's user"
else
  ok "$fixed of $checked volume(s) realigned with their image's user"
fi
