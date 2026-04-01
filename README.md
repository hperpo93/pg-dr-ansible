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
├── ansible.cfg
├── inventory/
│   ├── hosts.ini                         # Node IPs, roles, etcd metadata
│   └── group_vars/
│       └── all.yml                       # All variables — set passwords here
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

ansible all -m ping
```

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

```yaml
pg_version:              "18"
pg_superuser_password:   "your-postgres-password"
pg_replication_password: "your-replication-password"
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

Use `patroni_start.yml` to bring up a fresh Patroni cluster. This installs
packages, distributes certs, starts etcd, bootstraps the primary, then joins each
replica (serial: 1) so Patroni clones from the primary.

```bash
# Full cluster (primary + all replicas)
ansible-playbook -i inventory/hosts.ini playbooks/patroni_start.yml

# Primary only first, then add replicas
ansible-playbook -i inventory/hosts.ini playbooks/patroni_start.yml --limit pg_primary
ansible-playbook -i inventory/hosts.ini playbooks/patroni_start.yml --limit dr-node-2
```

| Play | Hosts | Action |
|------|-------|--------|
| 1/5 | `pg_nodes` | Install packages + distribute certs |
| 2/5 | `pg_nodes` | Start etcd cluster |
| 3/5 | `pg_primary` | Write Patroni config, start service, wait for Leader |
| 4/5 | `pg_replicas` | Wipe PGDATA, start Patroni, wait for streaming (serial: 1) |
| 5/5 | `pg_primary` | Validate cluster topology |

### To rerun from scratch

```bash
for node in dr-node-1 dr-node-2 dr-node-3; do
  ssh $node "sudo systemctl stop patroni; sudo systemctl stop etcd; \
             sudo pkill -u postgres -9 2>/dev/null; \
             sudo rm -rf /var/lib/postgresql/data/*; \
             sudo rm -rf /var/lib/etcd/*"
done

ansible-playbook -i inventory/hosts.ini playbooks/patroni_start.yml
```

---

## Step 4 — pgBackRest backups

With the cluster running, take backups from the primary.

```bash
# Full backup
sudo -u postgres pgbackrest --stanza=postgresql-cluster backup --type=full

# Incremental backup
sudo -u postgres pgbackrest --stanza=postgresql-cluster backup --type=incr

# List all backups
sudo -u postgres pgbackrest --stanza=postgresql-cluster info
```

If you upgraded PostgreSQL major version (e.g. PG14 → PG18), upgrade the stanza
metadata before taking the first backup with the new version:

```bash
sudo -u postgres pgbackrest --stanza=postgresql-cluster stanza-upgrade
```

---

## Step 5 — DR restore

All DR playbooks check that Patroni is **not running** before proceeding.
Stop services and wipe data before each run:

```bash
for node in dr-node-1 dr-node-2 dr-node-3; do
  ssh $node "sudo systemctl stop patroni; sudo systemctl stop etcd; \
             sudo pkill -u postgres -9 2>/dev/null; \
             sudo rm -rf /var/lib/postgresql/data/*; \
             sudo rm -rf /var/lib/etcd/*"
done
```

### Choosing a backup

By default all DR playbooks restore the **latest** backup. To target a specific
backup (e.g. an incremental), set `pgbackrest_restore_set` in `group_vars/all.yml`
or pass it as an extra var:

```bash
# Restore from a specific incremental
ansible-playbook -i inventory/hosts.ini playbooks/dr_standalone.yml \
  -e "pgbackrest_restore_set=20260331-114616F_20260331-120257I"

# PITR to a point in time
ansible-playbook -i inventory/hosts.ini playbooks/dr_standalone.yml \
  -e "pgbackrest_restore_type=time" \
  -e "pgbackrest_restore_target='2026-03-31 12:00:00+00'"
```

Leave `pgbackrest_restore_set: ""` (the default) to restore the latest backup.

---

### Mode 1 — Standalone (plain PostgreSQL, no Patroni)

Restores to the `[standalone]` host. PostgreSQL starts directly with no Patroni
or etcd. SSL is disabled on the restored node (certs are not distributed).

```bash
# Latest backup
ansible-playbook -i inventory/hosts.ini playbooks/dr_standalone.yml

# Specific incremental backup
ansible-playbook -i inventory/hosts.ini playbooks/dr_standalone.yml \
  -e "pgbackrest_restore_set=20260331-114616F_20260331-120257I"

# PITR
ansible-playbook -i inventory/hosts.ini playbooks/dr_standalone.yml \
  -e "pgbackrest_restore_type=time" \
  -e "pgbackrest_restore_target='2026-03-31 12:00:00+00'"
```

To rerun:

```bash
ssh dr-standalone "sudo -u postgres /usr/lib/postgresql/18/bin/pg_ctl \
  -D /var/lib/postgresql/data stop 2>/dev/null; \
  sudo rm -rf /var/lib/postgresql/data/*"

ansible-playbook -i inventory/hosts.ini playbooks/dr_standalone.yml
```

Connect directly (no VIP or load balancer):

```bash
psql -h <standalone-ip> -p 5432 -U postgres
```

### Mode 2 — Primary only, replicas join later

```bash
# Step A: restore and start primary
ansible-playbook -i inventory/hosts.ini playbooks/dr_primary.yml

# Step B: validate primary
sudo -u postgres patronictl -c /etc/patroni/config.yml list

# Step C: join all replicas
ansible-playbook -i inventory/hosts.ini playbooks/dr_join_replica.yml

# Step C (alt): join a single replica
ansible-playbook -i inventory/hosts.ini playbooks/dr_join_replica.yml --limit dr-node-2
```

### Mode 3 — Full cluster in one run

```bash
# Latest backup
ansible-playbook -i inventory/hosts.ini playbooks/dr_full_cluster.yml

# Specific incremental backup
ansible-playbook -i inventory/hosts.ini playbooks/dr_full_cluster.yml \
  -e "pgbackrest_restore_set=20260331-114616F_20260331-120257I"

# PITR
ansible-playbook -i inventory/hosts.ini playbooks/dr_full_cluster.yml \
  -e "pgbackrest_restore_type=time" \
  -e "pgbackrest_restore_target='2026-03-31 12:00:00+00'"
```

| Play | Action |
|------|--------|
| 1/8 | Preflight checks on all pg nodes |
| 2/8 | Install packages + distribute certs |
| 3/8 | Start etcd cluster |
| 4/8 | Wipe stale Patroni namespace from etcd |
| 5/8 | pgBackRest restore on primary, start Patroni, wait for Leader |
| 6/8 | Join replicas (Patroni clones from primary, serial: 1) |
| 7/8 | HAProxy + Keepalived (skipped — no lb_nodes in inventory) |
| 8/8 | Validate cluster topology |

---

## Step 6 — Patching procedure

### Stage 1 — Open scheduling conversation

```bash
ansible-playbook playbooks/patch_notify.yml -e "notify_stage=schedule"
```

### Stage 2 — Set the maintenance window in group_vars/all.yml

```yaml
patch_window_start: "2026-04-15 22:00"
patch_window_end:   "2026-04-16 02:00"
```

### Stage 3 — Send reminders

```bash
ansible-playbook playbooks/patch_notify.yml \
  -e "notify_stage=reminder_48h" \
  -e "patch_window_start='2026-04-15 22:00'" \
  -e "patch_window_end='2026-04-16 02:00'"

ansible-playbook playbooks/patch_notify.yml \
  -e "notify_stage=reminder_24h" \
  -e "patch_window_start='2026-04-15 22:00'" \
  -e "patch_window_end='2026-04-16 02:00'"

ansible-playbook playbooks/patch_notify.yml \
  -e "notify_stage=reminder_day_of" \
  -e "patch_window_start='2026-04-15 22:00'" \
  -e "patch_window_end='2026-04-16 02:00'"
```

### Stage 4 — Execute rolling patch

```bash
# Dry run first
ansible-playbook playbooks/patching.yml \
  -e "patch_dry_run=true" \
  -e "patch_window_start='2026-04-15 22:00'" \
  -e "patch_window_end='2026-04-16 02:00'"

# Live patch
ansible-playbook playbooks/patching.yml \
  -e "patch_window_start='2026-04-15 22:00'" \
  -e "patch_window_end='2026-04-16 02:00'"
```

The playbook patches replicas one at a time, then performs a `patronictl switchover`
to move leadership off the primary and patches the old primary last.

---

## Step 7 — Reindexing

```bash
# Report bloat only — no changes
ansible-playbook playbooks/reindex.yml -e "reindex_dry_run=true"

# Live reindex (default threshold: 20% dead tuple ratio)
ansible-playbook playbooks/reindex.yml

# Lower threshold
ansible-playbook playbooks/reindex.yml -e "reindex_bloat_threshold_pct=15"

# Target specific databases
ansible-playbook playbooks/reindex.yml \
  -e '{"reindex_target_databases": ["mydb", "reporting"]}'
```

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
| Archive mismatch after PG upgrade | Run `pgbackrest --stanza=postgresql-cluster stanza-upgrade` on the primary |
| Patch fails mid-run | `journalctl -u patroni -f` on affected node; cluster stays online |
| Reindex lock timeout | Retry off-peak or increase `reindex_lock_timeout` in group_vars/all.yml |
| Notification emails not sent | Check SMTP relay: `telnet localhost 25`; verify `patch_smtp_host` |

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
