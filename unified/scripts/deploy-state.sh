#!/usr/bin/env bash
# =============================================================================
# deploy-state.sh — a versioned "deploy-state" git repo per installation.
# =============================================================================
# Captures BOTH sides of a deployment in one nested git repo (<repo-root>/
# .deploy-state, ignored by the platform clone) so every install gets
# versioning / audit / rollback / diff of what actually runs:
#
#   live/<stack>/docker-compose.yml   LIVE state pulled from the Portainer API —
#   live/<stack>/stack.env            manual edits made in Portainer's UI are
#   live/_stacks.json                 snapshotted BEFORE a redeploy overwrites
#                                     them (who/when audit metadata included).
#   desired/<group>/docker-compose.yml DESIRED state: render-portainer-stacks.sh
#   desired/stack.env                  output (--baked, so it is comparable with
#   manifest.json                      live, which Portainer stores baked too).
#
# Secrets are SCRUBBED on both sides by the same helper (values → <redacted>),
# so the repo is safe to keep/ship and live-vs-desired diffs stay noise-free.
#
#   ./deploy-state.sh init                                  create the state repo
#   ./deploy-state.sh snapshot                              pull live ← Portainer
#   ./deploy-state.sh render [--env E] [--edition ce|ee]    render desired state
#   ./deploy-state.sh diff                                  desired vs live drift
#   ./deploy-state.sh log                                   state-repo history
#
# snapshot needs Portainer credentials: PORTAINER_API_KEY (preferred) or
# PORTAINER_PASSWORD (+ PORTAINER_USER, default admin). Neither set → exit 3
# (soft failure, so deploy.sh's best-effort pre-deploy hook can skip cleanly).
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # unified/
# The state repo lives one level ABOVE unified/ (= the platform repo root),
# next to the clone it describes. Overridable for tests / exotic layouts.
STATE_DIR="${STATE_DIR:-$HERE/../.deploy-state}"
# Swarm stacks are named industream-<group> by convention; STACK_PREFIX maps a
# desired/<group> onto its live/<stack> counterpart when diffing.
STACK_PREFIX="${STACK_PREFIX:-industream-}"

_TMP="$(mktemp -d)"
trap 'rm -rf "$_TMP"' EXIT

# ---- scrubber ----------------------------------------------------------------
# ONE redaction helper shared by snapshot (live) and render (desired): both
# sides of a diff MUST be scrubbed identically, or every diff is secret-noise.
# Data goes in via argv temp files, never stdin: `python3 - <<'PY'` reads its
# PROGRAM from stdin, so piping data into it would be swallowed.
scrub() {  # scrub <compose|env> <src> <dst>
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys, yaml
mode, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
SENSITIVE = re.compile(r"(password|passwd|secret|token|api[-_]?key)", re.I)
SAFE_SUFFIXES = ("_FILE", "_SECRET_NAME", "_SECRET_PATTERN")

def scrub_value(key, value):
    # Redact only REAL secret material. Keys that merely POINT at a secret
    # (a /run/secrets/ path, an external secret name/pattern) are kept — they
    # carry no secret and are exactly what a drift diff must surface.
    if value is None or not SENSITIVE.search(key):
        return value
    if key.strip().upper().endswith(SAFE_SUFFIXES):
        return value
    if str(value).startswith("/run/secrets/"):
        return value
    return "<redacted>"

if mode == "compose":
    doc = yaml.safe_load(open(src)) or {}
    for svc in (doc.get("services") or {}).values():
        if not isinstance(svc, dict):
            continue
        env = svc.get("environment")
        if isinstance(env, dict):              # map form: KEY: value
            for k in list(env):
                env[k] = scrub_value(k, env[k])
        elif isinstance(env, list):            # list form: "KEY=value" / "KEY"
            def scrub_item(entry):
                if not (isinstance(entry, str) and "=" in entry):
                    return entry               # bare "KEY" passthrough: no value
                key, value = entry.split("=", 1)
                return "{}={}".format(key, scrub_value(key, value))
            svc["environment"] = [scrub_item(e) for e in env]
    # IDENTICAL dump settings to render-portainer-stacks.sh: live content was
    # PUT to Portainer from that generator's output, so re-dumping with the
    # same settings keeps live and desired textually comparable.
    yaml.safe_dump(doc, open(dst, "w"), sort_keys=False, default_flow_style=False)
else:  # env file: KEY=VALUE lines; comments / blank lines preserved verbatim
    with open(src) as fin, open(dst, "w") as fout:
        for line in fin.read().splitlines():
            stripped = line.strip()
            if stripped and not stripped.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                line = "{}={}".format(key, scrub_value(key, value))
            fout.write(line + "\n")
PY
}

# ---- state-repo plumbing ------------------------------------------------------
ensure_repo() {
  [[ -d "$STATE_DIR/.git" ]] \
    || { echo "✗ no deploy-state repo at ${STATE_DIR} — run: deploy-state.sh init" >&2; exit 1; }
}

# Stage everything; commit only when something actually changed (idempotent
# snapshots/renders leave the history clean instead of stacking empty commits).
commit_if_changed() {  # commit_if_changed <commit-message> <no-change-message>
  git -C "$STATE_DIR" add -A
  if git -C "$STATE_DIR" diff --cached --quiet; then
    echo "$2"
    return 0
  fi
  git -C "$STATE_DIR" commit -q -m "$1"
  echo "✓ committed: $1"
}

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---- init ---------------------------------------------------------------------
cmd_init() {
  if [[ -d "$STATE_DIR/.git" ]]; then
    echo "✓ deploy-state repo already initialised at ${STATE_DIR} — nothing to do"
    return 0
  fi
  mkdir -p "$STATE_DIR"
  # default branch = main even on older git without `init -b` (symbolic-ref fallback)
  git init -q -b main "$STATE_DIR" 2>/dev/null \
    || { git init -q "$STATE_DIR"; git -C "$STATE_DIR" symbolic-ref HEAD refs/heads/main; }
  # local identity so commits work on appliance hosts with no global git config
  git -C "$STATE_DIR" config user.name  >/dev/null 2>&1 \
    || git -C "$STATE_DIR" config user.name "industream-cli"
  git -C "$STATE_DIR" config user.email >/dev/null 2>&1 \
    || git -C "$STATE_DIR" config user.email "cli@industream.local"
  cat > "$STATE_DIR/README.md" <<'EOF'
# deploy-state — versioned deployment state of this installation

Maintained by `unified/scripts/deploy-state.sh`. Do not edit by hand.

## Layout
- `live/<stack>/docker-compose.yml` — LIVE compose pulled from the Portainer API
  (includes manual edits made in Portainer's UI), secrets scrubbed.
- `live/<stack>/stack.env` — the stack's Portainer environment variables,
  secrets scrubbed (absent when the stack has none).
- `live/_stacks.json` — audit metadata per stack (Id, Name, CreatedBy,
  CreationDate, UpdatedBy, UpdateDate).
- `desired/<group>/docker-compose.yml` — DESIRED state rendered from source
  (`render-portainer-stacks.sh --baked`), secrets scrubbed.
- `desired/stack.env` — the shared rendered environment, secrets scrubbed.
- `manifest.json` — what produced `desired/` (edition, env, bundle, timestamp).

## Why
- `snapshot` before every deploy → manual Portainer edits are never silently
  lost; `git log` answers "what changed, when, by whom".
- `diff` → drift between what is running and what the source tree renders.
- Secrets are redacted (`<redacted>`) on BOTH sides, identically, so this repo
  is safe to retain and diffs stay meaningful.
EOF
  cat > "$STATE_DIR/.gitignore" <<'EOF'
*.bak
*.tar
*.tar.gz
EOF
  git -C "$STATE_DIR" add -A
  git -C "$STATE_DIR" commit -q -m "chore: init deploy-state repo"
  echo "✓ deploy-state repo initialised at ${STATE_DIR}"
}

# ---- Portainer API access -------------------------------------------------------
# Portainer is reached on the host itself: https://localhost with an SNI-less
# self-signed cert (-k) and routed by Traefik via the Host header. The domain
# comes from the environment or from the install's .env.<ENV> (the same file
# deploy.sh sources), so the snapshot hook needs zero extra configuration.
resolve_portainer_access() {
  if [[ -z "${INDUSTREAM_DOMAIN:-}" ]]; then
    local envf="$HERE/.env.${ENV:-prod}"
    if [[ -f "$envf" ]]; then
      # last assignment wins; strip inline comments / trailing spaces / quotes
      INDUSTREAM_DOMAIN="$(grep -E '^INDUSTREAM_DOMAIN=' "$envf" | tail -1 \
        | sed -E 's/^INDUSTREAM_DOMAIN=//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//; s/^"(.*)"$/\1/')"
    fi
  fi
  [[ -n "${INDUSTREAM_DOMAIN:-}" ]] \
    || { echo "✗ INDUSTREAM_DOMAIN not set and not found in ${HERE}/.env.${ENV:-prod}" >&2; exit 1; }

  # API key beats username/password; NEITHER → exit 3, a SOFT failure the
  # deploy.sh pre-deploy hook (and any other caller) can absorb non-fatally.
  if [[ -n "${PORTAINER_API_KEY:-}" ]]; then
    AUTH_ARGS=(-H "X-API-Key: ${PORTAINER_API_KEY}")
  elif [[ -n "${PORTAINER_PASSWORD:-}" ]]; then
    local body jwt
    # JSON-encode via python (a printf template breaks on quotes in passwords)
    body="$(python3 -c 'import json,os;print(json.dumps({
        "username": os.environ.get("PORTAINER_USER", "admin"),
        "password": os.environ["PORTAINER_PASSWORD"]}))')"
    curl -ksS --fail -H "Host: portainer.${INDUSTREAM_DOMAIN}" \
      -H "Content-Type: application/json" -d "$body" \
      -o "$_TMP/auth.json" "https://localhost/api/auth"
    jwt="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("jwt",""))' "$_TMP/auth.json")"
    [[ -n "$jwt" ]] || { echo "✗ Portainer auth succeeded but returned no jwt" >&2; exit 1; }
    AUTH_ARGS=(-H "Authorization: Bearer ${jwt}")
  else
    echo "⚠ neither PORTAINER_API_KEY nor PORTAINER_PASSWORD set — cannot snapshot live state" >&2
    exit 3
  fi
}

papi() {  # papi <api-path> <out-file>  — GET https://localhost/api<path>
  curl -ksS --fail -H "Host: portainer.${INDUSTREAM_DOMAIN}" "${AUTH_ARGS[@]}" \
    -o "$2" "https://localhost/api$1"
}

# ---- snapshot: live ← Portainer -------------------------------------------------
cmd_snapshot() {
  ensure_repo
  resolve_portainer_access
  papi /stacks "$_TMP/stacks.json"
  mkdir -p "$STATE_DIR/live" "$_TMP/env"

  # Split the stacks list: audit summary + an Id/Name index for the bash loop +
  # one raw KEY=VALUE file per stack Env (scrubbed below, same rule as compose).
  python3 - "$_TMP/stacks.json" "$_TMP" <<'PY'
import json, os, sys
stacks = json.load(open(sys.argv[1])) or []
tmp = sys.argv[2]
keys = ("Id", "Name", "CreationDate", "CreatedBy", "UpdateDate", "UpdatedBy")
json.dump([{k: s.get(k) for k in keys} for s in stacks],
          open(os.path.join(tmp, "_stacks.json"), "w"), indent=2)
with open(os.path.join(tmp, "index.tsv"), "w") as idx:
    for s in stacks:
        name = s.get("Name") or ""
        idx.write("{}\t{}\n".format(s.get("Id"), name))
        env = s.get("Env") or []
        if env and name:
            with open(os.path.join(tmp, "env", name + ".env"), "w") as f:
                for e in env:
                    f.write("{}={}\n".format(e.get("name"), e.get("value", "")))
PY
  cp "$_TMP/_stacks.json" "$STATE_DIR/live/_stacks.json"

  local count=0 sid sname
  while IFS=$'\t' read -r sid sname; do
    [[ -n "$sid" && -n "$sname" ]] || continue
    case "$sname" in */*|*..*) echo "  ⚠ skipping unsafe stack name '${sname}'" >&2; continue ;; esac
    papi "/stacks/${sid}/file" "$_TMP/file.json"
    python3 -c 'import json,sys;open(sys.argv[2],"w").write(json.load(open(sys.argv[1])).get("StackFileContent") or "")' \
      "$_TMP/file.json" "$_TMP/raw.yml"
    mkdir -p "$STATE_DIR/live/$sname"
    scrub compose "$_TMP/raw.yml" "$STATE_DIR/live/$sname/docker-compose.yml"
    if [[ -f "$_TMP/env/$sname.env" ]]; then
      scrub env "$_TMP/env/$sname.env" "$STATE_DIR/live/$sname/stack.env"
    else
      rm -f "$STATE_DIR/live/$sname/stack.env"   # Env emptied since last snapshot
    fi
    count=$((count + 1))
    echo "  ✓ live/${sname}"
  done < "$_TMP/index.tsv"

  # Prune state for stacks that no longer exist in Portainer.
  cut -f2 "$_TMP/index.tsv" > "$_TMP/names"
  local d n
  for d in "$STATE_DIR"/live/*/; do
    [[ -d "$d" ]] || continue
    n="$(basename "$d")"
    grep -Fxq "$n" "$_TMP/names" || { rm -rf "$d"; echo "  − pruned live/${n} (stack gone)"; }
  done

  commit_if_changed "live: snapshot $(utc_now) (${count} stacks)" "✓ no drift since last snapshot"
}

# ---- render: desired ← source tree ---------------------------------------------
cmd_render() {
  ensure_repo
  local env="prod" edition="ce" extra=() bundle=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)     env="$2"; shift 2 ;;
      --edition) edition="$2"; shift 2 ;;
      --bundle)  bundle="$2"; extra+=("$1" "$2"); shift 2 ;;
      --baked)   shift ;;                       # always added below; tolerate it
      *)         extra+=("$1"); shift ;;        # passed through to the renderer
    esac
  done
  # ALWAYS render --baked: Portainer stores live stacks fully interpolated, so
  # only a baked desired tree is textually comparable in `diff`.
  local render_args=(--env "$env" --edition "$edition" --baked)
  [[ ${#extra[@]} -gt 0 ]] && render_args+=("${extra[@]}")
  bash "$HERE/scripts/render-portainer-stacks.sh" "${render_args[@]}"

  local out="$HERE/releases/portainer/${env}-${edition}"
  [[ -d "$out" ]] || { echo "✗ renderer produced nothing at ${out}" >&2; exit 1; }

  # Rebuild desired/ from scratch so groups dropped from the render disappear.
  rm -rf "$STATE_DIR/desired"
  mkdir -p "$STATE_DIR/desired"
  local d g group_list=()
  for d in "$out"/*/; do
    [[ -f "$d/docker-compose.yml" ]] || continue
    g="$(basename "$d")"
    mkdir -p "$STATE_DIR/desired/$g"
    scrub compose "$d/docker-compose.yml" "$STATE_DIR/desired/$g/docker-compose.yml"
    group_list+=("$g")
  done
  scrub env "$out/stack.env" "$STATE_DIR/desired/stack.env"

  # Resolve the bundle version for the manifest (same rule as the renderer:
  # explicit --bundle, else the single releases/bundle-platform-*/ present).
  if [[ -z "$bundle" ]]; then
    local _b
    for _b in "$HERE"/releases/bundle-platform-*/; do
      [[ -d "$_b" ]] || continue
      bundle="$(basename "${_b%/}")"; bundle="${bundle#bundle-platform-}"
    done
  fi

  # manifest.json: enough provenance to reproduce desired/ exactly.
  local ts groups_csv
  ts="$(utc_now)"
  groups_csv="$(printf '%s,' "${group_list[@]}")"
  groups_csv="${groups_csv%,}"
  python3 - "$STATE_DIR/manifest.json" "$edition" "$env" "$bundle" "$ts" "$groups_csv" "${render_args[@]}" <<'PY'
import json, sys
out, edition, env, bundle, ts, groups = sys.argv[1:7]
json.dump({"edition": edition, "env": env, "bundle": bundle, "generated_at": ts,
           "groups": [g for g in groups.split(",") if g],
           "render_args": sys.argv[7:]},
          open(out, "w"), indent=2)
PY

  # A re-render ALWAYS rewrites generated_at in manifest.json; that alone is
  # not a real change. When manifest.json is the only staged path, drop it and
  # report "unchanged" instead of stacking timestamp-only commits.
  git -C "$STATE_DIR" add -A
  if git -C "$STATE_DIR" diff --cached --quiet; then
    echo "✓ desired state unchanged"
  elif [[ "$(git -C "$STATE_DIR" diff --cached --name-only)" == "manifest.json" ]]; then
    git -C "$STATE_DIR" checkout HEAD -- manifest.json
    echo "✓ desired state unchanged"
  else
    git -C "$STATE_DIR" commit -q -m "render: ${edition}/${env} ${ts}"
    echo "✓ committed: render: ${edition}/${env} ${ts}"
  fi
}

# ---- diff: live vs desired -------------------------------------------------------
cmd_diff() {
  ensure_repo
  local drifted=0 d g live_dir n
  for d in "$STATE_DIR"/desired/*/; do
    [[ -d "$d" ]] || continue
    g="$(basename "$d")"
    live_dir="live/${STACK_PREFIX}${g}"
    if [[ ! -d "$STATE_DIR/$live_dir" ]]; then
      echo "+ ${g}: in desired only (not deployed, or no snapshot yet)"
      drifted=$((drifted + 1))
      continue
    fi
    # live first, desired second → `+` lines are what a redeploy would change.
    # --no-index exits 1 on any difference — that is data here, not a failure.
    if ! git -C "$STATE_DIR" --no-pager diff --no-index -- \
         "$live_dir/docker-compose.yml" "desired/$g/docker-compose.yml"; then
      drifted=$((drifted + 1))
    fi
  done
  for d in "$STATE_DIR"/live/*/; do
    [[ -d "$d" ]] || continue
    n="$(basename "$d")"
    g="${n#"$STACK_PREFIX"}"
    if [[ ! -d "$STATE_DIR/desired/$g" ]]; then
      echo "- ${n}: live only (missing from desired)"
      drifted=$((drifted + 1))
    fi
  done
  echo "▶ ${drifted} group(s) drifted"
}

# ---- log -------------------------------------------------------------------------
cmd_log() {
  ensure_repo
  git -C "$STATE_DIR" --no-pager log --oneline -20
}

# ---- dispatch ----------------------------------------------------------------------
CMD="${1:-}"
[[ $# -gt 0 ]] && shift
case "$CMD" in
  init)      cmd_init "$@" ;;
  snapshot)  cmd_snapshot "$@" ;;
  render)    cmd_render "$@" ;;
  diff)      cmd_diff "$@" ;;
  log)       cmd_log "$@" ;;
  _scrub)    scrub "$@" ;;   # internal: exposes the scrubber for tests
  -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//' ;;
  "")        sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1 ;;
  *)         echo "✗ unknown command '${CMD}' (init|snapshot|render|diff|log)" >&2; exit 1 ;;
esac
