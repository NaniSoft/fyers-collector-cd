# fyers-collector-cd

Helm chart + deploy scripts for the merged **fyers-collector** app: one
always-on pod that captures per-minute snapshots **and** owns the daily OAuth
click-flow login (`/callback`, `/healthz` on port 8001).

The application source lives in
[`NaniSoft/fyers-collector`](https://github.com/NaniSoft/fyers-collector).
This repo is self-contained: it carries the runtime `config.yaml`, the chart,
and the deploy scripts — a deploy reads **nothing** from the app checkout
(only the image, pulled from GHCR).

## What the chart deploys

| Object | Purpose |
|---|---|
| `Deployment` (`<release>`) | the merged collector — capture loop, EOD, candles, backup, **and** the token callback listener |
| `Service` (`<release>`) | publishes the callback port (8001) — `LoadBalancer` locally, `NodePort` on the VPS |
| `ConfigMap` (`<release>-config`) | `config.yaml`, mounted at `/app/config.yaml` |
| `PersistentVolumeClaim` | only created when `storage.existingClaim` is empty; otherwise the existing claim is reused |

Secrets live **outside** helm: `fyers-env` (the whole `.env` as one file, mounted
at `/app/.env`) and the optional `fyers-rclone` (Drive credentials).

> **The port must be 8001.** It is byte-exact with the Fyers app registration
> (`FYERS_REDIRECT_URI`). Changing it silently bounces the login back to the
> Fyers login page.

## Deploy (Docker Desktop)

```sh
./deploy.sh            # sync secrets + helm install, published GHCR image
```

That is a thin wrapper around:

```sh
kubectl create secret generic fyers-env --from-file=.env=.env \
    --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install fyers-collector chart/ \
    -f chart/values-local.yaml \
    --set-file configYaml=config.yaml
```

- `config.yaml` is **committed** (non-secret) — it is the deployed runtime config.
- `chart/values.yaml` pins the image tag; `values-local.yaml` only adds the
  cluster specifics (LoadBalancer, node pin, its own PVC).
- `.env` is **not** committed. Provide it locally (`./.env`) or keep the
  `fyers-env` Secret already in the cluster.

For the inner dev loop, build a local image instead of using the release:

```sh
./deploy.sh build      # docker build + load into the kind nodes
./deploy.sh install --set image.repository=fyers-collector --set image.tag=local
```

## Operating

```sh
kubectl get pods
curl http://127.0.0.1:8001/healthz          # token listener alive
kubectl logs deploy/fyers-collector -f
kubectl scale deploy/fyers-collector --replicas=0     # pause capture
kubectl scale deploy/fyers-collector --replicas=1     # resume
```

Login is the click-flow: when the token on the PVC is missing/expired, the pod
Telegrams a Fyers login URL (routine ~06:30 IST, immediately on the collector's
reauth signal); you log in on Fyers' page; the redirect lands on
`http://127.0.0.1:8001/callback` and the token is written to the PVC, where the
collector hot-reloads it. **One click/day IS the design.**

## Drive backup (rclone)

The collector uploads each finished day at 23:15 IST. Give it credentials with a
`fyers-rclone` Secret and `rclone.enabled=true`:

```sh
kubectl create secret generic fyers-rclone \
    --from-file=rclone.conf=/path/to/rclone.conf \
    --dry-run=client -o yaml | kubectl apply -f -
```

## Data lifecycle

The chart **owns** its PVC (`fyers-collector-data`) on the local cluster:
created on install, deleted on `helm uninstall`. That is intentional — the
volume is ephemeral by design. The nightly 23:15 job uploads the day to Drive
(`gdrive:fyers-snapshots/…`) and then resets it, so the durable copy is always
on Drive, never only on the PVC.

On the VPS overlay the same applies (a fresh claim is created).

## VPS

`chart/values-vps.yaml` is a deliberate **placeholder** — the VPS does not exist
yet. It carries the open questions (second Fyers app for `http://<vps-ip>:8001`,
firewall + callback security, real storage class). Don't deploy it yet.

## CI/CD

| Workflow | Trigger | Does |
|---|---|---|
| `lint.yml` | push to `main`, PRs | `helm lint` + `helm template` on both overlays, and `sh -n deploy.sh` |
| `bump-image.yml` | `repository_dispatch: image-published`, or manual | pins the image tag in `chart/values.yaml` and commits it |

```
fyers-collector (tag v1.2.3)
  └─ push ghcr.io/nanisoft/fyers-collector:1.2.3
  └─ repository_dispatch -> fyers-collector-cd
       └─ bump-image.yml: chart/values.yaml  image.tag: "1.2.3"
```

To pin by hand: **Actions → bump-image → Run workflow** and give it a tag.

## GitOps

`argocd/application.yaml` is a starting-point template. ArgoCD cannot use
`--set-file`, so the target values file must inline `configYaml`. Wire it up once
the VPS cluster exists.

## Layout

```
chart/                 the helm chart (Chart.yaml, values*.yaml, templates/)
config.yaml            the deployed runtime config (non-secret, committed)
deploy.sh              secrets + helm install (and a local-build dev mode)
argocd/application.yaml  GitOps template (not wired yet)
```
