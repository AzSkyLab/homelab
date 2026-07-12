# Neo4j CE Backup/DR Simulation

Homelab simulation of the work design ("Night Ferry" — see the secondBrain vault:
`03 Architecture/Neo4j CE Backup and DR.md`). Demonstrates the core concept:
**back up a running Neo4j Community instance with zero downtime by snapshotting the
live volume and dumping from a clone**, shipping artifacts to a second "region",
and failing over with a single git commit.

## Azure → homelab mapping

| Azure (real design) | Homelab simulation |
|---|---|
| Azure Disk CSI + VolumeSnapshots | Longhorn + snapshot-controller (`longhorn-snap` VolumeSnapshotClass, in-cluster `type: snap`) |
| Region eastus2 / centralus | Namespaces `neo4j-eastus2` / `neo4j-centralus` |
| Storage accounts + `azb://` dumps | MinIO per namespace, `mc` upload |
| Blob Object Replication | MinIO bucket replication east→west (async, server-side) |
| Azure Private DNS record flip | CoreDNS `neo4j.db.home.lab` record (10.0.20.90 ⇄ 10.0.20.91) |
| Push-button failover (activate-dr PR) | One commit: centralus StatefulSet `replicas: 0→1` + CoreDNS record flip |
| Weekly restore drill | `neo4j-restore-drill` CronJob (suspended; trigger manually) |

## Components

- `kubernetes/apps/longhorn/` — Longhorn 1.12 + snapshot-controller (infrastructure)
- `kubernetes/apps/neo4j-dr-sim/` — the simulation Application
- `kubernetes/manifests/neo4j-dr-sim/` — all manifests (numbered by sync order)
- Longhorn UI: https://longhorn.home.lab — watch snapshots/clones live
- Neo4j primary: `bolt://neo4j.db.home.lab:7687`, browser at `http://neo4j.db.home.lab:7474` (user `neo4j`, demo password in the manifests)

**Demo credentials are committed on purpose** (`neo4jdemo-2026`, `minioadmin123`) —
lab-only simulation, nothing real behind them. Don't reuse the pattern for real apps.

## The backup pipeline (runs automatically)

1. `neo4j-snapshot` CronJob (hourly): VolumeSnapshot of the **running** primary PV; keeps newest 8.
2. `neo4j-clone-dump` CronJob (every 6 h): clone PVC from newest snapshot → worker pod
   starts Neo4j on the clone (**crash recovery**), sanity count, clean stop,
   `neo4j-admin database check` + `dump` (system + neo4j) → upload to east MinIO
   → `latest-verified` marker. **Production pod is never touched.**
3. MinIO bucket replication ships `dumps/prod/<ts>/` to the centralus MinIO.

## Demo runbook

```bash
# 0) Watch the pieces come up
kubectl get pods -n neo4j-eastus2 -w

# 1) Take an on-demand snapshot + backup right now (don't wait for the schedule)
kubectl create job snap-now --from=cronjob/neo4j-snapshot -n neo4j-eastus2
kubectl create job backup-now --from=cronjob/neo4j-clone-dump -n neo4j-eastus2
kubectl logs -f job/backup-now -n neo4j-eastus2

# 2) Confirm replication to the DR "region"
kubectl exec -n neo4j-centralus deploy/minio -- ls /data/dumps/prod/

# 3) Run the restore drill in centralus
kubectl create job drill-manual --from=cronjob/neo4j-restore-drill -n neo4j-centralus
kubectl logs -f job/drill-manual -n neo4j-centralus

# 4) Negative test — prove the safety net (dump refuses an unrecovered clone):
#    edit the worker to skip the recovery step, or exec into a clone and try
#    neo4j-admin database dump directly: it must fail with
#    "Active logical log detected ... recover database before running the dump"
```

## Failover (the one-PR demo)

Single commit, two changes:

1. `kubernetes/manifests/neo4j-dr-sim/60-neo4j-centralus.yml` — `replicas: 0` → `1`
   (hydrate initContainers load the newest verified dump before the server starts)
2. `kubernetes/apps/coredns/coredns.yml` — `neo4j.db IN A 10.0.20.90` → `10.0.20.91`

Push → ArgoCD syncs → DR instance hydrates and comes up → DNS now answers with the
centralus LB. Verify:

```bash
kubectl get pods -n neo4j-centralus -w
dig +short neo4j.db.home.lab @10.0.20.53
cypher-shell -a bolt://neo4j.db.home.lab:7687 -u neo4j -p 'neo4jdemo-2026' \
  "MATCH (n:Person) RETURN count(n);"
```

Failback: revert the commit (replicas back to 0, DNS back to .90). Delete the
centralus PVC (`data-neo4j-0`) afterwards if you want the next failover to
re-hydrate from a fresh dump.

## What this does NOT simulate

- Real cross-region latency / paired-region semantics
- Azure workload identity (MinIO uses static demo creds)
- The two-person PR-approval gate (single-owner repo)
- `azb://` direct dump-to-blob (uses dump-to-emptyDir + `mc cp`, which is the
  design's documented fallback path anyway)
