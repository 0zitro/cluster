#!/usr/bin/env bash

VPS_IP=$(curl -4 ifconfig.me)
K8S_VERSION="1.32"
CILIUM_VERSION="1.17.2"
CERTMANAGER_VERSION="1.17.1"

# sysctl params required by setup, params persist across reboots
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/30-ip-forwarding.conf
# Apply sysctl params without reboot
sysctl --system

# General repo utils
apt-get update
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y dist-upgrade
# apt-transport-https may be a dummy package; if so, you can skip that package
apt-get install -y apt-transport-https ca-certificates curl gpg

# Keyrings:
# If the directory `/etc/apt/keyrings` does not exist, it should be created before the curl command, read the note below.
mkdir -p -m 755 /etc/apt/keyrings

#  - Docker:
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
#  - Kubernetes:
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring_v${K8S_VERSION}.gpg
#  - Helm:
curl https://baltocdn.com/helm/signing.asc | gpg --dearmor --yes -o /etc/apt/keyrings/helm.gpg
# Visibility:
chmod -R a+r /etc/apt/keyrings

# Repos:
#  - Docker:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" > /etc/apt/sources.list.d/docker.list
#  - Kubernetes:
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring_v${K8S_VERSION}.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
#  - Helm:
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" > /etc/apt/sources.list.d/helm-stable-debian.list

# use systemd for the management of the container’s cgroups
mkdir -p /etc/docker
cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

# install tools
apt-get -y update
apt install -y --allow-change-held-packages docker-ce kubeadm kubectl kubelet kubernetes-cni helm
apt-mark hold kubelet kubeadm kubectl

# Reset previous install
kubeadm reset -f
rm -f /etc/cni/net.d/05-cilium.conflist
rm -f /etc/cni/net.d/.kubernetes-cni-keep
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X

# Reset configs and restart services
containerd config default | sed -E 's/SystemdCgroup = false/SystemdCgroup = true/; s%sandbox_image = ".*"%sandbox_image = "registry.k8s.io/pause:3.10"%' > /etc/containerd/config.toml
systemctl restart containerd
systemctl enable kubelet
systemctl restart kubelet

# Init cluster
kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=$VPS_IP

# allow master to run pods
kubectl taint nodes --all "node-role.kubernetes.io/control-plane:NoSchedule-"

# setup kubectl
mkdir -p $HOME/.kube
cp /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# install networking model
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version ${CILIUM_VERSION} --namespace kube-system

# install ingress
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx
kubectl patch svc ingress-nginx-controller -p "{\"spec\": {\"type\": \"LoadBalancer\", \"externalIPs\":[\"${VPS_IP}\"]}}"

# install certificate manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install \
  cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v${CERTMANAGER_VERSION} \
  --set installCRDs=true
