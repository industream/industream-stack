#!/usr/bin/env bash
# =============================================================================
# EE deploy gate — ties the offline signed license to the deployment.
# =============================================================================
# The keystone of the bash-first / edition model. Given a signed license it:
#   1. verifies it (signature + expiry) via license.sh
#   2. derives the entitlement set from the license (addons + products)
#   3. reads modules.json and selects the allowed services + their stack files
#      — BSL/Apache always; proprietary only if entitled (same rule as the TS
#      `stack-filter.ts`, but sourced from the OFFLINE license instead of Keygen)
#   4. applies the `-ee` image variant for entitled enterprise modules
#   5. logs in to the enterprise registry with the license-embedded robot creds
#   6. writes `INDUSTREAM_EDITION=enterprise` to `.env` so downstream scripts
#      know the deploy is EE (idempotent: noop on a non-EE re-run)
#   7. delegates the actual deploy to `scripts/deploy-swarm.sh`, passing
#      `--exclude` for non-entitled services and `--with-ee-overlay` so the
#      Logto overlay (docker-stack.ee.yml) is appended. We delegate because
#      deploy-swarm.sh owns the preprocessing pipeline — envsubst,
#      `docker compose config`, `fix-swarm-yaml.py`, registry pre-flight.
#      Calling `docker stack deploy` directly would break on Compose-only
#      constructs (e.g. `profiles:` in docker-stack.backup.yml).
#
# Dry-run by default (prints the plan). --login does the docker login.
# --deploy runs the stack deploy. No license = CE (this gate is EE-only).
#
# Usage:
#   ./ee-gate.sh --license acme.lic [--pubkey keys/license-public.pem]
#                [--modules <modules.json>] [--stack-dir <dir>] [--env dev]
#                [--login] [--deploy]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=license.sh
source "$SCRIPT_DIR/license.sh"

LICENSE_FILE=""
PUBKEY="${LICENSE_PUBKEY:-$SCRIPT_DIR/keys/license-public.pem}"
MODULES=""
STACK_DIR=""
ENVNAME="${ENV:-dev}"
DO_LOGIN=0
DO_DEPLOY=0
ENTERPRISE_REGISTRY="${ENTERPRISE_REGISTRY:-39t88114.c1.gra9.container-registry.ovh.net}"

die() { echo "✗ ee-gate: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --license)   LICENSE_FILE="$2"; shift 2 ;;
    --pubkey)    PUBKEY="$2"; shift 2 ;;
    --modules)   MODULES="$2"; shift 2 ;;
    --stack-dir) STACK_DIR="$2"; shift 2 ;;
    --env)       ENVNAME="$2"; shift 2 ;;
    --login)     DO_LOGIN=1; shift ;;
    --deploy)    DO_DEPLOY=1; DO_LOGIN=1; shift ;;
    -h|--help)   sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$LICENSE_FILE" ] || die "--license <file.lic> required"

# Locate modules.json (the entitlement→service/stackFile map).
if [ -z "$MODULES" ]; then
  for c in "$SCRIPT_DIR/../../../industream-cli/modules.json" \
           "$SCRIPT_DIR/../../industream-cli/modules.json" \
           "$SCRIPT_DIR/modules.json" "./modules.json"; do
    [ -f "$c" ] && MODULES="$c" && break
  done
fi
[ -f "$MODULES" ] || die "modules.json not found (pass --modules <path>)"
STACK_DIR="${STACK_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# --- 1) verify license -------------------------------------------------------
license_verify "$LICENSE_FILE" "$PUBKEY" || exit 1
license_check_expiry || { [ "$LICENSE_STATUS" = grace ] || die "license $LICENSE_STATUS"; }

CUSTOMER="$(license_field '.customer')"
SITE="$(license_field '.site')"
LTYPE="$(license_field '.type')"

# --- 2) entitlement set = addons[] + PRODUCT_<moduleKey> ---------------------
mapfile -t ENTS < <(jq -r '
  ([.addons[]?]) + ([.modules | keys[]? | "PRODUCT_" + .]) | .[]' <<<"$LICENSE_PAYLOAD")
has_ent() { local e; for e in "${ENTS[@]:-}"; do [ "$e" = "$1" ] && return 0; done; return 1; }

# --- 3+4) walk modules.json: decide allowed, collect stack files + ee images -
declare -A STACKFILES=()
ALLOWED=() ; EXCLUDED=() ; EE_IMAGES=()
# 0x1F (unit separator) as the field delimiter: a NON-whitespace IFS preserves
# empty fields. `IFS=$'\t'` would collapse the empty `entitlement` column
# (tab is IFS-whitespace) and shift every field by one.
while IFS=$'\037' read -r lic ent svc sf img eev; do
  [ -z "$svc" ] && continue
  allowed=0
  if   [ "$lic" = bsl ] || [ "$lic" = apache ]; then allowed=1   # always
  elif [ -z "$ent" ];                            then allowed=1   # gated by stack-file inclusion
  elif has_ent "$ent";                           then allowed=1   # entitled
  fi
  if [ "$allowed" = 1 ]; then
    ALLOWED+=("$svc")
    [ -n "$sf" ] && STACKFILES["$sf"]=1
    # `-ee` variant: applies when an EE build exists AND we're in a (paid) EE deploy.
    [ -n "$eev" ] && EE_IMAGES+=("${svc}=${ENTERPRISE_REGISTRY}/${eev}")
  else
    EXCLUDED+=("$svc")
  fi
done < <(jq -r '(.modules // .)[] |
  [.license//"", .entitlement//"", .serviceName//"", .stackFile//"", .imagePattern//"", .enterpriseVariant//""]
  | join("")' "$MODULES")

# --- report ------------------------------------------------------------------
echo "════════ EE deploy gate ════════"
echo "license : $CUSTOMER @ ${SITE:-<no site>}  (type=$LTYPE, status=$LICENSE_STATUS)"
echo "entitlements: ${ENTS[*]:-<none>}"
echo
echo "allowed services (${#ALLOWED[@]}): ${ALLOWED[*]}"
echo "excluded (${#EXCLUDED[@]}): ${EXCLUDED[*]:-<none>}"
echo
echo "stack files to deploy:"
COMPOSE_ARGS=()
for sf in $(printf '%s\n' "${!STACKFILES[@]}" | sort); do
  if [ -f "$STACK_DIR/$sf" ]; then echo "  ✓ $sf"; COMPOSE_ARGS+=("-c" "$STACK_DIR/$sf")
  else echo "  • $sf  (not present in $STACK_DIR — v2 file TBD)"; fi
done
echo
echo "enterprise (-ee) image overrides (${#EE_IMAGES[@]}):"
for e in "${EE_IMAGES[@]:-}"; do [ -n "$e" ] && echo "  $e:<tag>"; done

# --- 5) enterprise registry login -------------------------------------------
NEED_LOGIN=0; [ "${#EE_IMAGES[@]}" -gt 0 ] && NEED_LOGIN=1
if [ "$NEED_LOGIN" = 1 ]; then
  IFS=$'\t' read -r HUSER HSECRET < <(license_harbor_login || true)
  echo
  if [ -z "${HUSER:-}" ]; then
    echo "⚠ enterprise images required but the license carries no Harbor robot creds."
  elif [ "$DO_LOGIN" = 1 ]; then
    echo "→ docker login $ENTERPRISE_REGISTRY as $HUSER"
    printf '%s' "$HSECRET" | docker login "$ENTERPRISE_REGISTRY" -u "$HUSER" --password-stdin
  else
    echo "→ (dry-run) docker login $ENTERPRISE_REGISTRY -u '$HUSER' --password-stdin   # secret embedded in license"
  fi
fi

# --- 6) record edition in .env ----------------------------------------------
# Downstream scripts (create-secrets-ee.sh, the install wizard, etc.) read
# `INDUSTREAM_EDITION` from .env to decide whether to provision EE-only state.
# We write it here — after license verification has passed — so it's
# tamper-evidence-aligned: a valid license == EE; no license == CE.
ENV_FILE="$STACK_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  if grep -q '^INDUSTREAM_EDITION=' "$ENV_FILE"; then
    sed -i 's/^INDUSTREAM_EDITION=.*/INDUSTREAM_EDITION=enterprise/' "$ENV_FILE"
  else
    printf '\nINDUSTREAM_EDITION=enterprise\n' >> "$ENV_FILE"
  fi
  echo "→ INDUSTREAM_EDITION=enterprise written to $ENV_FILE"
fi

# --- 7) deploy ---------------------------------------------------------------
# Delegate to deploy-swarm.sh so the resolved stack benefits from the existing
# envsubst → `docker compose config` → fix-swarm-yaml.py preprocessing. Service
# exclusion is the license-policy hook: stack-file selection is left to
# deploy-swarm.sh (env-driven), and non-entitled services are surgically
# removed from the resolved YAML via its `--exclude` flag. The EE overlay
# (docker-stack.ee.yml) is opted-in via `--with-ee-overlay`.
echo
DEPLOY_SCRIPT="$STACK_DIR/scripts/deploy-swarm.sh"
[ -x "$DEPLOY_SCRIPT" ] || die "deploy-swarm.sh not found at $DEPLOY_SCRIPT"

# Build comma-separated --exclude argument from EXCLUDED[].
EXCLUDE_ARG=""
if [ "${#EXCLUDED[@]}" -gt 0 ]; then
  EXCLUDE_ARG=$(printf '%s,' "${EXCLUDED[@]}")
  EXCLUDE_ARG="${EXCLUDE_ARG%,}"
fi

DEPLOY_CMD=(bash "$DEPLOY_SCRIPT" --env "$ENVNAME" --with-ee-overlay)
[ -n "$EXCLUDE_ARG" ] && DEPLOY_CMD+=(--exclude "$EXCLUDE_ARG")

if [ "$DO_DEPLOY" = 1 ]; then
  echo "→ ${DEPLOY_CMD[*]}"
  "${DEPLOY_CMD[@]}"
else
  echo "→ (dry-run) ${DEPLOY_CMD[*]}"
  echo "  (add --login to authenticate, --deploy to run)"
fi
