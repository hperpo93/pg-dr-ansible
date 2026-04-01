# PostgreSQL HA Cluster — Ansible Automation

Ansible automation for bootstrapping, disaster-recovering, patching, and maintaining
a production Patroni cluster — covering all DBA duties per the operational spec.

```
Stack    : PostgreSQL 18 + Patroni + etcd
OS       : Ubuntu 24.04
Nodes    : dr-node-1, dr-node-2, dr-node-3
Standalone: dr-standalone (DR restore target, no Patroni)
Backup   : backup-server (pgBackRest, stanza: postgresql-cluster)
```

---

## Quick start

```bash
make setup        # copy all.yml.example → all.yml, then fill in CHANGE_ME values
make ping         # verify SSH connectivity to all nodes
make cluster      # bootstrap full Patroni cluster
make backup-full  # take first full backup
make status       # show cluster topology
```

For DR testing:

```bash
# From-scratch restore (wipes nodes first)
make dr-full-reset

# Refresh a running DR cluster from latest backup (stops Patroni, restores, rejoins)
make dr-full FORCE=true

# Standalone PITR — restore to a specific point in time
make dr-standalone RESTORE_TYPE=time RESTORE_TARGET='2026-03-31 11:55:00+00'
make dr-standalone RESTORE_TYPE=time RESTORE_TARGET='2026-03-31 12:03:10+00'

# Full cluster PITR
make dr-full FORCE=true RESTORE_TYPE=time RESTORE_TARGET='2026-03-31 12:03:10+00'

# Specific backup label
make dr-full-reset BACKUP_SET=20260331-114616F_20260331-120257I
```

Run `make` or `make help` to see all available targets.

---

## DBA duties coverage

| Requirement | Playbook / role | Status |
|---|---|---|
| Full backup weekly, 30-day retention | `group_vars/all.yml`, `pgbackrest.conf.j2` | Covered |
| Incremental backup daily, 30-day retention | `group_vars/all.yml`, `pgbackrest.conf.j2` | Covered |
| WAL archive continuous, 30-day retention | `patroni.config.yml.j2` (`archive_command`) | Covered |
| RPO 15 min (`archive_timeout: 60`) | `patroni.config.yml.j2` | Covered |
| RTO 1–4 hours | DR playbooks + runbook | Covered |
| Backup on primary only (Patroni guard) | `preflight` role | Covered |
| Recovery testing (full, incremental, PITR) | `dr_standalone`, `dr_primary`, `dr_full_cluster` | Covered |
| Patroni cluster start without restore | `patroni_start` | Covered |
| Patching procedure + notifications | `patch_notify.yml`, `patching.yml` | Covered |
| Index bloat monitoring + reindexing | `reindex.yml`, `reindex` role | Covered |

---

## Project structure

```
pg-dr-ansible/
├── Makefile                              # One-liner targets for all operations
├── ansible.cfg
├── inventory/
│   ├── hosts.ini                         # Node IPs, roles, etcd metadata
│   └── group_vars/
│       └── all.yml                       # All variables — set passwords here (gitignored)
│       └── all.yml.example               # Template — copy to all.yml and fill in values
├── roles/
│   ├── preflight/                        # OS check, disk space, backup SSH, Patroni guard
│   ├── certs/                            # Generate CA + per-node TLS certs, distribute
│   ├── install/                          # PostgreSQL, Patroni, pgBackRest
│   ├── etcd/                             # etcd binary, etcd.env, systemd, cluster health
│   ├── patroni/                          # patroni config.yml, start primary/replicas
│   ├── pgbackrest_restore/               # Wipe PGDATA, run pgBackRest restore
│   ├── patching/                         # Rolling patch sequence + email/Slack notifications
│   ├── reindex/                          # Bloat detection, REINDEX CONCURRENTLY, metric log
│   └── validate/                         # API health, replication, WAL archive
└── playbooks/
    ├── patroni_start.yml                 # Bootstrap Patroni cluster (no pgBackRest restore)
    ├── dr_standalone.yml                 # DR mode 1: plain PostgreSQL, no Patroni
    ├── dr_primary.yml                    # DR mode 2: primary only, replicas join later
    ├── dr_join_replica.yml               # DR mode 2b: join replica(s) to running primary
    ├── dr_full_cluster.yml               # DR mode 3: full 3-node cluster in one run
    ├── patch_notify.yml                  # Patching notifications (schedule → reminders)
    ├── patching.yml                      # Rolling cluster patch (replicas first, then primary)
    └── reindex.yml                       # Index bloat detection + REINDEX CONCURRENTLY
```

---

## Step 1 — Set up the Ansible control node

### Install Ansible

```bash
sudo apt update && sudo apt install -y python3 python3-pip
pip3 install --user ansible ansible-core
ansible --version
```

### Set up SSH key access to all nodes

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""

for host in <node-1-ip> <node-2-ip> <node-3-ip> <standalone-ip>; do
  ssh-copy-id <ssh-user>@${host}
done
```

| make | ansible equivalent |
|------|--------------------|
| `make ping` | `ansible all -m ping` |

---

## Step 2 — Configure variables

### inventory/hosts.ini

Single source of truth for all node names and IPs. Patroni config, etcd cluster
string, pg_hba replication entries, and TLS cert SANs are all derived at runtime.

```ini
[standalone]
dr-standalone ansible_host=<standalone-ip>

[pg_nodes]
dr-node-1 ansible_host=<node-1-ip> etcd_node_ip=<node-1-ip> etcd_cert_name=etcd-node1 node_index=1
dr-node-2 ansible_host=<node-2-ip> etcd_node_ip=<node-2-ip> etcd_cert_name=etcd-node2 node_index=2
dr-node-3 ansible_host=<node-3-ip> etcd_node_ip=<node-3-ip> etcd_cert_name=etcd-node3 node_index=3

[pg_primary]
dr-node-1 ansible_host=<node-1-ip>

[pg_replicas]
dr-node-2 ansible_host=<node-2-ip>
dr-node-3 ansible_host=<node-3-ip>

[backup_server]
backup-server ansible_host=<backup-server-ip>

[all:vars]
ansible_user=ubuntu
```

### group_vars/all.yml — key variables to set

`all.yml` is gitignored. Create it from the example then fill in the `CHANGE_ME` values:

| make | ansible equivalent |
|------|--------------------|
| `make setup` | `cp inventory/group_vars/all.yml.example inventory/group_vars/all.yml` |

```yaml
pg_version:              "18"
pg_superuser_password:   "CHANGE_ME"
pg_replication_password: "CHANGE_ME"
pgbackrest_repo_host:    "backup-server"
patroni_scope:           "postgresql-cluster"

# Restore options (used by all DR playbooks)
pgbackrest_restore_type: default        # default | time | name | lsn
pgbackrest_restore_set:  ""             # optional: specific backup label e.g. 20260331-114616F_20260331-120257I
pgbackrest_restore_target: ""           # used with time/name/lsn types
pgbackrest_restore_target_action: promote
```

For patching notifications also set:

```yaml
patch_notify_contacts:
  - name: Your Name
    email: "you@example.com"
patch_notify_from:   "dba-noreply@example.com"
patch_smtp_host:     "localhost"
patch_slack_webhook: ""          # optional — leave empty to skip Slack
```

---

## Step 3 — Bootstrap the cluster (no pgBackRest restore)

Installs packages, distributes certs, starts etcd, bootstraps the primary, then
joins each replica (serial: 1) so Patroni clones from the primary.

| make | ansible equivalent |
|------|--------------------|
| `make cluster` | `ansible-playbook -i inventory/hosts.ini playbooks/patroni_start.yml` |
| `make cluster-primary` | `ansible-playbook -i inventory/hosts.ini playbooks/patroni_start.yml --limit pg_primary` |
| `make cluster AP_EXTRA="--limit dr-node-2"` | `ansible-playbook -i inventory/hosts.ini playbooks/patroni_start.yml --limit dr-node-2` |
| `make cluster-reset` | `make reset-nodes && make cluster` |

| Play | Hosts | Action |
|------|-------|--------|
| 1/5 | `pg_nodes` | Install packages + distribute certs |
| 2/5 | `pg_nodes` | Start etcd cluster |
| 3/5 | `pg_primary` | Write Patroni config, start service, wait for Leader |
| 4/5 | `pg_replicas` | Wipe PGDATA, start Patroni, wait for streaming (serial: 1) |
| 5/5 | `pg_primary` | Validate cluster topology |

---

## Step 4 — pgBackRest backups

| make | ansible / ssh equivalent |
|------|--------------------------|
| `make backup-full` | `ssh dr-node-1 "sudo -u postgres pgbackrest --stanza=postgresql-cluster backup --type=full"` |
| `make backup-incr` | `ssh dr-node-1 "sudo -u postgres pgbackrest --stanza=postgresql-cluster backup --type=incr"` |
| `make backup-list` | `ssh dr-node-1 "sudo -u postgres pgbackrest --stanza=postgresql-cluster info"` |
| `make stanza-upgrade` | `ssh dr-node-1 "sudo -u postgres pgbackrest --stanza=postgresql-cluster stanza-upgrade"` |

> Run `stanza-upgrade` after a PostgreSQL major version change (e.g. PG14 → PG18)
> before taking the first backup with the new version.

---

## Step 5 — DR restore

### Choose your restore scenario

| Scenario | Command | When to use |
|----------|---------|-------------|
| **From scratch** — wipe nodes, then restore | `make dr-full-reset` | Real DR simulation. Nodes are wiped clean before restoring from backup. |
| **Refresh a running cluster** — stop, restore, rejoin | `make dr-full FORCE=true` | DR copy is stale and needs refreshing without manually stopping services first. |
| **Manual reset + restore** | `make reset-nodes && make dr-full` | Same as `dr-full-reset` but explicit. |

The `FORCE=true` flag bypasses the preflight Patroni guard and stops all Patroni
instances automatically before wiping and restoring.

### Reset utilities

| make | what it does |
|------|--------------|
| `make reset-nodes` | Stop patroni + etcd, wipe PGDATA + etcd data on all pg nodes |
| `make reset-standalone` | Stop PostgreSQL, wipe PGDATA on dr-standalone |

### Restore variables

| make variable | ansible equivalent | default |
|---------------|--------------------|---------|
| `BACKUP_SET=<label>` | `-e "pgbackrest_restore_set=<label>"` | `""` (latest) |
| `RESTORE_TYPE=time` | `-e "pgbackrest_restore_type=time"` | `default` |
| `RESTORE_TARGET='...'` | `-e "pgbackrest_restore_target='...'"` | `""` |
| `FORCE=true` | `-e "force=true"` | `false` |

---

### Mode 1 — Standalone (plain PostgreSQL, no Patroni)

Restores to the `[standalone]` host. PostgreSQL starts directly with no Patroni
or etcd. SSL is disabled on the restored node (certs are not distributed).

| make | ansible equivalent |
|------|--------------------|
| `make dr-standalone` | `ansible-playbook -i inventory/hosts.ini playbooks/dr_standalone.yml` |
| `make dr-standalone-reset` | reset standalone node, then restore |
| `make dr-standalone FORCE=true` | stop postgres on running standalone, then restore |
| `make dr-standalone BACKUP_SET=<label>` | `ansible-playbook ... -e "pgbackrest_restore_set=<label>"` |
| `make dr-standalone RESTORE_TYPE=time RESTORE_TARGET='2026-03-31 12:00:00+00'` | `ansible-playbook ... -e "pgbackrest_restore_type=time" -e "pgbackrest_restore_target='...'"`  |

#### Standalone PITR examples

```bash
# Restore to a point BEFORE a table was created (table will be absent)
make dr-standalone RESTORE_TYPE=time RESTORE_TARGET='2026-03-31 11:55:00+00'

# Restore to a point AFTER 100 rows were inserted (table + rows will be present)
make dr-standalone RESTORE_TYPE=time RESTORE_TARGET='2026-03-31 12:03:10+00'

# Verify result after restore
ssh dr-standalone "sudo -u postgres psql -tAc 'SELECT count(*) FROM dr_test;'"
```

pgBackRest selects the latest backup whose stop time ≤ the target:

| Target time | Backup used | Backup timeline | Expected result |
|-------------|-------------|-----------------|-----------------|
| `11:55:00` | full (11:46:23) | TL2 | table absent |
| `12:03:10` | incr (12:03:05) | TL6 | 100 rows |

> **Timeline note:** `recovery_target_timeline` is set automatically from the
> restored `backup_label` (e.g. `2` for the full backup, `6` for the incr).
> This avoids both `'current'` (may stop too early if the backup timeline has
> limited WAL) and `'latest'` (may point to a branched timeline that is not
> a descendant of the backup's checkpoint after repeated PITR runs).

Connect directly (no VIP or load balancer):

```bash
psql -h <standalone-ip> -p 5432 -U postgres
```

### Mode 2 — Primary only, replicas join later

Use for staged DR where you want to validate the primary before adding replicas.

| make | ansible equivalent |
|------|--------------------|
| `make dr-primary` | `ansible-playbook -i inventory/hosts.ini playbooks/dr_primary.yml` |
| `make dr-primary-reset` | wipe all pg nodes, then restore primary only |
| `make dr-primary FORCE=true` | stop Patroni on all nodes, then restore primary |
| `make status` | `sudo -u postgres patronictl -c /etc/patroni/config.yml list` |
| `make dr-join-replica` | `ansible-playbook -i inventory/hosts.ini playbooks/dr_join_replica.yml` |
| `make dr-join-replica AP_EXTRA="--limit dr-node-2"` | `ansible-playbook -i inventory/hosts.ini playbooks/dr_join_replica.yml --limit dr-node-2` |

### Mode 3 — Full cluster in one run

| make | ansible equivalent |
|------|--------------------|
| `make dr-full` | `ansible-playbook -i inventory/hosts.ini playbooks/dr_full_cluster.yml` |
| `make dr-full-reset` | wipe all pg nodes, then restore full cluster |
| `make dr-full FORCE=true` | stop Patroni on all nodes, then restore full cluster |
| `make dr-full BACKUP_SET=<label>` | `ansible-playbook ... -e "pgbackrest_restore_set=<label>"` |
| `make dr-full RESTORE_TYPE=time RESTORE_TARGET='...'` | `ansible-playbook ... -e "pgbackrest_restore_type=time" -e "pgbackrest_restore_target='...'"` |

#### Full cluster PITR examples

```bash
# PITR to before an accidental insert (table absent on restored cluster)
make dr-full FORCE=true RESTORE_TYPE=time RESTORE_TARGET='2026-03-31 11:55:00+00'

# PITR to after an insert — 100 rows present, cluster fully running with replicas
make dr-full FORCE=true RESTORE_TYPE=time RESTORE_TARGET='2026-03-31 12:03:10+00'

# Verify: patronictl shows Leader + 2 streaming replicas, 0 lag
ssh dr-node-1 "sudo -u postgres patronictl -c /etc/patroni/config.yml list"
ssh dr-node-1 "sudo -u postgres psql -tAc 'SELECT count(*) FROM dr_test;'"
```

> **How full-cluster PITR works:** pgBackRest restores the backup on the primary.
> PostgreSQL is started directly with `pg_ctl` (not Patroni) so that
> `recovery_target_time` is honoured — Patroni would promote at the consistency
> point and ignore the target. Once `pg_is_in_recovery()` returns `f`, Patroni
> is started and the replicas clone from the recovered primary as normal.

| Play | Action |
|------|--------|
| 1/8 | Preflight checks on all pg nodes (skips Patroni guard if `FORCE=true`) |
| 1.5/8 | Stop Patroni + PostgreSQL on all nodes (`FORCE=true` only) |
| 2/8 | Install packages + distribute certs |
| 3/8 | Start etcd cluster |
| 4/8 | Wipe stale Patroni namespace from etcd |
| 5/8 | pgBackRest restore on primary, start Patroni, wait for Leader |
| 6/8 | Join replicas (Patroni clones from primary, serial: 1) |
| 7/8 | HAProxy + Keepalived (skipped — no lb_nodes in inventory) |
| 8/8 | Validate cluster topology |

---

## Step 5b — PITR walkthrough (end-to-end test)

This section walks through a complete PITR test: create a table, insert data,
simulate an accident, then recover to two different points in time.

Run all commands from the Ansible control node.

---

### 1 — Establish a baseline backup

```bash
# Take a fresh full backup before the test
make backup-full

# Confirm it appears in the backup list
make backup-list
```

---

### 2 — Set up test data on the primary

```bash
# Create the demo table (empty at this point)
ssh dr-node-1 "sudo -u postgres psql -c \"
  CREATE TABLE IF NOT EXISTS pitr_demo (
    id      serial PRIMARY KEY,
    label   text,
    created timestamptz DEFAULT clock_timestamp()
  );
\""

# Capture T_BEFORE — recovery to this point will show an EMPTY table
T_BEFORE=$(date -u '+%Y-%m-%d %H:%M:%S+00')
echo "T_BEFORE (empty table) : $T_BEFORE"

# Insert 100 rows
ssh dr-node-1 "sudo -u postgres psql -c \"
  INSERT INTO pitr_demo (label)
    SELECT 'row_' || i FROM generate_series(1,100) i;
\""

# Force a WAL segment switch so the insert is immediately archived
ssh dr-node-1 "sudo -u postgres psql -tAc 'SELECT pg_switch_wal();'"

# Verify WAL is archived before recording T_AFTER
ssh dr-node-1 "sudo -u postgres pgbackrest --stanza=postgresql-cluster check"

# Capture T_AFTER — recovery to this point will show 100 rows
T_AFTER=$(date -u '+%Y-%m-%d %H:%M:%S+00')
echo "T_AFTER  (100 rows)    : $T_AFTER"
```

> `pg_switch_wal()` forces an immediate WAL segment switch.
> `pgbackrest check` blocks until that segment is confirmed archived —
> this guarantees the PITR target has all the data it needs.

---

### 3 — Take an incremental backup (optional but realistic)

```bash
# In production a cron job does this; run it manually for the test
make backup-incr
make backup-list
```

---

### 4 — Simulate the accident

```bash
# Someone drops the table
ssh dr-node-1 "sudo -u postgres psql -c 'DROP TABLE pitr_demo;'"

# Confirm it is gone
ssh dr-node-1 "sudo -u postgres psql -c '\dt pitr_demo'"

# Force WAL switch so the DROP is archived (needed for replay to work correctly)
ssh dr-node-1 "sudo -u postgres psql -tAc 'SELECT pg_switch_wal();'"
ssh dr-node-1 "sudo -u postgres pgbackrest --stanza=postgresql-cluster check"

echo "Accident archived. Restore targets:"
echo "  T_BEFORE = $T_BEFORE  →  table exists, 0 rows"
echo "  T_AFTER  = $T_AFTER   →  table exists, 100 rows"
```

---

### 5 — Restore to T_BEFORE (table present, no rows)

```bash
# Standalone PITR — no Patroni, fastest restore
make dr-standalone RESTORE_TYPE=time RESTORE_TARGET="$T_BEFORE"

# Verify
ssh dr-standalone "sudo -u postgres psql -tAc 'SELECT count(*) FROM pitr_demo;'"
# Expected output: 0
```

---

### 6 — Restore to T_AFTER (table present, 100 rows)

```bash
# Re-run standalone PITR to a later point
make dr-standalone RESTORE_TYPE=time RESTORE_TARGET="$T_AFTER"

# Verify
ssh dr-standalone "sudo -u postgres psql -tAc 'SELECT count(*) FROM pitr_demo;'"
# Expected output: 100

# Spot-check a sample of rows
ssh dr-standalone "sudo -u postgres psql -c \
  'SELECT id, label, created FROM pitr_demo ORDER BY id LIMIT 5;'"
```

---

### 7 — (Optional) Full cluster PITR to T_AFTER

Recovers to the same point on a full 3-node Patroni cluster instead of
the standalone node.

```bash
make dr-full FORCE=true RESTORE_TYPE=time RESTORE_TARGET="$T_AFTER"

# Verify cluster topology
ssh dr-node-1 "sudo -u postgres patronictl -c /etc/patroni/config.yml list"

# Verify data
ssh dr-node-1 "sudo -u postgres psql -tAc 'SELECT count(*) FROM pitr_demo;'"
# Expected output: 100
```

---

### Reference: what pgBackRest selects for each target

pgBackRest picks the **latest backup whose stop time ≤ the PITR target**.

| PITR target | Backup selected | Why |
|-------------|-----------------|-----|
| `T_BEFORE` | Full backup | The incr's stop time is > T_BEFORE, so it cannot be used |
| `T_AFTER`  | Incremental backup | Incr stop time ≤ T_AFTER; selected as latest valid backup |

After restore, `recovery_target_timeline` is set automatically by reading the
backup's timeline from `backup_label`. This avoids two common failures:

| Setting | Failure mode |
|---------|-------------|
| `'current'` | Stops too early when the backup's own timeline has only a few WAL segments |
| `'latest'`  | Fails with "not a child" after PITR runs branch the timeline tree |
| *(auto from `backup_label`)* | Always uses the backup's native timeline — no branching issues |

---

## Step 6 — Patching procedure

### Stage 1 — Open scheduling conversation

| make | ansible equivalent |
|------|--------------------|
| `make notify-schedule` | `ansible-playbook playbooks/patch_notify.yml -e "notify_stage=schedule"` |

### Stage 2 — Set the maintenance window in group_vars/all.yml

```yaml
patch_window_start: "2026-04-15 22:00"
patch_window_end:   "2026-04-16 02:00"
```

### Stage 3 — Send reminders

```bash
# make (pass window as AP_EXTRA since it varies per run)
make AP_EXTRA="-e notify_stage=reminder_48h -e patch_window_start='2026-04-15 22:00' -e patch_window_end='2026-04-16 02:00'" notify-schedule

# ansible equivalent
ansible-playbook playbooks/patch_notify.yml \
  -e "notify_stage=reminder_48h" \
  -e "patch_window_start='2026-04-15 22:00'" \
  -e "patch_window_end='2026-04-16 02:00'"
```

Repeat with `reminder_24h` and `reminder_day_of`.

### Stage 4 — Execute rolling patch

| make | ansible equivalent |
|------|--------------------|
| `make patch-dry AP_EXTRA="-e patch_window_start='2026-04-15 22:00' -e patch_window_end='2026-04-16 02:00'"` | `ansible-playbook playbooks/patching.yml -e "patch_dry_run=true" -e "patch_window_start=..."` |
| `make patch AP_EXTRA="-e patch_window_start='2026-04-15 22:00' -e patch_window_end='2026-04-16 02:00'"` | `ansible-playbook playbooks/patching.yml -e "patch_window_start=..." -e "patch_window_end=..."` |

The playbook patches replicas one at a time, then performs a `patronictl switchover`
to move leadership off the primary and patches the old primary last.

---

## Step 7 — Reindexing

| make | ansible equivalent |
|------|--------------------|
| `make reindex-dry` | `ansible-playbook playbooks/reindex.yml -e "reindex_dry_run=true"` |
| `make reindex` | `ansible-playbook playbooks/reindex.yml` |
| `make reindex AP_EXTRA="-e reindex_bloat_threshold_pct=15"` | `ansible-playbook playbooks/reindex.yml -e "reindex_bloat_threshold_pct=15"` |
| `make reindex AP_EXTRA='-e {"reindex_target_databases":["mydb"]}'` | `ansible-playbook playbooks/reindex.yml -e '{"reindex_target_databases": ["mydb"]}'` |

Every run appends a JSON line per index to `/var/log/postgresql/reindex_metrics.log`:

```bash
cat /var/log/postgresql/reindex_metrics.log | python3 -c "
import sys, json
for line in sys.stdin:
    r = json.loads(line)
    print(f\"{r['timestamp']}  {r['database']}.{r['schema']}.{r['index']}  \
{r['index_size_mb']}MB  dead={r['dead_tuple_ratio']}%  {r['duration_seconds']}s  [{r['status']}]\")
"
```

---

## Useful commands

```bash
# Cluster topology
sudo -u postgres patronictl -c /etc/patroni/config.yml list

# Patroni switchover / failover
sudo -u postgres patronictl -c /etc/patroni/config.yml switchover postgresql-cluster
sudo -u postgres patronictl -c /etc/patroni/config.yml failover postgresql-cluster

# etcd cluster health (run on any pg node)
etcdctl endpoint health
etcdctl member list

# pgBackRest — list backups
sudo -u postgres pgbackrest --stanza=postgresql-cluster info

# pgBackRest — verify WAL archiving
sudo -u postgres pgbackrest --stanza=postgresql-cluster check

# pgBackRest — take an incremental backup
sudo -u postgres pgbackrest --stanza=postgresql-cluster backup --type=incr
```

---

## Troubleshooting

| Symptom | Where to look |
|---------|--------------|
| Patroni won't start | `journalctl -u patroni -f` |
| etcd unhealthy | `etcdctl endpoint health` — all 3 members must show `healthy` |
| Replica stuck cloning | `patronictl list` — check lag; `tail -f /var/log/postgresql/*.log` |
| pgBackRest restore fails | `tail -100 /var/log/pgbackrest/postgresql-cluster-restore.log` |
| Standalone still in recovery | Connect and run: `SELECT pg_wal_replay_resume();` |
| etcd namespace mismatch after DR | The wipe play (4/8 in dr_full_cluster) handles this automatically |
| postgres can't read etcd certs | Check directory traversal ACLs: `getfacl /etc/etcd /etc/etcd/ssl` — postgres needs `--x` on both dirs plus `r` on cert files |
| Patroni heartbeat auth fails | Ensure `host all all 127.0.0.1/32 trust` is in `patroni_pg_hba_static` |
| Archive mismatch after PG upgrade | Run `make stanza-upgrade` (or `pgbackrest stanza-upgrade`) on the primary |
| Patch fails mid-run | `journalctl -u patroni -f` on affected node; cluster stays online |
| Reindex lock timeout | Retry off-peak or increase `reindex_lock_timeout` in group_vars/all.yml |
| Notification emails not sent | Check SMTP relay: `telnet localhost 25`; verify `patch_smtp_host` |
| `dr-full` preflight blocks: "Patroni is active" | Nodes still running from a previous run. Use `make dr-full-reset` (wipe first) or `make dr-full FORCE=true` (stop automatically) |
| Replica `start failed` after repeated DR runs | Timeline mismatch from accumulated restore history. Run `make reset-nodes && make dr-full` to restore cleanly |
| `pg_ctl` start fails: "Address already in use" | A previous postgres process is still running. Use `make dr-standalone FORCE=true` or `make dr-standalone-reset` |
| Standalone PITR: `recovery ended before configured recovery target was reached` | The backup's native timeline has too few WAL segments to reach the target (common for the full backup after many DR runs). The playbook auto-detects the correct timeline from `backup_label` — re-running should resolve it. If not, check that the target timestamp is within the WAL archive window: `sudo -u postgres pgbackrest --stanza=postgresql-cluster info` |
| Standalone PITR: `requested timeline X is not a child of this server's history` | `'latest'` was used and the latest timeline branched before the backup's checkpoint — this happens after multiple PITR runs create new timeline branches. The playbook reads the timeline directly from `backup_label` to avoid this; if it still fails, check `cat $PGDATA/backup_label` and compare with `pgbackrest info` |
| Full cluster PITR: Patroni promotes too early, ignores `recovery_target_time` | Patroni bootstraps at the consistency point, not the PITR target. The playbook starts PostgreSQL with `pg_ctl` first and waits for `pg_is_in_recovery()` to return `f` before starting Patroni — if the wait times out (60 × 5 s), check `/var/log/postgresql/postgresql-primary-pitr.log` on the primary |
| PITR target produces wrong row count | The target time may be slightly before or after the actual transaction commit. Use `pgbackrest info` to confirm WAL coverage and adjust the target by a few seconds |

---

## Backup schedule reference

| Type | Frequency | Retention | Cron |
|---|---|---|---|
| Full | Weekly (Sunday 01:00) | 30 days | `0 1 * * 0` |
| Incremental | Daily Mon–Sat (01:00) | 30 days | `0 1 * * 1-6` |
| WAL archive | Continuous | 30 days | via `archive_command` |

RPO: 15 minutes (`archive_timeout = 60`)
RTO: 1–4 hours (see DR modes above)

| DR mode | Estimated RTO |
|---|---|
| Standalone (latest) | 30 min – 2 hr |
| Primary only | 1 – 3 hr |
| Full cluster | 2 – 4 hr |
| PITR overhead | + 15 – 30 min WAL replay |
