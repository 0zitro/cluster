#!/usr/bin/env bash

VPS_IP=$(curl -4 ifconfig.me)
K8S_VERSION="1.32"
CALICO_VERSION="3.29.3"
CERTMANAGER_VERSION="1.17.1"

# Disable apparmor
systemctl stop apparmor
systemctl disable apparmor

# Disable swap
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# Add required modules, persist them in modules-load.d
echo "overlay" > /etc/modules-load.d/k8s-modules.conf
echo "br_netfilter" >> /etc/modules-load.d/k8s-modules.conf
modprobe overlay
modprobe br_netfilter

# sysctl params required by setup, params persist across reboots
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/30-ip-forwarding.conf
echo "net.bridge.bridge-nf-call-ip6tables = 1" >> /etc/sysctl.d/30-ip-forwarding.conf
echo "net.bridge.bridge-nf-call-iptables = 1" >> /etc/sysctl.d/30-ip-forwarding.conf
# Apply sysctl params without reboot
sysctl --system

# General repo utils
apt-get update
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y dist-upgrade
# apt-transport-https may be a dummy package; if so, you can skip that package
apt-get install -y apt-transport-https ca-certificates curl gpg

# Keyrings:
mkdir -p -m 755 /etc/apt/keyrings
#  - Kubernetes:
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring_v${K8S_VERSION}.gpg
#  - Helm:
curl https://baltocdn.com/helm/signing.asc | gpg --dearmor --yes -o /etc/apt/keyrings/helm.gpg
# Visibility:
chmod -R a+r /etc/apt/keyrings

# Repos:
#  - Kubernetes:
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring_v${K8S_VERSION}.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
#  - Helm:
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" > /etc/apt/sources.list.d/helm-stable-debian.list

# install tools
apt-get -y update
apt install -y --allow-change-held-packages containerd kubeadm kubectl kubelet kubernetes-cni helm
apt-mark hold kubelet kubeadm kubectl

# Reset previous install
kubeadm reset -f
rm -rf /etc/cni/net.d
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X

# Reset configs and restart services
mkdir -p /etc/containerd
containerd config default | sed -E 's/SystemdCgroup = false/SystemdCgroup = true/; s%sandbox_image = ".*"%sandbox_image = "registry.k8s.io/pause:3.10"%' > /etc/containerd/config.toml
systemctl restart containerd
systemctl enable kubelet
systemctl restart kubelet

# Init cluster
kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=$VPS_IP
export KUBECONFIG=/etc/kubernetes/admin.conf

# allow master to run pods
kubectl taint nodes --all "node-role.kubernetes.io/control-plane:NoSchedule-" || true

# setup kubectl
mkdir -p $HOME/.kube
cp /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# Use calico as the networking model
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml

# Install ingress
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install nginx-ingress ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.hostNetwork=true \
  --set controller.kind=DaemonSet \
  --set controller.service.type=ClusterIP
