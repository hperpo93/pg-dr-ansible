INVENTORY  := inventory/hosts.ini
ANSIBLE    := ansible-playbook -i $(INVENTORY)
AP_EXTRA   ?=

# Backup set to restore (leave empty for latest)
BACKUP_SET ?=
# Restore type: default | time | name | lsn
RESTORE_TYPE ?= default
# Restore target (used with time/name/lsn)
RESTORE_TARGET ?=

# Build extra-vars string from restore options
_RESTORE_VARS :=
ifneq ($(BACKUP_SET),)
  _RESTORE_VARS += -e "pgbackrest_restore_set=$(BACKUP_SET)"
endif
ifneq ($(RESTORE_TYPE),default)
  _RESTORE_VARS += -e "pgbackrest_restore_type=$(RESTORE_TYPE)"
endif
ifneq ($(RESTORE_TARGET),)
  _RESTORE_VARS += -e "pgbackrest_restore_target='$(RESTORE_TARGET)'"
endif

.DEFAULT_GOAL := help

# ── Help ──────────────────────────────────────────────────────────────────────

.PHONY: help
help:
	@echo ""
	@echo "PostgreSQL DR Automation — available targets"
	@echo ""
	@echo "  Bootstrap"
	@echo "    make cluster           Bootstrap full Patroni cluster (no restore)"
	@echo "    make cluster-primary   Bootstrap primary only"
	@echo "    make cluster-reset     Stop + wipe all nodes, then bootstrap"
	@echo ""
	@echo "  Backups  (run on dr-node-1)"
	@echo "    make backup-full       Take a full pgBackRest backup"
	@echo "    make backup-incr       Take an incremental pgBackRest backup"
	@echo "    make backup-list       List all available backups"
	@echo "    make stanza-upgrade    Upgrade stanza after a PG major version change"
	@echo ""
	@echo "  DR Restore"
	@echo "    make dr-standalone     Restore to standalone node (no Patroni)"
	@echo "    make dr-primary        Restore primary only"
	@echo "    make dr-join-replica   Join replica(s) to a running primary"
	@echo "    make dr-full           Restore full 3-node cluster"
	@echo ""
	@echo "  Operations"
	@echo "    make patch             Rolling cluster patch"
	@echo "    make patch-dry         Dry-run patch (no changes)"
	@echo "    make notify-schedule   Send patch scheduling notification"
	@echo "    make reindex           Detect bloat + REINDEX CONCURRENTLY"
	@echo "    make reindex-dry       Report bloat only (no changes)"
	@echo ""
	@echo "  Utilities"
	@echo "    make status            Show Patroni cluster topology"
	@echo "    make ping              Test Ansible connectivity to all nodes"
	@echo "    make setup             Copy all.yml.example → all.yml (first-time setup)"
	@echo "    make reset-nodes       Stop services + wipe PGDATA + etcd on pg nodes"
	@echo "    make reset-standalone  Stop + wipe PGDATA on dr-standalone"
	@echo ""
	@echo "  Restore options (pass as make vars):"
	@echo "    BACKUP_SET=<label>     Restore a specific backup e.g. 20260331-114616F_20260331-120257I"
	@echo "    RESTORE_TYPE=time      Use PITR"
	@echo "    RESTORE_TARGET='...'   PITR timestamp e.g. '2026-03-31 12:00:00+00'"
	@echo "    AP_EXTRA='...'         Pass extra flags to ansible-playbook"
	@echo ""
	@echo "  Examples:"
	@echo "    make dr-standalone BACKUP_SET=20260331-114616F_20260331-120257I"
	@echo "    make dr-full RESTORE_TYPE=time RESTORE_TARGET='2026-03-31 12:00:00+00'"
	@echo "    make patch AP_EXTRA=\"-e patch_window_start='2026-04-15 22:00' -e patch_window_end='2026-04-16 02:00'\""
	@echo ""

# ── First-time setup ──────────────────────────────────────────────────────────

.PHONY: setup
setup:
	@if [ -f inventory/group_vars/all.yml ]; then \
	  echo "inventory/group_vars/all.yml already exists — skipping."; \
	else \
	  cp inventory/group_vars/all.yml.example inventory/group_vars/all.yml; \
	  echo "Created inventory/group_vars/all.yml — fill in CHANGE_ME values before running."; \
	fi

# ── Connectivity ──────────────────────────────────────────────────────────────

.PHONY: ping
ping:
	ansible -i $(INVENTORY) all -m ping

# ── Cluster bootstrap ─────────────────────────────────────────────────────────

.PHONY: cluster
cluster:
	$(ANSIBLE) playbooks/patroni_start.yml $(AP_EXTRA)

.PHONY: cluster-primary
cluster-primary:
	$(ANSIBLE) playbooks/patroni_start.yml --limit pg_primary $(AP_EXTRA)

.PHONY: cluster-reset
cluster-reset: reset-nodes cluster

# ── Backups ───────────────────────────────────────────────────────────────────

.PHONY: backup-full
backup-full:
	ssh $$(ansible -i $(INVENTORY) pg_primary --list-hosts -q | head -1 | tr -d ' ') \
	  "sudo -u postgres pgbackrest --stanza=postgresql-cluster backup --type=full --log-level-console=info"

.PHONY: backup-incr
backup-incr:
	ssh $$(ansible -i $(INVENTORY) pg_primary --list-hosts -q | head -1 | tr -d ' ') \
	  "sudo -u postgres pgbackrest --stanza=postgresql-cluster backup --type=incr --log-level-console=info"

.PHONY: backup-list
backup-list:
	ssh $$(ansible -i $(INVENTORY) pg_primary --list-hosts -q | head -1 | tr -d ' ') \
	  "sudo -u postgres pgbackrest --stanza=postgresql-cluster info"

.PHONY: stanza-upgrade
stanza-upgrade:
	ssh $$(ansible -i $(INVENTORY) pg_primary --list-hosts -q | head -1 | tr -d ' ') \
	  "sudo -u postgres pgbackrest --stanza=postgresql-cluster stanza-upgrade --log-level-console=info"

# ── DR restore ────────────────────────────────────────────────────────────────

.PHONY: dr-standalone
dr-standalone:
	$(ANSIBLE) playbooks/dr_standalone.yml $(_RESTORE_VARS) $(AP_EXTRA)

.PHONY: dr-primary
dr-primary:
	$(ANSIBLE) playbooks/dr_primary.yml $(_RESTORE_VARS) $(AP_EXTRA)

.PHONY: dr-join-replica
dr-join-replica:
	$(ANSIBLE) playbooks/dr_join_replica.yml $(AP_EXTRA)

.PHONY: dr-full
dr-full:
	$(ANSIBLE) playbooks/dr_full_cluster.yml $(_RESTORE_VARS) $(AP_EXTRA)

# ── Operations ────────────────────────────────────────────────────────────────

.PHONY: patch
patch:
	$(ANSIBLE) playbooks/patching.yml $(AP_EXTRA)

.PHONY: patch-dry
patch-dry:
	$(ANSIBLE) playbooks/patching.yml -e "patch_dry_run=true" $(AP_EXTRA)

.PHONY: notify-schedule
notify-schedule:
	$(ANSIBLE) playbooks/patch_notify.yml -e "notify_stage=schedule" $(AP_EXTRA)

.PHONY: reindex
reindex:
	$(ANSIBLE) playbooks/reindex.yml $(AP_EXTRA)

.PHONY: reindex-dry
reindex-dry:
	$(ANSIBLE) playbooks/reindex.yml -e "reindex_dry_run=true" $(AP_EXTRA)

# ── Utilities ─────────────────────────────────────────────────────────────────

.PHONY: status
status:
	ssh $$(ansible -i $(INVENTORY) pg_primary --list-hosts -q | head -1 | tr -d ' ') \
	  "sudo -u postgres patronictl -c /etc/patroni/config.yml list"

.PHONY: reset-nodes
reset-nodes:
	@echo "Stopping services and wiping PGDATA + etcd on all pg nodes..."
	@for node in $$(ansible -i $(INVENTORY) pg_nodes --list-hosts -q | tr -d ' '); do \
	  echo "  wiping $$node"; \
	  ssh $$node "sudo systemctl stop patroni; sudo systemctl stop etcd; \
	              sudo pkill -u postgres -9 2>/dev/null; \
	              sudo rm -rf /var/lib/postgresql/data/*; \
	              sudo rm -rf /var/lib/etcd/*" ; \
	done
	@echo "Done."

.PHONY: reset-standalone
reset-standalone:
	@echo "Stopping PostgreSQL and wiping PGDATA on dr-standalone..."
	@STANDALONE=$$(ansible -i $(INVENTORY) standalone --list-hosts -q | head -1 | tr -d ' '); \
	ssh $$STANDALONE \
	  "sudo -u postgres /usr/lib/postgresql/$$(sudo -u postgres psql -tAc 'SHOW server_version_num' 2>/dev/null | cut -c1-2)*/bin/pg_ctl \
	   -D /var/lib/postgresql/data stop 2>/dev/null; \
	   sudo rm -rf /var/lib/postgresql/data/*" 2>/dev/null || true
	@echo "Done."
