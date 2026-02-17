#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Single-Node Kubernetes Cluster Setup (kubeadm)
# =============================================================================
# Installs a full single-node K8s cluster with:
#   - containerd as container runtime
#   - kubeadm / kubelet / kubectl
#   - Control-plane taint removed (master = worker)
#   - NGINX Ingress Controller
#   - cert-manager
# =============================================================================

KUBE_VERSION="1.31"                       # Kubernetes minor version
CERT_MANAGER_VERSION="v1.16.3"            # cert-manager release
POD_CIDR="10.244.0.0/16"                  # Pod network CIDR

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Pre-flight checks ───────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || err "This script must be run as root (or with sudo)."

log "Detecting OS..."
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID}"
else
    err "Cannot detect OS. /etc/os-release not found."
fi

case "${OS_ID}" in
    ubuntu|debian) log "Detected Debian-based OS: ${PRETTY_NAME}" ;;
    centos|rhel|rocky|almalinux|fedora) log "Detected RHEL-based OS: ${PRETTY_NAME}" ;;
    *) err "Unsupported OS: ${OS_ID}. This script supports Debian/Ubuntu and RHEL/CentOS/Rocky." ;;
esac

# ── 1. Disable swap ─────────────────────────────────────────────────────────
log "Disabling swap..."
swapoff -a || true
sed -i '/\sswap\s/d' /etc/fstab
log "Swap disabled."

# ── 2. Load required kernel modules ─────────────────────────────────────────
log "Loading kernel modules..."
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# ── 3. Set sysctl parameters ────────────────────────────────────────────────
log "Configuring sysctl for Kubernetes networking..."
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system > /dev/null 2>&1

# ── 4. Install containerd ───────────────────────────────────────────────────
install_containerd_debian() {
    log "Installing containerd (Debian/Ubuntu)..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg apt-transport-https \
        conntrack socat ebtables ethtool > /dev/null

    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        curl -fsSL https://download.docker.com/linux/${OS_ID}/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/${OS_ID} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq containerd.io > /dev/null
}

install_containerd_rhel() {
    log "Installing containerd (RHEL-based)..."
    dnf install -y -q dnf-plugins-core conntrack-tools socat ebtables ethtool > /dev/null 2>&1 \
        || yum install -y -q yum-utils conntrack-tools socat ebtables ethtool > /dev/null 2>&1
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null \
        || yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null
    dnf install -y -q containerd.io > /dev/null 2>&1 || yum install -y -q containerd.io > /dev/null 2>&1
}

case "${OS_ID}" in
    ubuntu|debian) install_containerd_debian ;;
    *)             install_containerd_rhel   ;;
esac

# Configure containerd with systemd cgroup driver
log "Configuring containerd (systemd cgroup)..."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# Ensure CRI plugin is not disabled (containerd 2.x may list it in disabled_plugins)
sed -i 's/disabled_plugins = \["cri"\]/disabled_plugins = []/' /etc/containerd/config.toml

# Enable SystemdCgroup — works for both containerd 1.x and 2.x config formats
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Set the correct sandbox (pause) image to avoid pull issues
sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml

systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd
sleep 2
log "containerd is running."

# ── 5. Install kubeadm, kubelet, kubectl ─────────────────────────────────────
install_kube_debian() {
    log "Installing kubeadm, kubelet, kubectl (Debian/Ubuntu)..."
    apt-get install -y -qq ca-certificates curl gpg > /dev/null

    KUBE_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
    if [[ ! -f "${KUBE_KEYRING}" ]]; then
        curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/Release.key" \
            | gpg --dearmor -o "${KUBE_KEYRING}"
    fi

    echo "deb [signed-by=${KUBE_KEYRING}] https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list

    apt-get update -qq
    apt-get install -y -qq kubelet kubeadm kubectl > /dev/null
    apt-mark hold kubelet kubeadm kubectl
}

install_kube_rhel() {
    log "Installing kubeadm, kubelet, kubectl (RHEL-based)..."
    cat > /etc/yum.repos.d/kubernetes.repo <<REPOEOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/rpm/repodata/repomd.xml.key
REPOEOF
    dnf install -y -q kubelet kubeadm kubectl > /dev/null 2>&1 \
        || yum install -y -q kubelet kubeadm kubectl > /dev/null 2>&1
}

case "${OS_ID}" in
    ubuntu|debian) install_kube_debian ;;
    *)             install_kube_rhel   ;;
esac

systemctl enable --now kubelet
log "kubeadm $(kubeadm version -o short) installed."

# ── Install k9s (optional CLI) ──────────────────────────────────────────────
if [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "debian" ]]; then
    log "Installing k9s (v0.50.18)..."
    K9S_URL="https://github.com/derailed/k9s/releases/download/v0.50.18/k9s_linux_amd64.deb"
    TMP_DEB="/tmp/k9s_linux_amd64.deb"
    curl -fsSL -o "${TMP_DEB}" "${K9S_URL}" || warn "Failed downloading k9s package"
    if [[ -f "${TMP_DEB}" ]]; then
        dpkg -i "${TMP_DEB}" > /dev/null 2>&1 || {
            log "Fixing missing dependencies for k9s..."
            apt-get update -qq
            apt-get install -y -qq -f > /dev/null 2>&1 || warn "Failed to install k9s dependencies"
        }
        rm -f "${TMP_DEB}"
        log "k9s installation attempted (check with: k9s version)."
    else
        warn "k9s package not found; skipping installation."
    fi
else
    warn "Skipping k9s install on non-Debian OS. Provide a package for your distro if desired."
fi
# ── 6. Initialize the cluster ────────────────────────────────────────────────
if [[ -f /etc/kubernetes/admin.conf ]]; then
    warn "Cluster already initialized — skipping kubeadm init."
else
    log "Initializing Kubernetes cluster with kubeadm..."
    kubeadm init \
        --pod-network-cidr="${POD_CIDR}" \
        --skip-phases=addon/kube-proxy 2>&1 | tee /var/log/kubeadm-init.log

    # If kube-proxy is needed (non-cilium CNI), install it back:
    # kubeadm init phase addon kube-proxy
    # We skip it here because we'll use a standard CNI that works fine either way.
    # Re-run kube-proxy addon just in case the chosen CNI needs it:
    kubeadm init phase addon kube-proxy --pod-network-cidr="${POD_CIDR}" 2>/dev/null || true
fi

# ── 7. Configure kubectl for the current user (and root) ────────────────────
log "Setting up kubeconfig..."
export KUBECONFIG=/etc/kubernetes/admin.conf

mkdir -p "${HOME}/.kube"
cp -f /etc/kubernetes/admin.conf "${HOME}/.kube/config"
chown "$(id -u):$(id -g)" "${HOME}/.kube/config"

# Also set up for the SUDO_USER if run via sudo
if [[ -n "${SUDO_USER:-}" ]]; then
    USER_HOME=$(eval echo "~${SUDO_USER}")
    mkdir -p "${USER_HOME}/.kube"
    cp -f /etc/kubernetes/admin.conf "${USER_HOME}/.kube/config"
    chown "$(id -u "${SUDO_USER}"):$(id -g "${SUDO_USER}")" "${USER_HOME}/.kube/config"
fi

# ── 8. Remove control-plane taints (allow workloads on this node) ────────────
log "Removing control-plane taints so this node can run workloads..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
kubectl taint nodes --all node-role.kubernetes.io/master-          2>/dev/null || true
log "Taints removed — node will accept pod scheduling."

# ── 9. Install a CNI plugin (Flannel) ────────────────────────────────────────
log "Installing Flannel CNI..."
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
log "Flannel deployed."

# ── 10. Wait for the node to become Ready ────────────────────────────────────
log "Waiting for node to become Ready (up to 120 s)..."
for i in $(seq 1 24); do
    STATUS=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [[ "${STATUS}" == "True" ]]; then
        log "Node is Ready!"
        break
    fi
    sleep 5
done

if [[ "${STATUS}" != "True" ]]; then
    warn "Node not yet Ready after 120 s — continuing anyway (it may take a bit longer)."
fi

# ── 11. Install NGINX Ingress Controller ─────────────────────────────────────
log "Installing NGINX Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/baremetal/deploy.yaml

log "Waiting for ingress-nginx controller to be available (up to 180 s)..."
kubectl -n ingress-nginx wait deployment ingress-nginx-controller \
    --for=condition=Available --timeout=180s 2>/dev/null || \
    warn "Ingress controller not ready within 180 s — check with: kubectl -n ingress-nginx get pods"

log "NGINX Ingress Controller installed."

# ── 12. Install cert-manager ─────────────────────────────────────────────────
log "Installing cert-manager ${CERT_MANAGER_VERSION}..."
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

log "Waiting for cert-manager deployments (up to 180 s)..."
kubectl -n cert-manager wait deployment cert-manager \
    --for=condition=Available --timeout=180s 2>/dev/null || true
kubectl -n cert-manager wait deployment cert-manager-webhook \
    --for=condition=Available --timeout=180s 2>/dev/null || true
kubectl -n cert-manager wait deployment cert-manager-cainjector \
    --for=condition=Available --timeout=180s 2>/dev/null || true

log "cert-manager installed."

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo -e "${GREEN} Single-node Kubernetes cluster is ready!${NC}"
echo "============================================================"
echo ""
kubectl get nodes -o wide
echo ""
echo "Installed components:"
echo "  - containerd (container runtime)"
echo "  - kubeadm / kubelet / kubectl  v${KUBE_VERSION}.x"
echo "  - Flannel CNI (pod networking)"
echo "  - NGINX Ingress Controller"
echo "  - cert-manager ${CERT_MANAGER_VERSION}"
echo "  - k9s (Kubernetes CLI)"
echo ""
echo "KUBECONFIG: ${HOME}/.kube/config"
echo ""
echo "Next steps:"
echo "  kubectl get pods -A            # verify all system pods"
echo "  kubectl get svc -n ingress-nginx  # ingress controller service"
echo ""
