# Book Notes Kubernetes

Kubernetes manifests for the Book Notes application. The repository deploys
the application and PostgreSQL to the kubeadm cluster provisioned by
`books-infra`, then exposes HTTP through Envoy Gateway and Gateway API.

## Architecture

- Namespace `book-notes` isolates application resources.
- A one-replica Deployment runs `ghcr.io/songhai9/books:1.0.0`.
- A one-replica StatefulSet runs `postgres:17.10-alpine3.23`.
- PostgreSQL is reachable only through a headless internal Service.
- A retained 5 GiB hostPath PersistentVolume stores lab data on the worker.
- Envoy Gateway implements Gateway API and exposes HTTP through NodePort 30080.
- A Gateway listener accepts HTTP and an HTTPRoute forwards `/` to the app.

This first storage implementation is intentionally local to the single worker.
It survives pod replacement but not deletion of the EC2 worker. AWS EBS CSI is
the future production-style replacement.

## Prerequisites

- Kubernetes `v1.36.x` and a compatible `kubectl` client
- Helm `v4.2.4`
- Envoy Gateway `v1.8.3`
- Gateway API CRDs bundled with Envoy Gateway `v1.8.3`
- A firewall rule allowing TCP `30080` to the worker
- A local kubeconfig authorized as cluster administrator

Kubernetes supports `kubectl` within one minor version of the API server. Do
not mutate this `v1.36` cluster with the older `v1.30.5` client currently on the
Mac. Until that client is upgraded, connect to the control plane and use its
matching `kubectl v1.36.3`.

## Install Envoy Gateway

The official versioned installation manifest installs Envoy Gateway and the
Gateway API CRDs:

```bash
kubectl apply --server-side \
  -f https://github.com/envoyproxy/gateway/releases/download/v1.8.3/install.yaml
kubectl wait --timeout=5m \
  --namespace envoy-gateway-system \
  deployment/envoy-gateway \
  --for=condition=Available
```

## Create the database secret

Do not put a real password in Git. Create the namespace and a random Secret
directly in the cluster:

```bash
kubectl apply -f manifests/base/namespace.yaml
kubectl --namespace book-notes create secret generic book-notes-database \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -base64 32)"
```

`manifests/base/secret.example.yaml` only documents the expected resource and
is deliberately excluded from the Kustomize deployment.

## Deploy with Helm

The development cluster is managed by the `book-notes` Helm release. Render
and validate changes before upgrading it:

```bash
helm lint charts/book-notes --strict --namespace book-notes
helm template book-notes charts/book-notes --namespace book-notes
helm upgrade --install book-notes charts/book-notes \
  --namespace book-notes \
  --server-side=true \
  --wait=watcher \
  --timeout 10m
```

The one-time adoption of the resources previously managed by Kustomize is
documented in [`docs/helm-migration.md`](docs/helm-migration.md). Do not repeat
the ownership migration flags during normal upgrades.

Wait for both workloads and inspect Gateway API status:

```bash
kubectl --namespace book-notes rollout status statefulset/book-notes-postgres
kubectl --namespace book-notes rollout status deployment/book-notes
kubectl get gatewayclass book-notes-envoy
kubectl --namespace book-notes get gateway,httproute
```

Find the worker public address in the infrastructure repository and test:

```bash
terraform -chdir=../books-infra/terraform output -raw kubernetes_worker_public_ip
curl http://WORKER_PUBLIC_IP:30080/health
curl http://WORKER_PUBLIC_IP:30080/ready
```

## Continuous integration

The `Kubernetes CI` workflow runs for every pull request, so its final status
can safely be required by the `main` branch ruleset. It:

1. lints the YAML sources and renders both Kustomize and Helm bundles;
2. verifies that both renderers produce the same workload resources;
3. rejects any Kubernetes Secret accidentally included in either bundle;
4. passes both bundles as a GitHub Actions artifact to isolated jobs;
5. validates built-in Kubernetes resources against `v1.36` schemas; and
6. checks workload security and operational practices with kube-linter.

Gateway API and Envoy Gateway objects are custom resources, so kubeconform
skips their schemas. Their live admission and status are verified when the
bundle is deployed to a cluster.

## Continuous deployment

The `Deploy to Kubernetes` workflow performs a controlled manual deployment.
It exchanges GitHub's OIDC token for short-lived AWS credentials, sends an SSM
Run Command to the kubeadm control plane, checks out the exact workflow commit,
and runs the Helm upgrade from inside the cluster network.

The workflow requires two non-secret repository variables:

- `AWS_KUBERNETES_CD_ROLE_ARN`, output by `books-infra` Terraform; and
- `KUBERNETES_CONTROL_PLANE_INSTANCE_ID`, also output by Terraform.

The deployment waits for both workloads, verifies Gateway API conditions, and
smoke-tests `/health`, `/ready`, and the homepage. It is initially available
only through `workflow_dispatch` on `main`; automatic release deployments will
be enabled after the manual path has been proven.

## Helm chart

The chart under `charts/book-notes` packages the same workloads as the raw
manifests. Its default values describe the current development cluster while
keeping image tags, resources, storage, node placement, and Gateway exposure
configurable.

Validate and render it locally:

```bash
helm lint charts/book-notes --strict --namespace book-notes
helm template book-notes charts/book-notes --namespace book-notes
```

The chart references the existing `book-notes-database` Secret and never
renders credentials. The live resources are owned by Helm release
`book-notes`. Kustomize remains temporarily in the repository as an independent
rendering reference while the deployment pipeline is built.

## Security and lifecycle notes

- The committed repository contains no database credentials or kubeconfig.
- PostgreSQL has no NodePort and is not reachable from the Internet.
- Application probes distinguish process health from database readiness.
- CPU and memory requests and limits protect the small worker.
- The PersistentVolume reclaim policy is `Retain`; deleting the claim does not
  automatically erase the host directory.
- TLS will be added later as an HTTPS Gateway listener backed by a Secret.
