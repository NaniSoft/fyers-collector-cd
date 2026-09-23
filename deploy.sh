#!/usr/bin/env sh
# Deploy the merged Fyers collector (capture + OAuth token callback in one pod).
#
#   ./deploy.sh                 # build + load + secrets + helm install
#   ./deploy.sh build           # just build + load the image into the nodes
#   ./deploy.sh secrets         # just sync .env (and rclone) into the cluster
#   ./deploy.sh install         # just helm upgrade --install
#
# Inputs (all overridable by env):
#   APP_DIR    app checkout to build the image from   (default ../fyers-collector)
#   IMAGE      image ref for a local build            (default fyers-collector:local)
#   VALUES     values overlay                          (default chart/values-local.yaml)
#   CONFIG     non-secret config.yaml                  (default ./config.yaml)
#   ENV_FILE   the .env secret file                    (default ./.env)
#   RCLONE_CONF rclone.conf (optional, for Drive backup)
#   RELEASE    helm release name                       (default fyers)
#
# Secrets live OUTSIDE helm: `fyers-env` (the whole .env as one file) and
# optional `fyers-rclone`. The data PVC is shared with any previous release.
set -eu

APP_DIR="${APP_DIR:-../fyers-collector}"
IMAGE="${IMAGE:-fyers-collector:local}"
VALUES="${VALUES:-chart/values-local.yaml}"
CONFIG="${CONFIG:-./config.yaml}"
ENV_FILE="${ENV_FILE:-./.env}"
RELEASE="${RELEASE:-fyers}"

[ -f "$CONFIG" ] || { echo "ERROR: $CONFIG missing (copy config.example.yaml)"; exit 1; }

load() {
    # kind nodes keep their OWN containerd image store: a host rebuild under the
    # same tag never reaches a running cluster, and with imagePullPolicy:
    # IfNotPresent the pod happily keeps the stale image. Stream the tar in.
    for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
        docker save "$1" | docker exec -i "$n" \
            ctr --namespace k8s.io images import - >/dev/null
        echo "loaded $1 into $n"
    done
}

build() {
    docker build -t "$IMAGE" "$APP_DIR"
    load "$IMAGE"
}

secrets() {
    [ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE missing (copy .env.example)"; exit 1; }
    # .env rides into the pod as a FILE at /app/.env (the app reads the file; no
    # app code changes for k8s). Idempotent re-apply.
    kubectl create secret generic fyers-env \
        --from-file=.env="$ENV_FILE" \
        --dry-run=client -o yaml | kubectl apply -f -
    if [ "${RCLONE_CONF:-}" != "" ] && [ -f "$RCLONE_CONF" ]; then
        kubectl create secret generic fyers-rclone \
            --from-file=rclone.conf="$RCLONE_CONF" \
            --dry-run=client -o yaml | kubectl apply -f -
        echo "rclone secret synced from $RCLONE_CONF (enable rclone in values)"
    else
        echo "NOTE: RCLONE_CONF not set — Drive backups alert-fail until a" \
             "fyers-rclone Secret exists (see README)."
    fi
}

install_chart() {
    helm upgrade --install "$RELEASE" chart/ \
        -f "$VALUES" \
        --set-file configYaml="$CONFIG" \
        "$@"
    echo
    echo "Deployed. Next:"
    echo "  kubectl get pods"
    echo "  curl http://127.0.0.1:8001/healthz"
    echo "  token click-flow: routine prompt 06:30 IST / immediate on reauth"
}

case "${1:-all}" in
    build)   build ;;
    secrets) secrets ;;
    install) shift; install_chart "$@" ;;
    all)     build; secrets; install_chart ;;
    *) echo "usage: $0 [build|secrets|install|all]"; exit 2 ;;
esac
