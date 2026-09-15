#!/usr/bin/env bash
# =============================================================================
# site-doctor.sh — diagnose, and optionally repair, an Industream site.
# =============================================================================
#   ./site-doctor.sh                    diagnose only; changes nothing
#   ./site-doctor.sh --fix              apply the safe repairs
#   ./site-doctor.sh --fix --reset-logto-db   also rebuild the Logto database
#
# Exit codes: 0 healthy · 1 issues remain · 2 cannot run (usage, no docker, …)
#
# Read-only by default on purpose: this gets run on customer production sites,
# often by someone who did not write it.
#
# Every repair here is something a current platform tree already does on each
# deploy. A site taking an up-to-date bundle should need none of them; when one
# fires, that is worth reporting upstream, not just fixing.
# =============================================================================
#
# `set -e` is deliberately NOT used: a diagnostic must survive its own probes,
# and most commands here are expected to fail on a broken site. Everything that
# matters is checked explicitly instead.
set -uo pipefail

STACK="${STACK:-industream-prod}"
ENV_NAME="${ENV:-prod}"
TARGET="${TARGET:-$HOME/industream-platform}"
FIX=false
RESET_LOGTO_DB=false

usage() { sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; }

# `${2:?}` would abort with 1 under `set -u`; every usage error must exit 2.
require_value() { [[ -n "${2:-}" ]] || { echo "✗ $1 needs a value" >&2; exit 2; }; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix)             FIX=true; shift ;;
    --reset-logto-db)  RESET_LOGTO_DB=true; shift ;;
    --stack)           require_value "$1" "${2:-}"; STACK="$2"; shift 2 ;;
    --env)             require_value "$1" "${2:-}"; ENV_NAME="$2"; shift 2 ;;
    --target)          require_value "$1" "${2:-}"; TARGET="$2"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --reset-logto-db destroys the OIDC application, the roles and every user. It
# must never be reachable from a read-only run.
if [[ "$RESET_LOGTO_DB" == true && "$FIX" != true ]]; then
  echo "✗ --reset-logto-db requires --fix (it is destructive)" >&2; exit 2
fi

if [[ -t 1 ]]; then
  B=$'\033[1;34m' G=$'\033[0;32m' Y=$'\033[1;33m' R=$'\033[0;31m' N=$'\033[0m'
else
  B='' G='' Y='' R='' N=''
fi
step() { printf '\n%s━━ %s%s\n' "$B" "$1" "$N"; }
ok()   { printf '   %s✓%s %s\n' "$G" "$N" "$1"; }
warn() { printf '   %s⚠%s %s\n' "$Y" "$N" "$1"; }
bad()  { printf '   %s✗%s %s\n' "$R" "$N" "$1"; }
act()  { printf '   %s▶%s %s\n' "$B" "$N" "$1"; }

ISSUES=0
issue() { ISSUES=$((ISSUES + 1)); bad "$1"; }

# A helper image is needed to read and change volume ownership. Prefer one the
# site already has: an air-gapped machine cannot pull.
HELPER_IMAGE=""
pick_helper_image() {
  local candidate
  for candidate in alpine:3.24.1 alpine:3 alpine:latest busybox:latest; do
    if docker image inspect "$candidate" >/dev/null 2>&1; then HELPER_IMAGE="$candidate"; return 0; fi
  done
  return 1
}

services() {
  docker service ls --filter "label=com.docker.stack.namespace=${STACK}" --format '{{.Name}}' 2>/dev/null
}
service_image() {
  docker service inspect "$1" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null
}

# ---------------------------------------------------------------- preconditions
command -v docker >/dev/null 2>&1 || { echo "✗ docker not found" >&2; exit 2; }
docker info >/dev/null 2>&1        || { echo "✗ cannot talk to the docker daemon" >&2; exit 2; }
mapfile -t SERVICES < <(services)
(( ${#SERVICES[@]} > 0 )) || { echo "✗ stack '${STACK}' has no services — pass --stack <name>" >&2; exit 2; }

printf '%sIndustream site doctor%s  stack=%s env=%s mode=%s\n' \
  "$B" "$N" "$STACK" "$ENV_NAME" "$([[ "$FIX" == true ]] && echo repair || echo read-only)"

# ------------------------------------------------------------------- 1. tree
step "1. Platform tree"
DOMAIN=""
envfile="$TARGET/unified/.env.${ENV_NAME}"
if [[ -f "$envfile" ]]; then
  DOMAIN="$(sed -n 's/^INDUSTREAM_DOMAIN=//p' "$envfile" | head -1)"
  if [[ -n "$DOMAIN" ]]; then
    ok "INDUSTREAM_DOMAIN = ${DOMAIN}"
  else
    issue "unified/.env.${ENV_NAME} exists but INDUSTREAM_DOMAIN is empty"
    bad "  every \${INDUSTREAM_DOMAIN} resolves empty → bind mounts like certs/.crt, Traefik routes break"
  fi
else
  issue "unified/.env.${ENV_NAME} is MISSING"
fi

if [[ -n "$DOMAIN" ]]; then
  if [[ -f "$TARGET/unified/base/certs/${DOMAIN}.crt" ]]; then
    ok "unified/base/certs/${DOMAIN}.crt present"
  else
    issue "unified/base/certs/${DOMAIN}.crt is MISSING — Grafana will not start"
    [[ -d "$TARGET/certs" ]] && warn "  certs/ exists at the tree root — copy them into unified/base/certs/"
  fi
fi

# ------------------------------------------------- 2. stray bundle env files
# deploy.sh feeds --env-file from a glob over the bundle directory. A name like
# `.env.core.bak` matches it, sorts AFTER the file it shadows, and — the chain
# being last-one-wins — silently decides which image versions get deployed.
step "2. Bundle env files"
strays=0
if [[ -d "$TARGET/unified/releases" ]]; then
  while IFS= read -r stray; do
    [[ -z "$stray" ]] && continue
    strays=$((strays + 1)); ISSUES=$((ISSUES + 1))
    if [[ "$FIX" == true ]]; then
      act "moving ${stray#"$TARGET"/} out of the bundle directory"
      mkdir -p "$TARGET/.env-strays" 2>/dev/null
      mv "$stray" "$TARGET/.env-strays/" 2>/dev/null && ok "moved" || bad "could not move it"
    else
      bad "${stray#"$TARGET"/} is loaded as if it were a group env file"
    fi
  done < <(find "$TARGET/unified/releases" -maxdepth 2 -name '.env.*' -type f \
             ! -regex '.*/\.env\.[a-z0-9-]+$' 2>/dev/null)
fi
(( strays == 0 )) && ok "no stray file shadows a group env file"

# ------------------------------------------------- 3. volume ownership drift
# An image that runs as a non-root user cannot read a root-owned volume. Never
# chown TO root: root reads any ownership, and rewriting would undo ownership a
# running service depends on.
step "3. Volume ownership"
drift=0
if ! pick_helper_image; then
  warn "no alpine/busybox image available locally — skipping (cannot inspect volumes)"
else
  for svc in "${SERVICES[@]}"; do
    image="$(service_image "$svc")"; [[ -n "$image" ]] || continue
    user="$(docker image inspect "${image%@*}" --format '{{.Config.User}}' 2>/dev/null)"
    user="${user%%:*}"
    [[ -z "$user" || "$user" == 0 || "$user" == root ]] && continue
    if [[ ! "$user" =~ ^[0-9]+$ ]]; then
      user="$(docker run --rm --entrypoint sh "${image%@*}" -c "id -u $user" 2>/dev/null)"
    fi
    [[ "$user" =~ ^[0-9]+$ ]] || continue

    while IFS= read -r vol; do
      [[ -z "$vol" ]] && continue
      docker volume inspect "$vol" >/dev/null 2>&1 || continue
      owner="$(docker run --rm -v "$vol":/v "$HELPER_IMAGE" stat -c '%u' /v 2>/dev/null)"
      [[ "$owner" == "$user" ]] && continue
      drift=$((drift + 1)); ISSUES=$((ISSUES + 1))
      if [[ "$FIX" == true ]]; then
        act "chown ${vol}: ${owner} → ${user}  (${svc##*_})"
        docker run --rm -v "$vol":/v "$HELPER_IMAGE" chown -R "${user}:${user}" /v >/dev/null 2>&1 \
          && ok "done" || bad "chown failed"
      else
        bad "${vol} owned by ${owner}, but ${svc##*_} runs as ${user}"
      fi
    done < <(docker service inspect "$svc" \
      --format '{{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{if eq .Type "volume"}}{{.Source}}{{"\n"}}{{end}}{{end}}' 2>/dev/null)
  done
  (( drift == 0 )) && ok "every volume matches the uid its image runs as"
fi

# --------------------------------------------------------- 4. pinned digests
# A service first deployed with a registry carries `image:tag@sha256:…`. Images
# loaded from a bundle have different digests — docker save/load does not keep
# the original — and `--resolve-image never` cannot re-resolve, so the task is
# rejected forever. `stack deploy` only rewrites services whose definition
# changed, so the ones whose version did not move keep the stale pin.
step "4. Registry digests"
pinned=0
for svc in "${SERVICES[@]}"; do
  image="$(service_image "$svc")"
  [[ "$image" == *@sha256:* ]] || continue
  pinned=$((pinned + 1)); ISSUES=$((ISSUES + 1))
  if [[ "$FIX" == true ]]; then
    act "unpinning ${svc##*_}"
    docker service update --no-resolve-image --image "${image%@sha256:*}" "$svc" >/dev/null 2>&1 \
      && ok "done" || bad "update failed"
  else
    bad "${svc##*_} is pinned to a registry digest"
  fi
done
(( pinned == 0 )) && ok "no service carries a registry digest"

# --------------------------------------------------------- 5. missing images
# Nothing here can conjure an image: it has to come from the bundle.
step "5. Images present locally"
missing=0
for svc in "${SERVICES[@]}"; do
  image="$(service_image "$svc")"; [[ -n "$image" ]] || continue
  docker image inspect "${image%@*}" >/dev/null 2>&1 && continue
  missing=$((missing + 1)); ISSUES=$((ISSUES + 1))
  bad "${svc##*_}: ${image%@*} is NOT on this machine"
done
if (( missing > 0 )); then
  warn "load them from the bundle:  cat <bundle>/images/<group>.tar.zst* | zstd -dc | docker load"
else
  ok "every service's image is present"
fi

# ----------------------------------------------------------------- 6. Logto
step "6. Logto"
PG="$(docker ps -qf "name=${STACK}_logto-postgres" 2>/dev/null | head -1)"
[[ -n "$PG" ]] || PG="$(docker ps -qf "name=_logto-postgres" 2>/dev/null | head -1)"

psql_logto() { docker exec "$PG" psql -U postgres -d logto -tAc "$1" 2>/dev/null; }
psql_admin() { docker exec "$PG" psql -U postgres -tAc "$1" 2>/dev/null; }

if [[ -z "$PG" ]]; then
  warn "logto-postgres is not running here — skipping"
else
  # A seeded Logto database carries ~70 tables. The entrypoint runs `db seed`
  # behind `|| true`, so a seed that died half-way still reports the service up.
  ntables="$(psql_logto "SELECT count(*) FROM pg_tables WHERE schemaname='public';")"
  seeded=false
  if [[ ! "$ntables" =~ ^[0-9]+$ ]]; then
    issue "cannot query the logto database"
  elif (( ntables < 20 )); then
    issue "logto has only ${ntables} table(s) — the seed never completed"
    bad "  the entrypoint hides it: \`db seed\` runs behind \`|| true\`"
  else
    ok "database seeded (${ntables} tables)"
    seeded=true
  fi

  if [[ "$seeded" == true ]]; then
    # Logto refuses to start against a business table without row-level security.
    norls="$(psql_logto "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='public' AND c.relkind='r' AND NOT c.relrowsecurity
          AND c.relname LIKE '%logto_config%';")"
    [[ "$norls" == "0" ]] && ok "row-level security in place" \
                          || issue "the config table lacks row-level security"

    # With no egress, Logto's bare fetch() to api.pwnedpasswords.com makes every
    # user creation answer 500 — including the first admin, which locks the console.
    notdisabled="$(psql_logto "SELECT count(*) FROM sign_in_experiences
        WHERE coalesce(password_policy->'rejects'->>'pwned','true') <> 'false';")"
    if [[ "$notdisabled" == "0" ]]; then
      ok "Have I Been Pwned check disabled on every tenant"
    else
      ISSUES=$((ISSUES + 1))
      policy_script="$TARGET/scripts/setup/logto-airgap-password-policy.sh"
      if [[ "$FIX" == true && -f "$policy_script" ]]; then
        act "disabling the Have I Been Pwned check"
        STACK="$STACK" bash "$policy_script" >/dev/null 2>&1 \
          && ok "done" || bad "failed — run scripts/setup/logto-airgap-password-policy.sh"
      else
        bad "${notdisabled} tenant(s) still check Have I Been Pwned — user creation 500s offline"
      fi
    fi

    napps="$(psql_logto "SELECT count(*) FROM applications WHERE tenant_id='default';")"
    nusers="$(psql_logto "SELECT count(*) FROM users WHERE tenant_id='default';")"
    if [[ "$napps" =~ ^[0-9]+$ ]] && (( napps > 0 )) && [[ "$nusers" =~ ^[0-9]+$ ]] && (( nusers > 0 )); then
      ok "${napps} OIDC application(s), ${nusers} user(s)"
    else
      issue "no OIDC application or no user — re-run the EE seeders (deploy.sh --airgap)"
    fi

    # Logto accepts a user with no email; Grafana does not, and fails on a 404
    # that names neither the user nor the missing field.
    noemail="$(psql_logto "SELECT string_agg(username, ', ') FROM users
        WHERE tenant_id='default' AND username IS NOT NULL
          AND (primary_email IS NULL OR primary_email='');")"
    [[ -n "$noemail" ]] && warn "users without an email (cannot sign in to Grafana): ${noemail}"
  fi

  # Logto's tenant roles live in the CLUSTER. DROP DATABASE leaves them behind,
  # the next seed dies on `role … already exists`, and the alterations then run
  # against an empty schema — surfacing as an undefined-type failure that points
  # nowhere near the cause.
  if [[ "$RESET_LOGTO_DB" == true ]]; then
    step "6b. Rebuilding the Logto database"
    warn "this destroys the OIDC application, the roles and every user"
    act "stopping logto"
    docker service scale "${STACK}_logto=0" >/dev/null 2>&1
    psql_admin "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='logto';" >/dev/null
    psql_admin "DROP DATABASE IF EXISTS logto;" >/dev/null
    while IFS= read -r role; do
      [[ -z "$role" ]] && continue
      act "dropping cluster role ${role}"
      psql_admin "DROP ROLE IF EXISTS \"${role}\";" >/dev/null || bad "could not drop ${role}"
    done < <(psql_admin "SELECT rolname FROM pg_roles WHERE rolname LIKE 'logto_tenant_%';")
    leftover="$(psql_admin "SELECT count(*) FROM pg_roles WHERE rolname LIKE 'logto_tenant_%';")"
    [[ "$leftover" == "0" ]] && ok "cluster roles cleaned" \
                             || bad "${leftover} logto_tenant_% role(s) remain — the reseed will fail"
    psql_admin "CREATE DATABASE logto;" >/dev/null && ok "database recreated"

    act "starting logto and waiting for the seed (up to 3 min)"
    docker service scale "${STACK}_logto=1" --detach >/dev/null 2>&1
    ntables=0
    for _ in $(seq 1 36); do
      sleep 5
      ntables="$(psql_logto "SELECT count(*) FROM pg_tables WHERE schemaname='public';")"
      [[ "$ntables" =~ ^[0-9]+$ ]] && (( ntables >= 20 )) && break
    done
    if [[ "$ntables" =~ ^[0-9]+$ ]] && (( ntables >= 20 )); then
      ok "seed completed (${ntables} tables)"
      policy_script="$TARGET/scripts/setup/logto-airgap-password-policy.sh"
      if [[ -f "$policy_script" ]]; then
        act "re-applying the air-gap password policy (the reset wiped it)"
        STACK="$STACK" bash "$policy_script" >/dev/null 2>&1 && ok "done" || bad "failed"
      fi
      warn "now re-run deploy.sh --airgap: only the EE seeders recreate the app and users"
    else
      issue "seed still incomplete (${ntables:-?} tables) — docker service logs --since 2m ${STACK}_logto"
    fi
  fi
fi

# ------------------------------------------------------------ 7. convergence
step "7. Stack state"
notready="$(docker stack services "$STACK" --format '{{.Name}} {{.Replicas}}' 2>/dev/null \
  | awk '{split($2,a,"/"); if (a[1]!=a[2]) print "   ✗ "$1" "$2}')"
total="$(docker stack services "$STACK" -q 2>/dev/null | wc -l)"
if [[ -n "$notready" ]]; then
  printf '%s\n' "$notready"
  ISSUES=$((ISSUES + 1))
  warn "some services were just updated — give swarm a minute, then re-run"
else
  ok "all ${total} services are at their desired replica count"
fi

# ---------------------------------------------------------------- verdict
echo
if (( ISSUES == 0 )); then
  printf '%s✓ nothing to repair%s\n' "$G" "$N"
  exit 0
fi
if [[ "$FIX" == true ]]; then
  printf '%s%d issue(s) handled or reported above — re-run to confirm%s\n' "$Y" "$ISSUES" "$N"
else
  printf '%s%d issue(s) found — re-run with --fix to repair%s\n' "$Y" "$ISSUES" "$N"
fi
echo "Re-run after any deploy made WITHOUT --airgap: it re-pins registry digests."
exit 1
