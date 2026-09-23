# fyers-collector-cd

Helm chart + deploy scripts for the merged **fyers-collector** app: one
always-on pod that captures per-minute snapshots **and** owns the daily OAuth
click-flow login (`/callback`, `/healthz` on port 8001).

The application source lives in
[`NaniSoft/fyers-collector`](https://github.com/NaniSoft/fyers-collector).

## What the chart deploys

| Object | Purpose |
|---|---|
| `Deployment` (`<release>`) | the merged collector — capture loop, EOD, candles, backup, **and** the token callback listener |
| `Service` (`<release>`) | publishes the callback port (8001) — `LoadBalancer` locally, `NodePort` on the VPS |
| `ConfigMap` (`<release>-config`) | your `config.yaml`, mounted at `/app/config.yaml` |
| `PersistentVolumeClaim` | only created when `storage.existingClaim` is empty; otherwise the existing claim is reused |

Secrets live **outside** helm: `fyers-env` (the whole `.env` as one file, mounted
at `/app/.env`) and the optional `fyers-rclone` (Drive credentials).

> **The port must be 8001.** It is byte-exact with the Fyers app registration
> (`FYERS_REDIRECT_URI`). Changing it silently bounces the login back to the
> Fyers login page.

## Deploy locally (Docker Desktop / kind)

```sh
# from this repo, with the app checked out at ../fyers-collector
cp config.example.yaml config.yaml      # then edit
cp ../fyers-collector/.env.example .env # then fill in Fyers/Telegram secrets

./deploy.sh                             # build + load + secrets + helm install
```

`deploy.sh` is a thin wrapper around:

```sh
docker build -t fyers-collector:local ../fyers-collector
kubectl create secret generic fyers-env --from-file=.env=.env \
    --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install fyers chart/ \
    -f chart/values-local.yaml \
    --set-file configYaml=config.yaml
```

`--set-file configYaml=config.yaml` keeps `config.yaml` the single source of
truth — the chart never carries a copy (a config edit re-rolls the pod via the
`checksum/config` annotation).

## Operating

```sh
kubectl get pods
curl http://127.0.0.1:8001/healthz          # token listener alive
kubectl logs deploy/fyers -f
kubectl scale deploy/fyers --replicas=0     # pause capture
kubectl scale deploy/fyers --replicas=1     # resume
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

## VPS

`chart/values-vps.yaml` is a deliberate **placeholder** — the VPS does not exist
yet. It carries the open questions (second Fyers app for `http://<vps-ip>:8001`,
firewall + callback security, real storage class). Don't deploy it yet.

## CI/CD

| Workflow | Trigger | Does |
|---|---|---|
| `lint.yml` | push to `main`, PRs | `helm lint` + `helm template` on both overlays, and a `sh -n` syntax check of `deploy.sh` |
| `bump-image.yml` | `repository_dispatch: image-published`, or manual | pins the image tag in `chart/values-vps.yaml` and commits it |

The app repo's release workflow dispatches the tag here:

```
fyers-collector (tag v1.2.3)
  └─ push ghcr.io/nanisoft/fyers-collector:1.2.3
  └─ repository_dispatch -> fyers-collector-cd
       └─ bump-image.yml: chart/values-vps.yaml  image.tag: 1.2.3
```

To pin by hand: **Actions → bump-image → Run workflow** and give it a tag
(e.g. `1.2.3`).

ArgoCD (or a manual `helm upgrade`) then syncs `chart/values-vps.yaml`.

## GitOps

`argocd/application.yaml` is a starting-point template. ArgoCD cannot use
`--set-file`, so the target values file must inline `configYaml`. Wire it up once
the VPS cluster exists.

## Layout

```
chart/                 the helm chart (Chart.yaml, values*.yaml, templates/)
deploy.sh              local build + secrets + helm install
argocd/application.yaml  GitOps template (not wired yet)
config.example.yaml    copy to config.yaml (non-secret runtime config)
```
