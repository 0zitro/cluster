# Install the cluster

```sh
curl -L https://raw.githubusercontent.com/0zitro/cluster/main/setup.sh | sh
```

# Deploy a simple app over an HTTPS endpoint

```sh
kubectl create --edit -f https://raw.githubusercontent.com/0zitro/cluster/main/letsencrypt-issuer.yaml
# edit your email address

kubectl create -f https://raw.githubusercontent.com/0zitro/cluster/main/hello-service.yaml

kubectl create --edit -f https://raw.githubusercontent.com/0zitro/cluster/main/nginx-ingress.yaml
# edit your subdomain
```
