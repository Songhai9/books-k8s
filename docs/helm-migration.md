# Helm ownership migration

This runbook records the one-time migration of the development cluster from
resources applied with `kubectl` and Kustomize to the Helm release
`book-notes` in namespace `book-notes`.

## Safety properties

The migration must preserve:

- every existing Kubernetes resource UID;
- the Bound PostgreSQL PVC and retained PersistentVolume;
- the PostgreSQL data;
- Gateway and HTTPRoute acceptance; and
- application health and readiness.

Do not use `helm uninstall` as a recovery action during adoption. It removes
release-owned resources. The PersistentVolume has a Helm keep policy, but the
workloads and Services do not.

## Pre-migration checks

Confirm there is no existing release and that the workloads are Ready:

```bash
helm list --all-namespaces
kubectl --namespace book-notes get deploy,statefulset,pods,pvc,svc
kubectl get pv book-notes-postgres
kubectl --namespace book-notes get gateway,httproute
```

Record the UID of every chart resource. These identifiers prove later that the
objects were updated rather than deleted and recreated.

Create a logical database backup outside the Git repositories:

```bash
kubectl --namespace book-notes exec book-notes-postgres-0 -- \
  pg_dump -U book_notes -d book_notes -Fc > book-notes-pre-helm.dump
chmod 600 book-notes-pre-helm.dump
```

## Server-side dry-run

Ask the API server to validate the adoption without persisting it:

```bash
helm upgrade --install book-notes charts/book-notes \
  --namespace book-notes \
  --take-ownership \
  --dry-run=server \
  --hide-secret
```

## Adoption

The raw resources were originally managed through Server-Side Apply by
`kubectl`. After verifying that the Helm render contained the same workload
resources and reviewing a server-side diff, Helm was allowed to claim those
fields:

```bash
helm upgrade --install book-notes charts/book-notes \
  --namespace book-notes \
  --take-ownership \
  --server-side=true \
  --force-conflicts \
  --wait=watcher \
  --timeout 10m
```

The first adoption deliberately omitted automatic rollback or atomic cleanup.
Before a successful Helm revision exists, cleanup could remove resources that
predated the release.

## Runtime issue found during migration

The PostgreSQL data directory is owned by UID 70 with mode `0700`. The init
container initially retained only the Linux `CHOWN` capability. That allows it
to change ownership, but it could not traverse the protected directory after
all other capabilities were dropped.

The init container now retains exactly:

- `CHOWN`, to change file ownership; and
- `DAC_OVERRIDE`, to traverse the existing protected data directory.

This issue was not detectable through static schema or policy checks. It was
found by the rollout and the application's readiness probe, which correctly
returned HTTP 503 while PostgreSQL was unavailable.

## Post-migration verification

Verify the release and workloads:

```bash
helm status book-notes --namespace book-notes
helm history book-notes --namespace book-notes
kubectl --namespace book-notes rollout status statefulset/book-notes-postgres
kubectl --namespace book-notes rollout status deployment/book-notes
kubectl --namespace book-notes get pods,pvc
```

Compare the captured UIDs, query the database row counts, and test:

```bash
curl --fail http://WORKER_PUBLIC_IP:30080/health
curl --fail http://WORKER_PUBLIC_IP:30080/ready
curl --fail http://WORKER_PUBLIC_IP:30080/
```

The completed migration preserved all 11 resource UIDs, the Bound PVC, and the
database contents. Helm revision 3 finished with status `deployed`.
