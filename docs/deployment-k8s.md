# Deploying eza on Kubernetes

Kubernetes runs the same image as the Docker deployment:
**eza-bookmarks** as non-root **uid/gid 10001**, state on a PVC mounted at
**/data**, probes on **/healthz**. SQLite is a single-writer embedded database,
so the deployment is deliberately **one replica** with the **Recreate**
strategy and a **ReadWriteOnce** volume. Do not scale it horizontally.

Manifests live in [`deploy/k8s/`](../deploy/k8s/):

| File | Contents |
|---|---|
| `kustomization.yaml` | namespace + resource list |
| `namespace.yaml` | `eza` namespace |
| `configmap.yaml` | non-secret env (`PUBLIC_ORIGIN`, `EZA_RP_ID`, ...) |
| `secret.yaml` | optional `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` (empty by default) |
| `pvc.yaml` | 10Gi RWO claim for `/data` |
| `deployment.yaml` | 1 replica, Recreate, probes, securityContext |
| `service.yaml` | ClusterIP on port 80 → container `http` (8080) |

## 1. Build and publish the image

```bash
nix build .#docker
docker load < result
docker tag eza:0.1.0.0 registry.example.com/eza:0.1.0.0
docker push registry.example.com/eza:0.1.0.0
```

Point the deployment at it, either by editing `deploy/k8s/deployment.yaml`
(`image:`) or without editing files:

```bash
cd deploy/k8s
kustomize edit set image eza=registry.example.com/eza:0.1.0.0
```

## 2. Configure origin and secrets

Edit `configmap.yaml`: `PUBLIC_ORIGIN` and `EZA_RP_ID` **must** be the
browser-visible HTTPS URL/host. Passkeys are bound to this origin, so decide it
before the first enrollment.

Create the optional AI-key secret (the manifest's empty Secret is replaced;
keep the real secret out of git):

```bash
kubectl -n eza create secret generic eza-secrets \
  --from-literal=ANTHROPIC_API_KEY="$(pass show anthropic/eza)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Keys are optional: the pod starts without them. AI tagging is off by default
(`EZA_AI_PROVIDER=none`), and a key-based provider with no key reports the
missing key instead of failing. The deployment command already wraps the server
in SecretSpec's `env` provider (`--file /etc/eza/secretspec.toml --profile
production`), so either keys or nothing works. See [secrets.md](secrets.md).

`configmap.yaml` carries the non-secret runtime settings: `EZA_DATA_DIR`,
`EZA_BIND`, `PUBLIC_ORIGIN`, `EZA_RP_ID`, `EZA_RP_NAME`, `EZA_LOG_LEVEL`,
`EZA_ENRICH_WORKERS`, `EZA_FETCH_TIMEOUT_MS`, `EZA_FAVICON_MAX_BYTES`,
`EZA_FAVICON_TTL_DAYS`, `EZA_SHARE_TTL_DAYS`, `EZA_ALLOW_PRIVATE_FETCH` (SSRF
guard; keep `0`), `EZA_MAX_BODY_BYTES`, `EZA_IMPORT_MAX_BYTES`,
`EZA_SNAPSHOT_MAX_BYTES`, `EZA_BACKUP_KEEP_DAYS`, and the AI settings
`EZA_AI_PROVIDER` (`none` disables AI tagging), `EZA_OLLAMA_BASE_URL`, and
`EZA_AI_MODEL` (empty selects the provider default). `EZA_CONTROL_DB` and
`EZA_USERS_DIR` default below `EZA_DATA_DIR`; `EZA_MAX_USERS` defaults to 32.
Edit the ConfigMap and let the Deployment roll; the workers stay inside the
single pod, so `replicas: 1` is still required.

## 3. Apply

```bash
kubectl apply -k deploy/k8s
kubectl -n eza rollout status deployment/eza
kubectl -n eza get pods,pvc,svc
```

Check the endpoints:

```bash
kubectl -n eza port-forward svc/eza 8080:80
curl -fsS http://127.0.0.1:8080/healthz
```

## 4. Expose it with HTTPS (required for passkeys)

Any TLS-terminating ingress works; two common setups:

**Tailscale operator** (tailnet-only, no public DNS):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: eza
  namespace: eza
spec:
  ingressClassName: tailscale
  defaultBackend:
    service:
      name: eza
      port:
        number: 80
  tls:
    - hosts:
        - eza
```

The resulting URL is `https://eza.<tailnet>.ts.net`; set
`PUBLIC_ORIGIN=https://eza.<tailnet>.ts.net` and
`EZA_RP_ID=eza.<tailnet>.ts.net` accordingly (see [tailscale.md](tailscale.md)).

**ingress-nginx + cert-manager**: create an Ingress for host
`eza.example.com` pointing at the `eza` service, let cert-manager issue the
certificate, and set `PUBLIC_ORIGIN`/`EZA_RP_ID` to that host.

Never expose plain HTTP: WebAuthn refuses insecure origins.

## Probes

All three probes hit `GET /healthz`, which returns 200 only when SQLite
answers (`SELECT 1`) and 503 otherwise:

- `startupProbe`: 30 × 2 s. It covers first-boot migrations on large databases;
- `readinessProbe`: every 10 s. It removes the pod from the Service when the
  database is unavailable;
- `livenessProbe`: every 30 s after a 20 s delay. It restarts a wedged server.

HTTP probes are used here because Kubernetes supports them natively; for
`exec` probes the image also ships `/bin/eza-bookmarks healthcheck` (same
`GET /healthz` check, exit 0/1).

The server needs no write access to the root filesystem:
`readOnlyRootFilesystem: true` plus a small `emptyDir` `/tmp`, dropped
capabilities and `allowPrivilegeEscalation: false`. The pod runs with
`runAsNonRoot`, `runAsUser/Group: 10001`, `fsGroup: 10001` (makes the PVC
writable) and `seccompProfile: RuntimeDefault`.

## Storage and backups

The PVC is mounted at `/data` and holds the control database `control.db`,
one library per account under `users/<id>/eza.db` (with
`users/<id>/snapshots/`), and the backup stamps under `backups/`. Because the
claim is `ReadWriteOnce`, only one pod can mount it at a time: the Recreate
strategy guarantees the old pod is gone before the new one starts.

Recommended backup: run the server's own backup command inside the running
pod (`VACUUM INTO` + integrity check + 14-day prune; safe while eza is
writing). It backs up the control database and every enabled account into one
stamp directory; `--user alice` narrows it to that account's library:

```bash
POD=$(kubectl -n eza get pod -l app.kubernetes.io/name=eza -o jsonpath='{.items[0].metadata.name}')
kubectl -n eza exec "$POD" -- /bin/eza-bookmarks backup
# prints: backup: /data/backups/20260101-031700
kubectl -n eza exec "$POD" -- /bin/eza-bookmarks users list
```

For scheduled off-cluster backups, use a separate Job/CronJob that mounts the
same PVC (only possible while the eza pod is not mounting it, unless the volume
is ReadWriteMany and the storage backend allows safe concurrent reads; SQLite
reads are safe, but a second *writer* is not) or, more simply, a CronJob in the
same node with an RWO volume and `strategy: Recreate` semantics via a
`ReadWriteOncePod` claim. The simplest safe pattern is to copy backups off
the volume from a Job that uses `kubectl exec`-style access or an object-store
sidecar; the image already ships `rclone` for the upload step:

```bash
kubectl -n eza exec "$POD" -- rclone copy /data/backups/<stamp> remote:eza-backups
```

Restore: scale the Deployment to zero, run a one-shot pod that mounts the same
PVC and invokes the `restore` command (it validates the stamp, backs up the
current installation, copies each library to the control row's path, and
rewrites paths when the data root moved), then scale back up:

```bash
kubectl -n eza scale deployment/eza --replicas=0
kubectl -n eza run eza-restore --rm -it --restart=Never \
  --image=registry.example.com/eza:0.1.0.0 --overrides='
  {"spec":{"containers":[{"name":"eza-restore","image":"registry.example.com/eza:0.1.0.0",
  "command":["/bin/eza-bookmarks","restore","/data/backups/<stamp>","--yes"],
  "env":[{"name":"EZA_DATA_DIR","value":"/data"}],
  "volumeMounts":[{"name":"data","mountPath":"/data"}]}],
  "volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"eza-data"}}]}}'
kubectl -n eza scale deployment/eza --replicas=1
```

Add `--dry-run` instead of `--yes` to print the plan. A stamp from the first
multi-user layout (`users/<id>.db`, no manifest) also restores; accounts whose
library is missing from the stamp keep their current copy. Page snapshots are
not part of a stamp, so copy `users/<id>/snapshots/` separately when they
matter. (Adjust the `--overrides` JSON to your registry/tag; running as uid
10001 is required for the PVC permissions.)

## Upgrades

```bash
nix build .#docker
docker load < result
docker tag eza:0.1.0.0 registry.example.com/eza:0.1.0.0 && docker push registry.example.com/eza:0.1.0.0
kubectl -n eza set image deployment/eza eza=registry.example.com/eza:0.1.0.0
kubectl -n eza rollout status deployment/eza
```

Take a backup first; database migrations run automatically at server start.

## Troubleshooting

| Symptom | Check |
|---|---|
| Pod `CrashLoopBackOff` | `kubectl -n eza logs deploy/eza --previous`; most often a PVC permission error or invalid origin. |
| Readiness never passes | `/healthz` 503 → DB issue; `kubectl -n eza exec deploy/eza -- eza-bookmarks verify`. |
| Passkeys rejected | Ingress must terminate HTTPS and pass the original Host; `PUBLIC_ORIGIN`/`EZA_RP_ID` must match. |
| PVC stuck Pending | No default StorageClass; set `storageClassName` in `pvc.yaml`. |
| Web UI 404 | Image built without the release web bundle (see [deployment-docker.md](deployment-docker.md#web-assets)). |
