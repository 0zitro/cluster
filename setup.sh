#!/bin/sh

VPS_IP=$(curl -4 ifconfig.co)

# update the system
apt-get update
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade

# add Docker repository
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

# add Kubernetes repository
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" | tee -a /etc/apt/sources.list.d/kubernetes.list

# add Helm repository
curl https://baltocdn.com/helm/signing.asc | apt-key add -
echo "deb https://baltocdn.com/helm/stable/debian/ all main" | tee /etc/apt/sources.list.d/helm-stable-debian.list

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

# start cluster
kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=$VPS_IP

# setup kubectl
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# install networking model
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version 1.10.4 --namespace kube-system

# allow master to run pods
kubectl taint nodes --all node-role.kubernetes.io/master-

# install ingress
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx
kubectl patch svc ingress-nginx-controller -p "{\"spec\": {\"type\": \"LoadBalancer\", \"externalIPs\":[\"$VPS_IP\"]}}"

# install certificate manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install \
  cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.5.3 \
  --set installCRDs=true
