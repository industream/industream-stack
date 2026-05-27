# Industream offline license (Ed25519) — prototype

Offline, signed, per-site license for air-gapped industrial deployments.
No license server, no internet, no per-machine binding. Pure `openssl` + `jq`.

This is the **entitlement gate** of a **two-gate** model — see
[`../../../industream-cli/docs/V2-AUTH-MIGRATION.md`](../../../industream-cli/docs/V2-AUTH-MIGRATION.md)
§ Licensing.

This pairs with the in-flight **split-registry** migration (`REGISTRY-ARCHITECTURE.md`):

| Gate | Registry | Auth | Revocable? | Purpose |
|------|----------|------|------------|---------|
| — (none) | `COMMUNITY_REGISTRY=ghcr.io/industream` | **anonymous** | n/a | CE / BSL images — free, no license, no creds. |
| **Distribution** | `ENTERPRISE_REGISTRY` (OVH `39t88114…`) | **license-bound robot** | ✅ rotate the robot | Can't *pull* proprietary addons without it. Leak → revoke that one client. |
| **Entitlement** | the signed `.lic` file | Ed25519, offline | ⚠️ expiry/maintenance | What runs, until when, which modules/limits. |

The enterprise-registry robot creds are **embedded in the signed license**
(`harbor.username`/`secret`), so one artifact carries both gates. `create-customer.ts`
already provisions the robot + (Keygen) license; v2 swaps the Keygen part for this offline
file — community images keep pulling anonymously from GHCR.

> The `842775dh…` OVH registry is **internal CI staging** (dispatcher source), never
> customer-facing — not a gate.
>
> **Transitional (current state):** community GHCR images are still **private pending a
> security scan** and will be opened later. Until then, a CE deploy also needs a GHCR pull
> token — so the "community = anonymous, no creds" row above is the **target**, not today.

## Files
- `gen-keys.sh` — one-time, Industream-side. Ed25519 keypair. **Private key never ships.**
- `issue-license.sh` — Industream-side. Builds + signs a `.lic` (needs the private key).
- `license.sh` — deploy-side library/CLI. Verifies offline (needs only the **public** key).
- `ee-gate.sh` — the EE deploy gate (below).

## EE deploy gate (`ee-gate.sh`)
The keystone: turns a verified license into a deployment. It is the bash port of
`stack-filter.ts`, fed by the **offline signed license** instead of Keygen.
```bash
./ee-gate.sh --license acme.lic [--pubkey keys/license-public.pem]
             [--modules <modules.json>] [--env dev] [--login] [--deploy]
```
It (1) verifies signature + expiry, (2) derives the entitlement set
(`addons[]` + `PRODUCT_<moduleKey>`), (3) reads `modules.json` and selects the
allowed services + their stack files (BSL always; proprietary only if entitled —
exactly `stack-filter.ts`), (4) applies the `-ee` image for modules with an
`enterpriseVariant`, (5) `docker login`s the enterprise registry with the
license-embedded robot creds, (6) prints/runs the `docker stack deploy`.
**Dry-run by default**; `--login` authenticates, `--deploy` runs.

## Issue (Industream side)
```bash
./gen-keys.sh keys                      # once; keep keys/license-private.pem in `pass`
./issue-license.sh --key keys/license-private.pem \
  --customer "ACME GmbH" --site "Plant-Esch-1" --type subscription \
  --module DATACATALOG:maxTags=1000 --module AI_STUDIO:maxModels=5 \
  --addon ADDON_BACKUP --addon ADDON_DB_TIMESCALE \
  --harbor-user 'robot$client-acme' --harbor-secret '<robot-token>' \
  --expiry 2027-05-27 --out acme.lic
# trial:     --type trial --days 90      (expiry = today+90)
# perpetual: --type perpetual --maintenance 2027-05-27   (no run expiry; gates upgrades)
```

## Verify (deploy side, offline)
```bash
# only license-public.pem ships with the platform
./license.sh show   acme.lic keys/license-public.pem
./license.sh verify acme.lic keys/license-public.pem    # exit!=0 if invalid/expired

# as a library, inside the ee-gate:
source ./license.sh
license_verify acme.lic keys/license-public.pem || exit 1
license_check_expiry || true            # sets LICENSE_STATUS=valid|grace|expired|clock-rollback
license_module_enabled DATACATALOG      # → deploy docker-stack.data.yml
license_module_limit  DATACATALOG maxTags
license_has_addon     ADDON_BACKUP      # → add docker-stack.backup.yml
license_harbor_login                    # → "user<TAB>secret" for `docker login`
```

## License format
`<base64(payload_json)>.<base64(ed25519_sig_over_the_payload_b64_bytes)>` (JWT-style:
we sign the encoded segment, so verification re-uses the exact bytes — no JSON
canonicalization trap).

Payload claims: `customer, site, type, modules{NAME:{limits}}, addons[], harbor{username,secret},
issued, expiry, maintenance_expiry`.

## Security properties (all tested)
- Tampering any claim (e.g. adding an unpurchased module) → signature fails.
- Wrong key → fails. Private key never leaves Industream → clients can't forge.
- `expiry`: hard calendar limit with a configurable grace window
  (`LICENSE_GRACE_DAYS`, default 14) — **warns, does not brick** running production.
- Clock-rollback guard via a monotonic high-water mark (`LICENSE_STATE`,
  default `/var/lib/industream/license.state`).

## Known limits (honest)
- Offline = **all enforcement state lives on the customer's disk**. A determined customer
  can VM/volume-snapshot and restore to defeat expiry/rollback, or patch the script. This
  raises the bar; it is not DRM. The **Harbor gate** + contract are the real controls.
- **Quantitative caps** (maxTags/maxModels/maxUsers) are *carried* here but must be
  **enforced at runtime by the apps** (DataBridge/AI-Studio/MCP) — the deploy gate only
  does module on/off + add-ons.
- **Trial countdown** (runtime budget, monotonic) is documented in the migration plan but
  not in this prototype (boolean + calendar expiry only).
