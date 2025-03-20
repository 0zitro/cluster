#!/usr/bin/env bash

VPS_IP=$(curl -4 ifconfig.co)
K8S_VERSION="1.31"
CILIUM_VERSION="1.17.2"
CERTMANAGER_VERSION="1.17.1"

# General repo utils
apt-get update
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade
# apt-transport-https may be a dummy package; if so, you can skip that package
apt-get install -y apt-transport-https ca-certificates curl gpg

# Keyrings:
# If the directory `/etc/apt/keyrings` does not exist, it should be created before the curl command, read the note below.
sudo mkdir -p -m 755 /etc/apt/keyrings

#  - Docker:
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
#  - Kubernetes:
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring_v${K8S_VERSION}.gpg
#  - Helm:
curl https://baltocdn.com/helm/signing.asc | gpg --dearmor -o /usr/share/keyrings/helm.gpg
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
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" > /etc/apt/sources.list.d/helm-stable-debian.list

# use systemd for the management of the container’s cgroups
mkdir /etc/docker
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
apt-get update
apt install docker-ce kubeadm kubelet kubernetes-cni helm -y
apt-mark hold kubelet kubeadm kubectl

# start cluster
kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=$VPS_IP

# setup kubectl
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# install networking model
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version ${CILIUM_VERSION} --namespace kube-system

# allow master to run pods
kubectl taint nodes --all node-role.kubernetes.io/master-

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
