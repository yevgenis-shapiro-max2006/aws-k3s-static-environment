

#!/bin/bash
set -euo pipefail

NODE_INDEX="${1:-}"
MASTER_IP="${2:-}"
MASTER_COUNT="${3:-}"

K3S_VERSION="${K3S_VERSION:-v1.37.0+k3s1}"
SSH_KEY="/home/ubuntu/.ssh/id_rsa"

if [ -z "$NODE_INDEX" ] || [ -z "$MASTER_IP" ] || [ -z "$MASTER_COUNT" ]; then
  echo "Usage: $0 <NODE_INDEX> <MASTER_IP> <MASTER_COUNT>"
  exit 1
fi

echo "[+] NODE_INDEX=$NODE_INDEX"
echo "[+] MASTER_IP=$MASTER_IP"
echo "[+] MASTER_COUNT=$MASTER_COUNT"
echo "[+] K3S_VERSION=$K3S_VERSION"

# Private K3s API traffic must bypass any system HTTP(S) proxy.
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}${MASTER_IP},127.0.0.1,localhost"
export no_proxy="$NO_PROXY"

# ============================================================
# FIRST MASTER
# ============================================================

if [ "$NODE_INDEX" -eq 0 ]; then

  echo "[+] Installing first master (cluster-init)"
  sudo apt-get install -y open-iscsi nfs-common || true
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="$K3S_VERSION" \
    INSTALL_K3S_EXEC="server \
      --cluster-init \
      --write-kubeconfig-mode 644 \
      --tls-san "$MASTER_IP" \
      --disable local-storage \
      --disable traefik" \
    sh -

  echo "[+] Waiting for K3s API..."

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  MAX_RETRIES=60
  DELAY=5

  for i in $(seq 1 "$MAX_RETRIES"); do
    if kubectl get nodes >/dev/null 2>&1; then
      echo "[+] K3s API is ready"
      break
    fi

    echo "[+] Waiting for API... ($i/$MAX_RETRIES)"
    sleep "$DELAY"
  done

  if ! kubectl get nodes >/dev/null 2>&1; then
    echo "[-] K3s API did not become ready"
    exit 1
  fi

  echo "[+] First master is ready"

# ============================================================
# ADDITIONAL MASTERS / WORKERS
# ============================================================

else

  echo "[+] Waiting for master K3s API on $MASTER_IP:6443..."

  MAX_RETRIES=120
  DELAY=5

  # The Terraform provisioner already validates TCP/6443.
  # Do not gate node joining on /readyz: the API may accept TCP while
  # Kubernetes readiness checks are still initializing. K3s agents can
  # start and retry registration once the API is ready.
  for i in $(seq 1 "$MAX_RETRIES"); do
    if timeout 3 bash -c "</dev/tcp/${MASTER_IP}/6443" 2>/dev/null; then
      echo "[+] Master TCP 6443 is reachable"
      break
    fi

    echo "[+] Waiting for master TCP 6443... ($i/$MAX_RETRIES)"
    sleep "$DELAY"
  done

  if ! timeout 5 bash -c "</dev/tcp/${MASTER_IP}/6443" 2>/dev/null; then
    echo "[-] Master TCP 6443 did not become reachable"
    echo "[-] Route to master:"
    ip route get "$MASTER_IP" || true
    echo "[-] TCP 6443 test:"
    timeout 5 bash -c "</dev/tcp/${MASTER_IP}/6443" 2>&1 || true
    exit 1
  fi

  # ==========================================================
  # GET K3S TOKEN
  # ==========================================================

  echo "[+] Waiting for K3s token..."

  TOKEN=""

  for i in $(seq 1 "$MAX_RETRIES"); do

    TOKEN=$(ssh \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=5 \
      -o BatchMode=yes \
      -i "$SSH_KEY" \
      ubuntu@"$MASTER_IP" \
      "sudo cat /var/lib/rancher/k3s/server/node-token" \
      2>/dev/null || true)

    if [ -n "$TOKEN" ]; then
      echo "[+] Successfully retrieved K3s token"
      break
    fi

    echo "[+] Token not available yet... ($i/$MAX_RETRIES)"
    sleep "$DELAY"
  done

  if [ -z "$TOKEN" ]; then
    echo "[-] Failed to get K3s token"
    exit 1
  fi

  # ==========================================================
  # ADDITIONAL MASTER
  # ==========================================================

  if [ "$NODE_INDEX" -lt "$MASTER_COUNT" ]; then

    echo "[+] Joining as additional master"
    sudo apt-get install -y open-iscsi nfs-common || true
    
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="$K3S_VERSION" \
      K3S_URL="https://${MASTER_IP}:6443" \
      K3S_TOKEN="$TOKEN" \
      INSTALL_K3S_EXEC="server \
        --disable local-storage \
        --disable traefik" \
      sh -

    echo "[+] Additional master joined"

  # ==========================================================
  # WORKER
  # ==========================================================

  else

    echo "[+] Joining as worker"
    sudo apt-get install -y open-iscsi nfs-common || true

    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="$K3S_VERSION" \
      K3S_URL="https://${MASTER_IP}:6443" \
      K3S_TOKEN="$TOKEN" \
      INSTALL_K3S_EXEC="agent" \
      sh -

    echo "[+] Worker joined"

  fi

fi

# ============================================================
# FIRST MASTER ONLY
# HELM + NGINX INGRESS
# ============================================================

if [ "$NODE_INDEX" -eq 0 ]; then

  echo "[+] Installing Helm if needed..."

  if ! command -v helm >/dev/null 2>&1; then
    curl -fsSL \
      https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 \
      | bash
  fi

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "[+] Adding ingress-nginx Helm repository..."
  helm repo add ingress-nginx \
    https://kubernetes.github.io/ingress-nginx \
    2>/dev/null || true

  helm repo update
  echo "[+] Installing NGINX Ingress Controller..."

  helm upgrade --install ingress-nginx \
    ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.publishService.enabled=true \
    --set controller.replicaCount=2 \
    --wait \
    --timeout 5m

  echo "[+] Waiting for NGINX Ingress Controller..."

  kubectl rollout status \
    deployment/ingress-nginx-controller \
    -n ingress-nginx \
    --timeout=300s

  echo ""
  echo "[+] K3s cluster status:"
  kubectl get nodes -o wide

  echo ""
  echo "[+] NGINX Ingress status:"
  kubectl get pods -n ingress-nginx

  echo ""
  echo "[+] NGINX Ingress service:"
  kubectl get svc -n ingress-nginx

  sleep 5
  echo "[+] Installing Argo Controller..."
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update

  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    --set global.domain=argo-dev.crypterio.co \
    --set server.insecure=true \
    --set server.ingress.enabled=true \
    --set server.ingress.ingressClassName=nginx \
    --set server.ingress.hostname=argo-dev.crypterio.co \
    --set server.ingress.tls=true \
    --set server.ingress.annotations."nginx\.ingress\.kubernetes\.io/backend-protocol"=HTTP \
    --set-string 'configs.secret.argocdServerAdminPassword=$2a$10$lgcvwdvggWeLl1AN14NWsePcWQczWHRQH2eiUNL9w/gN6NaelDl.G' \
    --set-string 'configs.secret.argocdServerAdminPasswordMtime=2026-09-26T16:00:00Z' \
    --wait \
    --timeout 5m

  sleep 5
  kubectl patch deployment argocd-server -n argocd \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]'
  kubectl rollout status deployment/argocd-server -n argocd

  sleep 5
  helm repo add longhorn https://charts.longhorn.io
  helm repo update

  helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --set defaultSettings.defaultDataPath=/var/lib/longhorn \
  --set defaultSettings.defaultReplicaCount=1 \
  --set defaultSettings.replicaSoftAntiAffinity=false \
  --set defaultSettings.replicaZoneSoftAntiAffinity=false \
  --set defaultSettings.replicaAutoBalance=least-effort \
  --set defaultSettings.storageMinimalAvailablePercentage=25 \
  --set defaultSettings.storageOverProvisioningPercentage=100 \
  --set defaultSettings.createDefaultDiskLabeledNodes=true \
  --set defaultSettings.disableSchedulingOnCordonedNode=true \
  --set persistence.defaultClass=true \
  --set persistence.defaultClassReplicaCount=1 \
  --set persistence.defaultFsType=ext4 \
  --set persistence.defaultDataLocality=disabled
  
  echo ""
  echo "[+] K3s bootstrap completed successfully"

fi
