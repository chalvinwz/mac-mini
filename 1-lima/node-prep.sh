#!/usr/bin/env bash
# Prepare an Ubuntu 26.04 node for kubeadm. Idempotent — safe to re-run.
# Run as root on BOTH control-plane-01 and worker-01 before kubeadm init/join.
set -euo pipefail

K8S_MINOR="${K8S_MINOR:-v1.36}"

echo "==> 1/5 swap off"
# kubeadm's preflight refuses to run with swap enabled. OrbStack images ship with
# a large swapfile, so this is not optional here.
swapoff -a
sed -i.bak -E 's@^([^#].*\sswap\s)@#\1@' /etc/fstab || true

echo "==> 2/5 kernel modules"
# overlay: containerd's snapshotter. br_netfilter: makes bridged traffic visible
# to iptables, without which Service routing silently does nothing.
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo "==> 3/5 sysctl"
cat >/etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo "==> 4/5 containerd"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq containerd apt-transport-https ca-certificates curl gpg
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
# Ubuntu 26.04 is cgroup v2 only and kubelet uses the systemd driver. containerd
# defaults to cgroupfs; leaving them mismatched makes kubelet fail at startup
# with an error that does not mention cgroups.
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Registry mirrors in /etc/containerd/certs.d are ignored unless config_path points
# at them. The generated config has config_path twice, under different plugins, so
# the substitution is scoped to the CRI images registry section only.
sed -i "/\[plugins\.'io\.containerd\.cri\.v1\.images'\.registry\]/,/^ *\[/ s|config_path = ''|config_path = '/etc/containerd/certs.d'|" \
  /etc/containerd/config.toml
mkdir -p /etc/containerd/certs.d

systemctl restart containerd
systemctl enable --now containerd >/dev/null

# Without this, every crictl invocation probes containerd, CRI-O and cri-dockerd
# in turn and prints three deprecation warnings before doing anything useful.
cat >/etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

echo "==> 5/5 kubeadm, kubelet, kubectl, crictl (${K8S_MINOR})"
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
# cri-tools ships crictl and lives in the same repo, so it tracks the Kubernetes minor
# version instead of drifting. Talking to containerd directly is the only way to debug
# an image pull that kubelet reports as a bare ImagePullBackOff.
apt-get install -y -qq kubelet kubeadm kubectl cri-tools
# Without the hold, an unattended upgrade can move the control plane a minor
# version while you are not looking.
apt-mark hold kubelet kubeadm kubectl cri-tools >/dev/null
systemctl enable kubelet >/dev/null

echo
echo "ready: $(kubeadm version -o short)  containerd $(containerd --version | awk '{print $3}')"
echo "swap:  $(free -m | awk '/Swap:/{print $2}')MB (want 0)"
