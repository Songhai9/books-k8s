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

## Deploy

Render locally before applying:

```bash
kubectl kustomize manifests
kubectl apply --server-side --kustomize manifests
```

If operating from the control plane, copy the `manifests/` directory to the
host first and run the same commands there. The kubeconfig installed by Ansible
under `/home/ubuntu/.kube/config` is already selected for the Ubuntu user.

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

1. lints the YAML sources and renders the complete Kustomize bundle;
2. rejects any Kubernetes Secret accidentally included in that bundle;
3. passes the rendered bundle as a GitHub Actions artifact to isolated jobs;
4. validates built-in Kubernetes resources against `v1.36` schemas; and
5. checks workload security and operational practices with kube-linter.

Gateway API and Envoy Gateway objects are custom resources, so kubeconform
skips their schemas. Their live admission and status are verified when the
bundle is deployed to a cluster.

## Security and lifecycle notes

- The committed repository contains no database credentials or kubeconfig.
- PostgreSQL has no NodePort and is not reachable from the Internet.
- Application probes distinguish process health from database readiness.
- CPU and memory requests and limits protect the small worker.
- The PersistentVolume reclaim policy is `Retain`; deleting the claim does not
  automatically erase the host directory.
- TLS will be added later as an HTTPS Gateway listener backed by a Secret.
