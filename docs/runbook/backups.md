# Backups Runbook

Operational guide for the Industream platform backup subsystem.

---

## Overview

Three scheduled jobs produce the backups, one job verifies them weekly,
and one monitor exposes a dashboard.

| Service             | Script                              | Schedule (UTC) | Output                                    |
|---------------------|-------------------------------------|----------------|-------------------------------------------|
| `backup-postgres`   | `scripts/backups/backup-postgres.sh`| `0 2 * * *`    | `/backups/postgres/<date>/*.sql.gz`       |
| `backup-influxdb`   | `scripts/backups/backup-influxdb.sh`| `30 2 * * *`   | `/backups/influxdb/<date>/influxdb_*.tar.gz` |
| `backup-volumes`    | `scripts/backups/backup-volumes.sh` | `0 4 * * *`    | `/backups/volumes/<date>/*.tar.gz`        |
| `verify-weekly`     | `scripts/backups/verify-weekly.sh`  | `0 3 * * 0`    | `/var/log/industream-backups/verify-weekly-<YYYYMMDD>.log` |
| `backup-monitor`    | (UI, image `backup-monitor:1.0.0`)  | (always on)    | https://backups.\<domain\>                 |

All jobs share the `${ENV}-backup-data` volume; the verify job mounts it
read-only. Scheduling is driven by `swarm-cronjob` labels.

---

## Weekly verification

### What is verified

`verify-weekly.sh` walks the backup root (`/backups`) and looks at every
file modified in the **last 7 days**. Three categories are checked:

1. **PostgreSQL** (`*.sql.gz`)
   - `gzip -t` integrity.
   - Decompresses the first 4 KiB and asserts a Postgres plain-dump
     marker is present (`PostgreSQL database dump`, `SET statement_timeout`,
     or `Dumped from database version`). This catches dumps that were
     truncated mid-stream or replaced by error text.
2. **InfluxDB** (`influxdb_*.tar.gz`)
   - `tar -tzf` integrity.
   - Listing must contain a `manifest`, `.bolt`, `kv`, `sqlite`, or
     `.sql` entry, i.e. the canonical files emitted by `influx backup`.
3. **Volumes** (other `*.tar.gz`)
   - `tar -tzf` integrity.

The script counts `OK` vs `FAIL` per category and exits non-zero when
**any** file fails verification **or** when no backups were found in the
window at all.

### When it runs

`swarm-cronjob` triggers the `verify-weekly` service every Sunday at
**03:00 UTC** (`0 3 * * 0`). The job runs on the swarm manager — the
same node as the producing jobs — so it always sees the populated
backup volume.

### Where to read the report

The job writes a timestamped log inside the
`${ENV}-backup-verify-logs` volume:

```
/var/log/industream-backups/verify-weekly-<YYYYMMDD>.log
```

Fetch it from the manager host with:

```bash
docker run --rm -v <env>-backup-verify-logs:/logs alpine \
    ls -lh /logs
docker run --rm -v <env>-backup-verify-logs:/logs alpine \
    cat /logs/verify-weekly-$(date +%Y%m%d).log
```

Each entry is prefixed with `OK    |` or `FAIL  |`, followed by the
absolute path of the verified file. The summary block at the bottom
gives the per-category counts.

### What to do on FAIL

A Ntfy notification is pushed to the topic configured via `NTFY_TOPIC`
(default `industream-backups`) with priority `high` and tag `warning`.

1. Open the log file (`verify-weekly-<YYYYMMDD>.log`) and identify the
   failing file(s).
2. Inspect the matching producer log (`docker service logs <env>_backup-postgres`
   etc.) for the day the broken backup was created.
3. Re-run the producer manually by scaling its replicas:

   ```bash
   docker service scale <env>_backup-postgres=1   # or backup-influxdb / backup-volumes
   # wait for the run to finish, then:
   docker service scale <env>_backup-postgres=0
   ```

4. Re-run the verifier (see below) to confirm the fix.
5. If the producer keeps emitting broken files, investigate disk space
   (`df -h`), source-DB connectivity, and Docker secrets.

### Special case: "no backups found"

If the window contains zero files, the verifier exits 1 with the message
`No backups found in the last 7 days`. This means the producers have
not run — usually because `swarm-cronjob` is down or because the cron
labels were removed. Check:

```bash
docker service ps <env>_swarm-cronjob
docker service inspect <env>_backup-postgres --format '{{.Spec.Labels}}'
```

---

## Running the verification manually

### Inside the swarm

```bash
docker service scale <env>_verify-weekly=1
# the job runs once, exits, then the swarm-cronjob will continue to
# schedule it weekly. Set replicas back to 0 just to be safe:
docker service scale <env>_verify-weekly=0
```

### Outside the swarm (local smoke test)

```bash
BACKUP_DIR=/path/to/local/backups \
LOG_DIR=/tmp \
MAX_AGE_DAYS=7 \
NTFY_URL= \
NTFY_TOPIC= \
bash scripts/backups/verify-weekly.sh
```

Setting `NTFY_URL=` (empty) prevents the notification call when running
ad hoc.

---

## Known limitations (V1)

- **No restore test.** The verifier confirms structural integrity but
  does not spin up a temporary Postgres / InfluxDB and replay the dump.
  The reason is operational: a full restore loop needs an isolated test
  database with enough disk to hold every dump and a guaranteed clean
  teardown — neither is in scope for the single-node Bernegger deploy.
  V2 will add an opt-in `RESTORE_TEST=true` mode that pipes each dump
  into a throwaway `pg_restore` against a `pg_tmp` instance.
- **Symlink handling.** The walker uses `find -type f`, so symlinks are
  ignored. Backup producers never create symlinks today, so this is a
  non-issue.
- **InfluxDB layout drift.** The InfluxDB marker list (`manifest`,
  `.bolt`, `kv`, `sqlite`, `.sql`) covers OSS 2.x. If we migrate to
  InfluxDB 3 the matcher must be revisited.
- **Concurrency.** The job is single-shot; `swarm-cronjob.skip-running=true`
  guarantees the previous instance has exited before the next slot
  fires.
