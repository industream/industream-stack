# Air-gapped bundle — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `prepare`/`install` pair that lets the unified stack be installed and updated on a site with no internet access.

**Architecture:** `deploy.sh` gains two flags — `--list-images` (the single source of truth for what must be bundled) and `--airgap` (skip the pre-pull, add `--resolve-image never`). A sibling `unified/scripts/airgap.sh` builds a bundle directory of per-group image tarballs, a `git archive` of the tree, harvested runtime assets, and a generated `install.sh` that loads, syncs, seeds and deploys on site.

**Tech Stack:** bash, docker CLI, zstd, rsync, split, python3 (already a deploy.sh dependency).

**Spec:** `docs/specs/2026-09-03-airgap-bundle-design.md`

## Global Constraints

- **Everything in English** — code, comments, commit messages, documentation. Repo rule.
- **Branch `feature/airgap-bundle`, off `origin/main`. Never commit to `main`, never merge, never push a tag.** The PR is opened for review by the repo owner, not merged by us.
- **Images are delivered by `docker load`. No local registry, and no image reference in `base/*.yml` or `runtime/**` is edited** — 15 third-party references hardcode their registry and are load-bearing.
- **The image list is produced only by `deploy.sh --list-images`.** No second list anywhere.
- **`--max-part-size` defaults to `3800M`** (keeps every file under the FAT32 4 GiB per-file limit). `0` disables splitting.
- **Loading never reassembles a split file** — `cat parts | zstd -dc | docker load`.
- **`prepare` refuses a dirty git working tree** on tracked files.
- **`prepare` fails loudly when a harvested CDN cache is empty.** Never ship an empty cache.
- **The on-site tree sync never runs `git reset --hard` and never a bare `cp -r`.** rsync with hard exclusions: `.env.*`, `secrets/`, `unified/custom/`, `unified/instances/`, `.deploy-state/`.
- **`install.sh` exposes no `--down`** — `deploy.sh --down` destroys `caddy_data`, hence the CA.
- **Assets are seeded on every deploy**, not only the first.
- Line numbers drift; anchor edits on the quoted strings given in each task, not on line numbers.

---

## File Structure

| File | Responsibility |
|---|---|
| `unified/scripts/deploy.sh` (modify) | Add `--list-images` and `--airgap`. Extract the inline image extractor into `resolve_image_list()` used by both the flag and the pre-pull. |
| `unified/scripts/airgap.sh` (create) | `prepare` and `verify`. Build-side only; never deploys. |
| `unified/scripts/airgap-install.sh` (create) | Copied into the bundle as `install.sh`. Site-side only; never builds. |
| `tests/airgap/lib.sh` (create) | Assertion helpers and the `docker` stub harness. |
| `tests/airgap/test_*.sh` (create) | One file per task's behaviour. |
| `tests/airgap/run.sh` (create) | Runs every `test_*.sh`, prints a summary, exits non-zero on failure. |
| `tests/airgap/bench/` (create) | Isolated-VM bench: libvirt network definition and the observable-signal checks. |
| `docs/runbook/airgap.md` (create) | Operator runbook: build, transport, install, update, roll back. |

---

## Task 1: Test harness

**Files:**
- Create: `tests/airgap/lib.sh`, `tests/airgap/run.sh`
- Test: itself

**Interfaces:**
- Produces: `assert_eq <actual> <expected> <label>`, `assert_contains <haystack> <needle> <label>`, `assert_fails <cmd...>`, `with_docker_stub <fn>` (prepends a recording `docker` stub to `PATH`, exports `DOCKER_LOG` naming the file that receives one line per invocation), `fail <msg>`, `pass <label>`.

- [ ] **Step 1: Write the failing test**

Create `tests/airgap/test_harness.sh`:

```bash
#!/usr/bin/env bash
# The harness must record docker invocations and must fail loudly.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

with_docker_stub bash -c 'docker pull alpine:3 >/dev/null; docker stack deploy -c f.yml s >/dev/null'
assert_contains "$(cat "$DOCKER_LOG")" "pull alpine:3" "stub records a pull"
assert_contains "$(cat "$DOCKER_LOG")" "stack deploy" "stub records a stack deploy"
assert_fails false "assert_fails accepts a failing command"
pass "harness"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/airgap/test_harness.sh`
Expected: FAIL — `lib.sh` does not exist.

- [ ] **Step 3: Write the harness**

Create `tests/airgap/lib.sh`:

```bash
#!/usr/bin/env bash
# Minimal assertion helpers. Plain bash on purpose: this repo has no test
# framework, and the bench VM is air-gapped so nothing can be installed there.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

fail() { echo "  ✗ $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
  pass "$3"
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3: '$2' not found in output"
  pass "$3"
}

assert_fails() {
  local label="${*: -1}"
  if "${@:1:$#-1}" >/dev/null 2>&1; then fail "$label: command unexpectedly succeeded"; fi
  pass "$label"
}

# Runs a command with a `docker` stub first on PATH. Every invocation appends
# its argv to $DOCKER_LOG, so a test can assert what the script WOULD have run
# without a daemon — and, just as importantly, what it did NOT run.
with_docker_stub() {
  local stub_dir; stub_dir="$(mktemp -d)"
  DOCKER_LOG="$(mktemp)"; export DOCKER_LOG
  cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
case "$1" in
  info)   echo "active" ;;
  image)  exit 1 ;;          # `image inspect` → absent, so callers pull
  volume) echo "vol" ;;
esac
exit 0
STUB
  chmod +x "$stub_dir/docker"
  PATH="$stub_dir:$PATH" "$@"
}
```

Create `tests/airgap/run.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
failed=0
for t in test_*.sh; do
  echo "▶ $t"
  bash "$t" || { echo "  ✗ $t FAILED"; failed=1; }
done
exit "$failed"
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/airgap/run.sh`
Expected: PASS on `test_harness.sh`.

- [ ] **Step 5: Commit**

```bash
git add tests/airgap/lib.sh tests/airgap/run.sh tests/airgap/test_harness.sh
git commit -m "test(airgap): add a plain-bash harness with a recording docker stub"
```

---

## Task 2: `deploy.sh --list-images`

**Files:**
- Modify: `unified/scripts/deploy.sh` — the argument `case` block, and the pre-pull block (anchor: the line printing `▶ pre-pulling images`)
- Test: `tests/airgap/test_list_images.sh`

**Interfaces:**
- Consumes: the harness from Task 1.
- Produces: `deploy.sh --list-images` prints one fully-resolved image reference per line and exits 0. `resolve_image_list <file>...` is the shell function both this flag and the pre-pull call.

- [ ] **Step 1: Write the failing test**

Create `tests/airgap/test_list_images.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

ce="$(with_docker_stub ./scripts/deploy.sh --runtime swarm --edition ce --list-images)"
[[ -n "$ce" ]] || fail "CE list is empty"
pass "CE list is non-empty"

# Every reference must be fully resolved: an unexpanded ${VAR} would silently
# become an empty image at deploy time.
if grep -q '\$' <<<"$ce"; then fail "unresolved variable in the image list"; fi
pass "no unresolved variables"

assert_contains "$ce" "postgres:" "third-party images are included"

# EE adds Logto and the enterprise Hub, so it must be a strict superset.
ee="$(with_docker_stub ./scripts/deploy.sh --runtime swarm --edition ee --list-images)"
(( $(wc -l <<<"$ee") > $(wc -l <<<"$ce") )) || fail "EE list is not larger than CE"
pass "EE list is larger than CE"
assert_contains "$ee" "logto" "EE includes Logto"

# --groups must narrow the footprint.
core="$(with_docker_stub ./scripts/deploy.sh --runtime swarm --edition ce --groups core --list-images)"
(( $(wc -l <<<"$core") < $(wc -l <<<"$ce") )) || fail "--groups did not narrow the list"
pass "--groups narrows the list"

# No duplicates: a duplicate would be saved twice into the bundle.
assert_eq "$(sort <<<"$ce" | uniq -d | wc -l)" "0" "list has no duplicates"

# The flag must not deploy anything.
if grep -q "stack deploy" "$DOCKER_LOG" 2>/dev/null; then fail "--list-images deployed"; fi
pass "--list-images does not deploy"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/airgap/test_list_images.sh`
Expected: FAIL — `Unknown option: --list-images`.

- [ ] **Step 3: Implement**

In `deploy.sh`, add to the argument `case` block, next to `--render`:

```bash
    --list-images) LIST_IMAGES=true; shift ;;
```

and initialise `LIST_IMAGES=false` beside `RENDER=false`.

Extract the existing pre-pull extractor into a function placed just above the pre-pull block. Move the heredoc python verbatim — it already drops inline YAML comments and skips unresolved references:

```bash
# Resolve every `image:` reference in the assembled files against the CURRENT
# environment. Shared by --list-images and the pre-pull so the bundle can never
# disagree with what the deploy will ask for.
resolve_image_list() {
  python3 - "$@" <<'PY'
import sys, os, re
seen = set()
for fn in sys.argv[1:]:
    try:
        lines = open(fn).read().splitlines()
    except OSError:
        continue
    for ln in lines:
        m = re.match(r"\s*image:\s*(.+?)\s*$", ln)
        if not m:
            continue
        raw = re.sub(r"\s+#.*$", "", m.group(1).strip()).strip()
        img = os.path.expandvars(raw.strip("'\""))
        if "$" in img or not img or img in seen:
            continue
        seen.add(img)
        print(img)
PY
}
```

Replace the pre-pull's inline heredoc with `resolve_image_list "${_pp_files[@]}" | xargs -r -P 4 -n 1 sh -c '…'`, leaving the retry/timeout wrapper untouched.

Then, immediately after the env sourcing in the swarm branch (anchor: the line `for bf in "$BUNDLE_DIR"/.env.*; do source "$bf"; done`) and before the deploy-state snapshot, add:

```bash
  if [[ "$LIST_IMAGES" == true ]]; then
    _li_files=(); for f in "${FILES[@]}"; do [[ "$f" == -f ]] || _li_files+=("$f"); done
    resolve_image_list "${_li_files[@]}"
    exit 0
  fi
```

Mirror the same block in the compose branch after its env sourcing, so both runtimes answer the flag.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/airgap/test_list_images.sh`
Expected: all assertions PASS.

- [ ] **Step 5: Check the drift guard by hand once**

Run: `cd unified && ./scripts/deploy.sh --runtime swarm --edition ee --list-images | wc -l`
Expected: a count in the 50s. Compare against `grep -c '^\s*image:' base/*.yml runtime/swarm/*.yml` — the list may be smaller (duplicated references collapse) but never larger.

- [ ] **Step 6: Commit**

```bash
git add unified/scripts/deploy.sh tests/airgap/test_list_images.sh
git commit -m "feat(deploy): add --list-images as the single source of the image set"
```

---

## Task 3: `deploy.sh --airgap`

**Files:**
- Modify: `unified/scripts/deploy.sh` — argument `case`, the pre-pull block, the `docker stack deploy` invocation (anchor: `docker stack deploy --detach=true --with-registry-auth --prune`)
- Test: `tests/airgap/test_airgap_flag.sh`

**Interfaces:**
- Consumes: Task 2's `resolve_image_list`.
- Produces: `deploy.sh --airgap` — no pull is emitted; `docker stack deploy` carries `--resolve-image never` and not `--with-registry-auth`.

- [ ] **Step 1: Write the failing test**

Create `tests/airgap/test_airgap_flag.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

# A stack deploy needs an env file; use the dummy test env shipped in the tree.
run_deploy() {
  with_docker_stub ./scripts/deploy.sh --runtime swarm --edition ce \
    --env test --stack airgap-test "$@" >/dev/null 2>&1 || true
}

run_deploy --airgap
log="$(cat "$DOCKER_LOG")"
if grep -qE '^pull ' <<<"$log"; then fail "--airgap still pulled images"; fi
pass "--airgap emits no pull"
assert_contains "$log" "--resolve-image never" "--airgap passes --resolve-image never"
if grep -q -- "--with-registry-auth" <<<"$log"; then fail "--airgap kept --with-registry-auth"; fi
pass "--airgap drops --with-registry-auth"

# Without the flag, the pre-pull must still happen — this guards the online path.
run_deploy
assert_contains "$(cat "$DOCKER_LOG")" "pull " "online deploy still pre-pulls"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/airgap/test_airgap_flag.sh`
Expected: FAIL — `Unknown option: --airgap`.

- [ ] **Step 3: Implement**

Add `AIRGAP=false` beside `RENDER=false`, and to the `case` block:

```bash
    --airgap)    AIRGAP=true; shift ;;
```

Guard the pre-pull block:

```bash
  if [[ "$AIRGAP" == true ]]; then
    echo "▶ airgap: skipping the pre-pull; images must already be loaded (see airgap.sh)"
  else
    … existing pre-pull …
  fi
```

Build the deploy flags instead of hardcoding them, replacing the `docker stack deploy` line:

```bash
  # `--resolve-image never` is REQUIRED offline: the default (`always`) contacts
  # the registry for every tag→digest even when the image is already local.
  DEPLOY_FLAGS=(--detach=true --prune)
  if [[ "$AIRGAP" == true ]]; then
    DEPLOY_FLAGS+=(--resolve-image never)
  else
    DEPLOY_FLAGS+=(--with-registry-auth)
  fi
  docker stack deploy "${DEPLOY_FLAGS[@]}" "${C_FILES[@]}" "$STACK"
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/airgap/test_airgap_flag.sh`
Expected: all assertions PASS.

- [ ] **Step 5: Commit**

```bash
git add unified/scripts/deploy.sh tests/airgap/test_airgap_flag.sh
git commit -m "feat(deploy): add --airgap (no pre-pull, --resolve-image never)"
```

---

## Task 4: `airgap.sh prepare` — guards, tree, manifest

**Files:**
- Create: `unified/scripts/airgap.sh`
- Test: `tests/airgap/test_prepare_tree.sh`

**Interfaces:**
- Consumes: `deploy.sh --list-images`.
- Produces: `airgap.sh prepare --runtime R --edition E [--groups G] [--env ENV] [--out DIR] [--max-part-size SIZE] [--harvest-from CTX]` creating `<out>/industream-airgap-<commit>-<edition>-<runtime>/` containing `tree/`, `bundle.json`, `MANIFEST.sha256`. `bundle.json` keys: `commit`, `edition`, `runtime`, `groups`, `env`, `created`, `images[]`, `uncompressed_bytes`.

- [ ] **Step 1: Write the failing test**

Create `tests/airgap/test_prepare_tree.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"
out="$(mktemp -d)"

# 1. A dirty tracked file must abort the build: what ships must be what was tested.
touch "$REPO_ROOT/unified/versions.env.dirtytest"
git -C "$REPO_ROOT" add -N unified/versions.env.dirtytest
assert_fails ./scripts/airgap.sh prepare --runtime swarm --edition ce --out "$out" \
  "prepare refuses a dirty working tree"
git -C "$REPO_ROOT" rm --cached -q unified/versions.env.dirtytest
rm -f "$REPO_ROOT/unified/versions.env.dirtytest"

# 2. On a clean tree it must produce the tree and the manifest.
bundle="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$out" --skip-images --skip-assets | tail -1)"
[[ -d "$bundle/tree" ]] || fail "tree/ missing"
pass "tree/ produced"
[[ -f "$bundle/tree/unified/scripts/deploy.sh" ]] || fail "deploy.sh missing from the tree"
pass "tree carries deploy.sh"
[[ -f "$bundle/bundle.json" ]] || fail "bundle.json missing"
pass "bundle.json produced"
assert_contains "$(cat "$bundle/bundle.json")" '"edition": "ce"' "bundle.json records the edition"
[[ -f "$bundle/MANIFEST.sha256" ]] || fail "MANIFEST.sha256 missing"
pass "manifest produced"

# 3. The resolved bundle .env.* must travel even when untracked — git archive
#    alone would deliver a stack whose images resolve to empty strings.
[[ -n "$(find "$bundle/tree/unified/releases" -name '.env.*' -print -quit)" ]] \
  || fail "bundle .env.* files missing from the tree"
pass "bundle .env.* travel with the tree"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/airgap/test_prepare_tree.sh`
Expected: FAIL — `airgap.sh` does not exist.

- [ ] **Step 3: Implement**

Create `unified/scripts/airgap.sh` with the argument parsing, the guards and the tree step. `--skip-images` and `--skip-assets` exist for the tests and for a fast tree-only rebuild; they are documented as such.

```bash
#!/usr/bin/env bash
# =============================================================================
# airgap.sh — build and verify an offline bundle for a site with no internet.
# =============================================================================
#   ./airgap.sh prepare --runtime swarm --edition ee --out /media/usb
#   ./airgap.sh verify  /media/usb/industream-airgap-<commit>-ee-swarm
#
# Design: docs/specs/2026-09-03-airgap-bundle-design.md
# The image set ALWAYS comes from `deploy.sh --list-images` — never a second
# list, which would drift the first time a group is added.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # unified/
REPO="$(cd "$HERE/.." && pwd)"

RUNTIME="" EDITION="ce" ENV="prod" GROUPS="" OUT="." HARVEST_FROM=""
MAX_PART_SIZE="3800M" SKIP_IMAGES=false SKIP_ASSETS=false

die() { echo "✗ $*" >&2; exit 1; }

cmd_prepare() {
  [[ "$RUNTIME" == swarm || "$RUNTIME" == compose ]] || die "--runtime swarm|compose required"

  # What ships must be what was tested. A tracked file modified locally means
  # the archive below would not match the code under test — and an untracked
  # file a script calls would simply be absent on site.
  [[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]] \
    || die "working tree is dirty — commit or stash before building a bundle"

  local commit; commit="$(git -C "$REPO" rev-parse --short HEAD)"
  local name="industream-airgap-${commit}-${EDITION}-${RUNTIME}"
  local dest="$OUT/$name"
  rm -rf "$dest"; mkdir -p "$dest/tree" "$dest/images" "$dest/assets" "$dest/os"

  echo "▶ tree (git archive $commit)"
  git -C "$REPO" archive HEAD | tar -x -C "$dest/tree"

  # deploy.sh sources "$BUNDLE_DIR"/.env.* and several of those are not
  # committed (the secrets hook blocks `git add` on them), so the archive alone
  # is not enough.
  echo "▶ resolved bundle env files"
  ( cd "$HERE" && find releases -name '.env.*' -type f -print0 ) \
    | ( cd "$HERE" && xargs -0 -r -I{} cp --parents {} "$dest/tree/unified/" )

  local groups_args=(); [[ -n "$GROUPS" ]] && groups_args=(--groups "$GROUPS")
  echo "▶ resolving the image set"
  local images
  images="$( cd "$HERE" && ./scripts/deploy.sh --runtime "$RUNTIME" --edition "$EDITION" \
      --env "$ENV" "${groups_args[@]}" --list-images )"
  [[ -n "$images" ]] || die "the image list is empty — check --edition/--groups"

  [[ "$SKIP_IMAGES" == true ]] || save_images "$dest" "$images"
  [[ "$SKIP_ASSETS" == true ]] || harvest_assets "$dest"

  write_bundle_json "$dest" "$commit" "$images"
  ( cd "$dest" && find . -type f ! -name MANIFEST.sha256 -print0 \
      | xargs -0 sha256sum > MANIFEST.sha256 )
  cp "$HERE/scripts/airgap-install.sh" "$dest/install.sh" 2>/dev/null || true
  chmod +x "$dest/install.sh" 2>/dev/null || true

  echo "▶ $dest"
  echo "$dest"
}

# UNCOMPRESSED_BYTES is accumulated by save_images and recorded in bundle.json;
# install.sh sizes its disk preflight from it.
UNCOMPRESSED_BYTES=0

write_bundle_json() {
  local dest="$1" commit="$2" images="$3"
  python3 - "$dest" "$commit" "$EDITION" "$RUNTIME" "$ENV" "$GROUPS" "$UNCOMPRESSED_BYTES" <<PY
import json, sys, datetime
dest, commit, edition, runtime, env, groups, uncompressed = sys.argv[1:8]
images = """$images""".split()
json.dump({
    "commit": commit, "edition": edition, "runtime": runtime, "env": env,
    "groups": groups, "created": datetime.datetime.now().isoformat(timespec="seconds"),
    "uncompressed_bytes": int(uncompressed), "images": images,
}, open(dest + "/bundle.json", "w"), indent=2)
PY
}

save_images()   { :; }   # Task 5
harvest_assets(){ :; }   # Task 6

# Dispatch. `_split` is exposed so the splitting logic is directly testable.
case "${1:-}" in
  prepare) shift; parse_args "$@"; cmd_prepare ;;
  verify)  shift; cmd_verify "$@" ;;
  _split)  shift; cmd_split "$@" ;;
  *)       die "usage: airgap.sh prepare|verify <args>" ;;
esac
```

`parse_args` is the same `while [[ $# -gt 0 ]]` / `case` loop as `deploy.sh`, accepting `--runtime --edition --env --groups --out --max-part-size --harvest-from --skip-images --skip-assets`.

Note that `bundle.json` has no `stack` key: the swarm stack name is a site property, not a build property. `install.sh` takes it from `--stack`, defaulting to `industream-prod`.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/airgap/test_prepare_tree.sh`
Expected: all assertions PASS.

- [ ] **Step 5: Commit**

```bash
git add unified/scripts/airgap.sh tests/airgap/test_prepare_tree.sh
git commit -m "feat(airgap): prepare builds the tree, bundle.json and manifest"
```

---

## Task 5: `airgap.sh prepare` — save and split images

**Files:**
- Modify: `unified/scripts/airgap.sh` — replace the `save_images()` stub
- Test: `tests/airgap/test_prepare_images.sh`

**Interfaces:**
- Consumes: the image list from Task 4.
- Produces: `images/<group>.tar.zst`, split into `.00`, `.01` … when above `--max-part-size`; `PARTS.sha256` listing every part.

- [ ] **Step 1: Write the failing test**

Create `tests/airgap/test_prepare_images.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"
out="$(mktemp -d)"

bundle="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$out" --skip-assets | tail -1)"
log="$(cat "$DOCKER_LOG")"

# An image already present locally must not be pulled; the stub reports every
# `image inspect` as absent, so a pull per image is expected here.
assert_contains "$log" "pull " "absent images are pulled"
assert_contains "$log" "save " "images are saved"

# One tarball per group, not one per image.
(( $(ls "$bundle/images" | wc -l) < $(python3 -c "import json;print(len(json.load(open('$bundle/bundle.json'))['images']))") )) \
  || fail "images are not grouped"
pass "images are grouped into per-group tarballs"

# Splitting: a 5 MB file with a 1 MB cap must yield parts that concatenate back
# to the same bytes.
big="$out/big.bin"; head -c 5000000 /dev/urandom > "$big"
sum_before="$(sha256sum < "$big" | cut -d' ' -f1)"
./scripts/airgap.sh _split "$big" 1M
[[ -f "$big.00" ]] || fail "split produced no parts"
pass "split produced parts"
assert_eq "$(cat "$big".* | sha256sum | cut -d' ' -f1)" "$sum_before" "parts concatenate to the original"
[[ ! -f "$big" ]] || fail "the original was left behind, doubling the bundle size"
pass "the original is removed after splitting"

# A file under the cap must be left intact.
small="$out/small.bin"; head -c 1000 /dev/urandom > "$small"
./scripts/airgap.sh _split "$small" 1M
[[ -f "$small" && ! -f "$small.00" ]] || fail "a small file was split anyway"
pass "files under the cap are left intact"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/airgap/test_prepare_images.sh`
Expected: FAIL — no `images/` produced, `_split` unknown.

- [ ] **Step 3: Implement**

```bash
# Split a file that exceeds the cap into numbered parts and drop the original —
# keeping it would double the bundle's size on the transport medium. Parts are
# streamed back with `cat parts | zstd -dc | docker load`, so they are never
# reassembled on the target's disk.
cmd_split() {
  local f="$1" cap="$2"
  [[ "$cap" == 0 ]] && return 0
  local bytes cap_bytes
  bytes="$(stat -c%s "$f")"
  cap_bytes="$(numfmt --from=iec "$cap")"
  (( bytes <= cap_bytes )) && return 0
  split -d -a 2 -b "$cap" "$f" "$f."
  rm -f "$f"
}

# One tarball per group. A single archive would deduplicate shared layers best
# (`docker save` writes each layer once per invocation) but cannot be resumed;
# per-group tarballs cost some duplication of the workers' shared base layers
# and buy file-by-file recovery on a flaky transport.
save_images() {
  local dest="$1" images="$2" group img
  for group in $(group_names); do
    local set; set="$(images_for_group "$group" "$images")"
    [[ -z "$set" ]] && continue
    echo "▶ images: $group"
    for img in $set; do
      if docker image inspect "$img" >/dev/null 2>&1; then
        echo "  local  $img"
      else
        echo "  pull   $img"
        docker pull "$img" || die "cannot pull $img — build the bundle from a connected machine"
      fi
      UNCOMPRESSED_BYTES=$(( UNCOMPRESSED_BYTES + $(docker image inspect -f '{{.Size}}' "$img" 2>/dev/null || echo 0) ))
    done
    # shellcheck disable=SC2086
    docker save $set | zstd -T0 -3 > "$dest/images/$group.tar.zst"
    cmd_split "$dest/images/$group.tar.zst" "$MAX_PART_SIZE"
  done
  ( cd "$dest" && find images -type f -print0 | xargs -0 sha256sum > PARTS.sha256 )
}

# Grouping, like the list itself, comes from the deploy — never from a table.
# render-bundles.sh already shipped a hand-maintained TABLE that silently
# omitted six workers; this must not acquire a second one.
group_names() {
  if [[ -n "$GROUPS" ]]; then echo "$GROUPS"
  else ( cd "$HERE" && ./scripts/deploy.sh --runtime "$RUNTIME" --edition "$EDITION" \
           --env "$ENV" --print-groups ); fi
}

# The images of ONE group, intersected with the full set so that a group whose
# images are all shared with another still yields a coherent tarball.
images_for_group() {
  local group="$1" all="$2"
  comm -12 \
    <( cd "$HERE" && ./scripts/deploy.sh --runtime "$RUNTIME" --edition "$EDITION" \
         --env "$ENV" --groups "$group" --list-images | sort -u ) \
    <( sort -u <<<"$all" )
}
```

`--print-groups` is a two-line addition to `deploy.sh` in the same place as `--list-images`: it echoes `$GROUP_SET` and exits, so the default footprint is never restated here either.

Add it in Task 2's Step 3 alongside `--list-images`:

```bash
    --print-groups) PRINT_GROUPS=true; shift ;;
```

and, next to the `--list-images` block:

```bash
  if [[ "$PRINT_GROUPS" == true ]]; then echo "$GROUP_SET"; exit 0; fi
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/airgap/test_prepare_images.sh`
Expected: all assertions PASS.

- [ ] **Step 5: Commit**

```bash
git add unified/scripts/airgap.sh tests/airgap/test_prepare_images.sh
git commit -m "feat(airgap): save images per group, split above the part cap"
```

---

## Task 6: `airgap.sh prepare` — harvest runtime assets

**Files:**
- Modify: `unified/scripts/airgap.sh` — replace the `harvest_assets()` stub
- Test: `tests/airgap/test_prepare_assets.sh`

**Interfaces:**
- Produces: `assets/grafana-plugins/` and `assets/cdn-packages/{cdn-server-storage,cdn-cache-storage}/`.

- [ ] **Step 1: Write the failing test**

Create `tests/airgap/test_prepare_assets.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"
out="$(mktemp -d)"

# The Grafana plugins are obtained by RUNNING the Grafana image with the exact
# preinstall list — never by re-implementing the download, which is what once
# left a 22MB fragment of a 25.8MB plugin in the volume.
bundle="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$out" --skip-images | tail -1)" || true
log="$(cat "$DOCKER_LOG")"
assert_contains "$log" "GF_PLUGINS_PREINSTALL_SYNC" "grafana is run with the real preinstall list"

# An empty CDN cache must abort: shipping one is the HO8 failure mode, and it
# surfaces later as FlowMaker boxes with no definition.
assert_contains "$(bash -c "AIRGAP_FAKE_EMPTY_CDN=1 ./scripts/airgap.sh prepare \
  --runtime swarm --edition ce --out $out --skip-images 2>&1" || true)" \
  "CDN cache is empty" "an empty CDN cache aborts the build"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/airgap/test_prepare_assets.sh`
Expected: FAIL — no `GF_PLUGINS_PREINSTALL_SYNC` in the log.

- [ ] **Step 3: Implement**

```bash
# Assets are HARVESTED from a real, connected instance, never rebuilt.
harvest_assets() {
  local dest="$1"
  local docker_ctx=(); [[ -n "$HARVEST_FROM" ]] && docker_ctx=(--context "$HARVEST_FROM")

  # --- Grafana plugins -------------------------------------------------------
  # base/monitoring.yml installs these with GF_PLUGINS_PREINSTALL_SYNC, which is
  # deliberately boot-blocking: offline, a missing plugin means Grafana does not
  # start at all. Run the real image with the real list and take what it built.
  echo "▶ assets: grafana plugins"
  # shellcheck disable=SC1091
  set -a; source "$HERE/versions.env"; set +a
  local preinstall="yesoreyeram-infinity-datasource,marcusolsson-json-datasource,volkovlabs-echarts-panel${GRAFANA_DATABRIDGE_PLUGIN}"
  mkdir -p "$dest/assets/grafana-plugins"
  docker "${docker_ctx[@]}" run --rm \
    -e "GF_PLUGINS_PREINSTALL_SYNC=$preinstall" \
    -e GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=industream-databridge-datasource,industream-hubbridge-app \
    -v "$dest/assets/grafana-plugins:/out" \
    --entrypoint /bin/sh "grafana/grafana-oss:${GRAFANA_VERSION}" \
    -c 'grafana cli --pluginsDir /var/lib/grafana/plugins plugins ls >/dev/null 2>&1;
        cp -a /var/lib/grafana/plugins/. /out/ 2>/dev/null || true'
  [[ -n "$(ls -A "$dest/assets/grafana-plugins")" ]] \
    || die "no Grafana plugin was produced — Grafana will not boot offline"

  # --- CDN packages ----------------------------------------------------------
  # cdn-server (Verdaccio) proxies npmjs and publishes on demand, so offline it
  # stays empty and FlowMaker boxes lose their definitions. Copy the volumes of
  # an instance that has ACTUALLY served them.
  echo "▶ assets: cdn packages"
  local v
  for v in cdn-server-storage cdn-cache-storage; do
    mkdir -p "$dest/assets/cdn-packages/$v"
    docker "${docker_ctx[@]}" run --rm \
      -v "${AIRGAP_STACK:-industream-prod}_${v}:/src:ro" \
      -v "$dest/assets/cdn-packages/$v:/out" \
      alpine sh -c 'cp -a /src/. /out/ 2>/dev/null || true'
  done
  if [[ -n "${AIRGAP_FAKE_EMPTY_CDN:-}" ]] \
     || [[ -z "$(find "$dest/assets/cdn-packages" -type f -print -quit)" ]]; then
    die "CDN cache is empty — harvest from a warmed instance (--harvest-from) or the boxes will have no definition on site"
  fi
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/airgap/test_prepare_assets.sh`
Expected: all assertions PASS.

- [ ] **Step 5: Verify the plugin harvest once against a real daemon**

Run: `cd unified && ./scripts/airgap.sh prepare --runtime swarm --edition ce --out /tmp/ag --skip-images`
Expected: `/tmp/ag/*/assets/grafana-plugins/` contains four directories, including `industream-databridge-datasource` with a `plugin.json`. If it does not, the entrypoint override is wrong for this Grafana version — fix it here, not on site.

- [ ] **Step 6: Commit**

```bash
git add unified/scripts/airgap.sh tests/airgap/test_prepare_assets.sh
git commit -m "feat(airgap): harvest grafana plugins and CDN packages from a live instance"
```

---

## Task 7: `airgap.sh verify`

**Files:**
- Modify: `unified/scripts/airgap.sh` — add `cmd_verify`
- Test: `tests/airgap/test_verify.sh`

**Interfaces:**
- Produces: `airgap.sh verify <bundle>` exits 0 when the bundle is complete and self-consistent, non-zero otherwise, naming what is missing.

- [ ] **Step 1: Write the failing test**

Create `tests/airgap/test_verify.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"
out="$(mktemp -d)"
bundle="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$out" --skip-images --skip-assets | tail -1)"

with_docker_stub ./scripts/airgap.sh verify "$bundle" >/dev/null \
  || fail "a freshly built bundle does not verify"
pass "a fresh bundle verifies"

# Corrupting a file must be caught by the manifest.
echo tampered >> "$bundle/tree/unified/versions.env"
assert_fails ./scripts/airgap.sh verify "$bundle" "a tampered file fails verification"
git -C "$REPO_ROOT" show HEAD:unified/versions.env > "$bundle/tree/unified/versions.env"

# Dropping an image from the manifest must be caught by replaying the list
# against the bundle's OWN tree — this is what catches a group added between
# build and departure.
python3 - "$bundle/bundle.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["images"].pop(); json.dump(d, open(p, "w"))
PY
assert_fails ./scripts/airgap.sh verify "$bundle" "a missing image fails verification"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/airgap/test_verify.sh`
Expected: FAIL — `verify` is not implemented.

- [ ] **Step 3: Implement**

```bash
# verify is replayable on BOTH sides: before shipping, and on site before
# touching Docker.
cmd_verify() {
  local b="${1:?usage: airgap.sh verify <bundle>}"
  [[ -f "$b/bundle.json" ]] || die "not a bundle: $b"

  echo "▶ checksums"
  ( cd "$b" && sha256sum --quiet -c MANIFEST.sha256 ) || die "manifest mismatch"
  [[ -f "$b/PARTS.sha256" ]] && { ( cd "$b" && sha256sum --quiet -c PARTS.sha256 ) || die "part mismatch"; }

  echo "▶ image set"
  # Replay the resolution against the bundle's OWN tree, so a group added after
  # the build is caught here rather than as an empty image on site.
  local edition runtime env groups expected have
  eval "$(python3 -c "
import json;d=json.load(open('$b/bundle.json'))
print(f'''edition={d[\"edition\"]}; runtime={d[\"runtime\"]}; env={d[\"env\"]}; groups=\"{d[\"groups\"]}\"''')")"
  local groups_args=(); [[ -n "$groups" ]] && groups_args=(--groups "$groups")
  expected="$( cd "$b/tree/unified" && ./scripts/deploy.sh --runtime "$runtime" \
      --edition "$edition" --env "$env" "${groups_args[@]}" --list-images | sort )"
  have="$(python3 -c "import json;print('\n'.join(sorted(json.load(open('$b/bundle.json'))['images'])))")"
  local missing; missing="$(comm -23 <(echo "$expected") <(echo "$have"))"
  [[ -z "$missing" ]] || die "images required by the tree but absent from the bundle:
$missing"
  echo "✓ bundle verified ($(wc -l <<<"$have") images)"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/airgap/test_verify.sh`
Expected: all assertions PASS.

- [ ] **Step 5: Commit**

```bash
git add unified/scripts/airgap.sh tests/airgap/test_verify.sh
git commit -m "feat(airgap): verify checksums and replay the image set against the bundle tree"
```

---

## Task 8: `install.sh` — preflights and image load

**Files:**
- Create: `unified/scripts/airgap-install.sh`
- Test: `tests/airgap/test_install_preflight.sh`

**Interfaces:**
- Produces: `install.sh [--target DIR] [--yes]` run from inside the bundle. Reads `bundle.json` for edition/runtime/groups/env.

- [ ] **Step 1: Write the failing test**

Create `tests/airgap/test_install_preflight.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"
out="$(mktemp -d)"; target="$(mktemp -d)"
bundle="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$out" --skip-images --skip-assets | tail -1)"

# Disk space is checked on /var/lib/containerd as well as /var/lib/docker:
# Docker 29 stores images in the former (22GB vs 4KB measured), and checking
# only the latter is how a machine froze mid-install.
assert_contains "$(grep -c 'containerd' "$REPO_ROOT/unified/scripts/airgap-install.sh")" "" ""
grep -q '/var/lib/containerd' "$REPO_ROOT/unified/scripts/airgap-install.sh" \
  || fail "the disk preflight ignores /var/lib/containerd"
pass "disk preflight covers containerd"

# Clock drift breaks proxy TLS and Hub JWT with errors that never mention time.
grep -q 'clock\|chrony\|timedatectl' "$REPO_ROOT/unified/scripts/airgap-install.sh" \
  || fail "no clock preflight"
pass "clock preflight present"

# install.sh must never offer a teardown: deploy.sh --down destroys caddy_data,
# hence the CA, hence every workstation that trusted the certificate.
if grep -q -- '--down' "$REPO_ROOT/unified/scripts/airgap-install.sh"; then
  fail "install.sh exposes --down"
fi
pass "install.sh exposes no --down"

# A bundle that does not verify must stop before Docker is touched.
echo tampered >> "$bundle/tree/unified/versions.env"
out_log="$(with_docker_stub bash "$bundle/install.sh" --target "$target" --yes 2>&1 || true)"
assert_contains "$out_log" "manifest mismatch" "install stops on a bad manifest"
if grep -q "load" "$DOCKER_LOG" 2>/dev/null; then fail "install loaded images despite a bad manifest"; fi
pass "no image was loaded after a failed verification"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/airgap/test_install_preflight.sh`
Expected: FAIL — `airgap-install.sh` does not exist.

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
# =============================================================================
# install.sh — install or update the platform from an offline bundle.
# =============================================================================
# Same script for a first install and for an update; the only difference is
# what is already on the machine. Run it from inside the unpacked bundle.
#
# There is deliberately NO teardown option: `deploy.sh --down` removes
# caddy_data, hence the CA, hence every workstation that trusted the cert.
# =============================================================================
set -euo pipefail
BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${TARGET:-$HOME/industream-platform}"
ASSUME_YES=false

die() { echo "✗ $*" >&2; exit 1; }

# Read one key from bundle.json, with a fallback for keys a bundle may not
# carry (the swarm stack name is a site property, not a build property).
json_get() {
  python3 -c "
import json,sys
d=json.load(open('$BUNDLE/bundle.json'))
print(d.get('$1', '''${2:-}'''))"
}

preflight() {
  command -v docker >/dev/null || die "docker is not installed"

  local runtime; runtime="$(json_get runtime)"
  if [[ "$runtime" == swarm ]]; then
    [[ "$(docker info -f '{{.Swarm.LocalNodeState}}' 2>/dev/null)" == active ]] \
      || die "this node is not in an active swarm — run 'docker swarm init' first"
  fi

  # Docker 29 stores images under /var/lib/containerd, NOT /var/lib/docker.
  # Checking only the latter is how a machine froze mid-install with 22GB
  # landing on a 20GB root.
  local need_kb dir
  need_kb="$(( $(json_get uncompressed_bytes 0) / 1024 + 2097152 ))"
  for dir in /var/lib/containerd /var/lib/docker; do
    [[ -d "$dir" ]] || continue
    local free_kb; free_kb="$(df -Pk "$dir" | awk 'NR==2{print $4}')"
    (( free_kb >= need_kb )) \
      || die "not enough free space on $dir: $((free_kb/1024))MB free, $((need_kb/1024))MB needed"
  done

  # A wrong clock breaks proxy TLS and Hub JWT with errors that never mention
  # time — the most expensive class of failure to diagnose on site.
  if command -v timedatectl >/dev/null; then
    timedatectl show -p NTPSynchronized --value | grep -q yes \
      || echo "⚠ clock is not NTP-synchronised — TLS and JWT failures will look like anything but a clock problem" >&2
  fi

  echo "▶ verifying the bundle"
  bash "$BUNDLE/tree/unified/scripts/airgap.sh" verify "$BUNDLE" || exit 1
}

load_images() {
  local base
  # Parts are streamed straight into docker load: never reassembled, so the
  # bundle is never duplicated on a disk that may not have room for it.
  for base in $(ls "$BUNDLE/images" 2>/dev/null | sed 's/\.[0-9][0-9]$//' | sort -u); do
    echo "▶ loading $base"
    cat "$BUNDLE/images/$base" "$BUNDLE/images/$base".[0-9][0-9] 2>/dev/null \
      | zstd -dc | docker load
  done
}
```

`json_get` reads a key from `bundle.json` with `python3`. Wire `preflight` then `load_images` into `main`, with `--target` and `--yes` parsing.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/airgap/test_install_preflight.sh`
Expected: all assertions PASS.

- [ ] **Step 5: Commit**

```bash
git add unified/scripts/airgap-install.sh tests/airgap/test_install_preflight.sh
git commit -m "feat(airgap): install preflights and streamed image load"
```

---

## Task 9: `install.sh` — tree sync and asset seeding

**Files:**
- Modify: `unified/scripts/airgap-install.sh`
- Test: `tests/airgap/test_install_sync.sh`

**Interfaces:**
- Produces: `sync_tree` and `seed_assets` called between `load_images` and the deploy. Writes `<target>/AIRGAP_VERSION` (commit and bundle name).

- [ ] **Step 1: Write the failing test**

Create `tests/airgap/test_install_sync.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"
out="$(mktemp -d)"; target="$(mktemp -d)"
bundle="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --out "$out" --skip-images --skip-assets | tail -1)"

# Pre-existing site state that MUST survive an update. All three have already
# been clobbered on these hosts.
mkdir -p "$target/unified/custom" "$target/secrets/prod" "$target/unified/instances"
echo "SITE_SECRET=keepme"   > "$target/unified/.env.prod"
echo "custom-overlay"       > "$target/unified/custom/site.yml"
echo "s3cret"               > "$target/secrets/prod/hub_backend_admin_password"

with_docker_stub bash "$bundle/install.sh" --target "$target" --yes --no-deploy >/dev/null 2>&1 || true

assert_eq "$(cat "$target/unified/.env.prod")" "SITE_SECRET=keepme" ".env.<env> survives the sync"
assert_eq "$(cat "$target/unified/custom/site.yml")" "custom-overlay" "custom/ survives the sync"
assert_eq "$(cat "$target/secrets/prod/hub_backend_admin_password")" "s3cret" "secrets/ survive the sync"
[[ -f "$target/unified/scripts/deploy.sh" ]] || fail "the tree was not synced"
pass "the tree was synced"
[[ -f "$target/AIRGAP_VERSION" ]] || fail "AIRGAP_VERSION not written"
pass "AIRGAP_VERSION written"
[[ -n "$(ls "$target/backups" 2>/dev/null)" ]] || fail "no rollback snapshot was taken"
pass "a rollback snapshot was taken"

# Assets must be seeded on EVERY run, not only the first: a bumped
# GRAFANA_DATABRIDGE_PLUGIN would otherwise send Grafana looking for a version
# it cannot reach, and the preinstall is boot-blocking.
# The swarm overlays pin `name: ${ENV}-<volume>`, so the real volume is
# `prod-grafana-data` — seeding `<stack>_grafana-data` would create an unused
# volume and leave Grafana unable to boot.
assert_contains "$(cat "$DOCKER_LOG")" "prod-grafana-data" "grafana plugins are seeded into the ENV-prefixed volume"
assert_contains "$(cat "$DOCKER_LOG")" "prod-cdn-server-storage" "CDN packages are seeded into the ENV-prefixed volume"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/airgap/test_install_sync.sh`
Expected: FAIL — `--no-deploy` unknown, nothing synced.

- [ ] **Step 3: Implement**

```bash
# Never `git reset --hard`, never a bare `cp -r`: both have already destroyed
# untracked site state on these hosts. rsync with hard exclusions, after a
# snapshot that makes the previous tree recoverable.
sync_tree() {
  mkdir -p "$TARGET/backups"
  if [[ -d "$TARGET/unified" ]]; then
    local snap="$TARGET/backups/tree-$(date +%Y%m%d-%H%M%S).tar.gz"
    echo "▶ snapshotting the current tree → $snap"
    tar czf "$snap" -C "$TARGET" --exclude=backups .
  fi
  echo "▶ syncing the tree"
  rsync -a --delete \
    --exclude='.env.*' \
    --exclude='secrets/' \
    --exclude='unified/custom/' \
    --exclude='unified/instances/' \
    --exclude='.deploy-state/' \
    --exclude='backups/' \
    "$BUNDLE/tree/" "$TARGET/"
  # The checkout is knowingly detached from origin: offline it will never take
  # another `git pull`, so record what it actually holds.
  printf 'commit=%s\nbundle=%s\ninstalled=%s\n' \
    "$(json_get commit)" "$(basename "$BUNDLE")" "$(date -Is)" > "$TARGET/AIRGAP_VERSION"
}

# Seeded on EVERY deploy, not only the first. GF_PLUGINS_PREINSTALL_SYNC is
# boot-blocking, so a plugin version bump with no reachable registry would stop
# Grafana from starting at all.
# Volume names differ per runtime, and NOT the way the `<stack>_<volume>`
# default would suggest: the swarm overlays pin an explicit
# `name: ${ENV}-<volume>` (runtime/swarm/monitoring.yml:219, core.yml:184-188),
# so the real volume is `prod-grafana-data`. Compose declares no name, so it
# gets the `<project>_<volume>` default. Seeding the wrong name silently
# creates an unused volume and leaves Grafana unable to boot.
volume_name() {
  if [[ "$(json_get runtime)" == swarm ]]; then echo "$(json_get env)-$1"
  else echo "${PROJECT:-fm-$(json_get env)}_$1"; fi
}

seed_assets() {
  seed_volume() {
    local vol="$1" src="$2" sub="${3:-}"
    [[ -d "$src" && -n "$(ls -A "$src")" ]] || return 0
    docker volume create "$vol" >/dev/null
    docker run --rm -v "$vol:/dest" -v "$src:/src:ro" alpine \
      sh -c "mkdir -p /dest/$sub && cp -a /src/. /dest/$sub"
  }
  echo "▶ seeding runtime assets"
  seed_volume "$(volume_name grafana-data)"       "$BUNDLE/assets/grafana-plugins"                 "plugins"
  seed_volume "$(volume_name cdn-server-storage)" "$BUNDLE/assets/cdn-packages/cdn-server-storage"
  seed_volume "$(volume_name cdn-cache-storage)"  "$BUNDLE/assets/cdn-packages/cdn-cache-storage"
}
```

Add `--no-deploy` (used by the tests and by an operator who wants to stage the change and deploy in a maintenance window).

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/airgap/test_install_sync.sh`
Expected: all assertions PASS.

- [ ] **Step 5: Commit**

```bash
git add unified/scripts/airgap-install.sh tests/airgap/test_install_sync.sh
git commit -m "feat(airgap): sync the tree with hard exclusions and seed runtime assets"
```

---

## Task 10: `install.sh` — deploy, and the runbook

**Files:**
- Modify: `unified/scripts/airgap-install.sh`
- Create: `docs/runbook/airgap.md`
- Test: `tests/airgap/test_install_deploy.sh`

**Interfaces:**
- Produces: `install.sh` ends by calling `deploy.sh --airgap` with the edition, runtime, groups and env from `bundle.json`, each overridable.

- [ ] **Step 1: Write the failing test**

Create `tests/airgap/test_install_deploy.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"
out="$(mktemp -d)"; target="$(mktemp -d)"
bundle="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ee \
  --out "$out" --skip-images --skip-assets | tail -1)"

with_docker_stub bash "$bundle/install.sh" --target "$target" --yes >/dev/null 2>&1 || true
log="$(cat "$DOCKER_LOG")"
assert_contains "$log" "--resolve-image never" "the deploy runs in airgap mode"
if grep -qE '^pull ' <<<"$log"; then fail "the install pulled an image"; fi
pass "the install pulls nothing"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/airgap/test_install_deploy.sh`
Expected: FAIL — no `stack deploy` recorded.

- [ ] **Step 3: Implement**

```bash
run_deploy() {
  local args=(--runtime "$(json_get runtime)" --edition "$(json_get edition)"
              --env "$(json_get env)" --airgap)
  local groups; groups="$(json_get groups)"
  [[ -n "$groups" ]] && args+=(--groups "$groups")
  [[ "$(json_get runtime)" == swarm ]] && args+=(--stack "$(json_get stack industream-prod)")
  ( cd "$TARGET/unified" && ./scripts/deploy.sh "${args[@]}" )
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/airgap/run.sh`
Expected: every test file PASSes.

- [ ] **Step 5: Write the runbook**

Create `docs/runbook/airgap.md` covering, with the exact commands: building a bundle from a connected machine (including the warmed instance needed for the CDN harvest), transporting it (FAT32 works at the default part size), installing on a fresh site, updating an existing one, rolling back with the previous bundle, and the two things that must never be done — no `--down`, and no `git reset --hard` on the site checkout. State plainly that the site checkout is detached from `origin` and that `AIRGAP_VERSION` is the only record of what it holds.

- [ ] **Step 6: Commit**

```bash
git add unified/scripts/airgap-install.sh tests/airgap/test_install_deploy.sh docs/runbook/airgap.md
git commit -m "feat(airgap): deploy from the bundle and document the operator runbook"
```

---

## Task 11: Isolated-VM bench

**Files:**
- Create: `tests/airgap/bench/check-signals.sh`, `tests/airgap/bench/README.md`

**Interfaces:**
- Consumes: a bundle built by Task 4-7 and installed by Task 8-10.
- Produces: `check-signals.sh <domain> [stack]` exiting 0 only when every observable signal holds.

- [ ] **Step 0: Prepare the bench — the existing VMs do not serve as-is**

Surveyed on the workstation, 2026-09-03:

- The isolated network **already exists**: libvirt `ho8-airgap`, `10.20.154.0/24`,
  bridge `virbr-ho8`. Its XML has **no `<forward>` element and no `<dhcp>` block**,
  so it is genuinely isolated — no NAT, no route out, no leases. Reuse it; do not
  define a new one. The host reaches guests on it through `virbr-ho8`
  (`10.20.154.1`), so SSH from the workstation works while the internet does not —
  which is exactly the property the bench needs.
- **`industream-cli-test` cannot be the bench as it stands.** It sits on the `default`
  NAT network (so it has internet, and a VM that still holds a default route passes
  tests it should fail), it has only **3.3 GB free on `/`** — with `/var/lib/docker`
  and `/var/lib/containerd` both on that same filesystem — and it already runs five
  stacks including `industream-prod` at 54 services. A full bundle needs roughly
  50 GB.
- **`ho8-rehearsal`** is already attached to `ho8-airgap`, but it carries the HO8
  compose/Portainer rehearsal state and is worth preserving as-is.

So: grow `industream-cli-test`'s disk and move its interface to `ho8-airgap` with a
static address in `10.20.154.0/24` (there is no DHCP), or build a fresh VM on that
network. Either way the guest gets a static IP; `.20` is HO8's, so use `.30`.

`industream-cli-test` is however **the right `--harvest-from` source**: it runs
`industream-prod` with the populated `prod-cdn-server-storage` and
`prod-cdn-cache-storage` volumes that Task 6 needs, and it has internet for the
Grafana plugin harvest.

- [ ] **Step 1: Write the signal checks**

Create `tests/airgap/bench/check-signals.sh`:

```bash
#!/usr/bin/env bash
# Observable signals only. "The service is up" is not a signal; a queried value
# is. Run on the bench VM after install.sh.
set -uo pipefail
domain="${1:?usage: check-signals.sh <domain>}"
stack="${2:-industream-prod}"
rc=0
chk() { if eval "$2" >/dev/null 2>&1; then echo "  ✓ $1"; else echo "  ✗ $1"; rc=1; fi }

chk "no service below its desired replicas" \
  '! docker stack services "$stack" --format "{{.Replicas}}" | awk -F/ "\$1!=\$2{exit 1}"'
chk "Grafana lists the DataBridge datasource (proves the plugin seeding)" \
  'curl -sk "https://dashboard.$domain/grafana/api/datasources" | grep -q databridge'
chk "the CDN serves a box definition (proves Verdaccio is populated, not merely running)" \
  'docker exec "$(docker ps -qf name=${stack}_cdn-server | head -1)" \
     wget -qO- http://localhost:4873/-/verdaccio/data/packages | grep -q databridge'
chk "the Hub returns launchpad tiles" \
  'curl -sk "https://$domain/api/uifusion/apps" | grep -q "\["'
chk "DataCatalog rejects an unauthenticated request" \
  '[ "$(curl -sk -o /dev/null -w %{http_code} "https://datacatalog-api.$domain/api/assets")" = 401 ]'
exit "$rc"
```

- [ ] **Step 2: Run the cold-install scenario**

On a blank VM attached to the isolated network: copy the bundle, `./install.sh --target ~/industream-platform --yes`, then `check-signals.sh <domain>`.
Expected: every signal ✓. Any ✗ is a bundle defect — fix it in `airgap.sh` or `airgap-install.sh`, rebuild, repeat. Do not fix it by hand on the VM: a hand-fixed VM proves nothing about the bundle.

- [ ] **Step 3: Run the update scenario**

Install bundle N-1 on the VM, write a measurement through DataBridge, then apply bundle N.
Expected: services converge; `.env.<env>`, `secrets/` and `unified/custom/` are byte-identical before and after (`diff -r`); the Grafana plugin is at the new version; the measurement written before is readable after.

- [ ] **Step 4: Record the results in the runbook**

Append the measured numbers to `docs/runbook/airgap.md`: bundle size, uncompressed size, install duration, and the disk actually consumed on `/var/lib/containerd`. These are what size a customer's VM.

- [ ] **Step 5: Commit**

```bash
git add tests/airgap/bench docs/runbook/airgap.md
git commit -m "test(airgap): isolated-VM bench with observable signal checks"
```

---

## Task 12: Open the PR

- [ ] **Step 1: Run the whole suite**

Run: `bash tests/airgap/run.sh`
Expected: exit 0.

- [ ] **Step 2: Lint**

Run: `shellcheck unified/scripts/airgap.sh unified/scripts/airgap-install.sh unified/scripts/deploy.sh`
Expected: no error-level finding. Warnings that the repo already suppresses elsewhere may be suppressed the same way, with the same `# shellcheck disable=` style.

- [ ] **Step 3: Push and open the PR — do not merge**

```bash
git push -u origin feature/airgap-bundle
gh pr create --base main --title "[AIRGAP] Offline bundle prepare/install for air-gapped sites" \
  --body "Implements docs/specs/2026-09-03-airgap-bundle-design.md. …"
```

The PR is for the repo owner to review and merge. **Never `gh pr merge`, never push to `main`.**
