#!/bin/bash

# Deploy AKS Cluster

RESOURCE_GROUP_NAME="homework"
AKS_CLUSTER_NAME="akswork"
REGION="NorthEurope"
AAD_ADMIN="fd61ff1a-d05d-488d-a363-a09121e3444e"


function createAKS {
  az group create -n $RESOURCE_GROUP_NAME --location $REGION
  az aks create -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP_NAME --network-plugin azure \
  --network-policy azure --enable-cluster-autoscaler --max-count 3 --min-count 1 \
  --generate-ssh-keys --enable-oidc-issuer --enable-workload-identity \
  --node-vm-size Standard_D2s_v3 --enable-aad --aad-admin-group-object-ids $AAD_ADMIN  -y
}

function k8sWorkload {
   echo "---> Getting AKS cluster credentials"
   az aks get-credentials -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP_NAME --overwrite
   kubectl create namespace dev
   kubectl create namespace dev-rmq
   kubectl create namespace prod
   kubectl create namespace prod-rmq
   echo "---> Download deployment files"
   curl -v https://seeacademyhw2.blob.core.windows.net/aks-store-demo-hw2/aks-store-demo-hw2.yaml -o aks-store-demo-hw2.yaml
   echo "---> Splitting applications"
   sed -n '1,72 p' ./aks-store-demo-hw2.yaml > ./rabbitmq.yaml
   sed -n '74,286 p' ./aks-store-demo-hw2.yaml > ./application.yaml  
   # Prod
   echo "---> Deploy Application on Prod RabbitMQ"
   kubectl apply -f ./rabbitmq.yaml -n prod-rmq
   echo "---> Changing the configuration"
   sed -i "66s/.*/        command: ['sh', '-c', 'until nc -zv rabbitmq.prod-rmq.svc.cluster.local 5672; do echo waiting for rabbitmq; sleep 2; done;']/" ./application.yaml
   sed -i -e 's/1m/150m/g' ./application.yaml
   sed -i -e 's/75m/275m/g' ./application.yaml
   sed -i -e 's/2m/250m/g' ./application.yaml
   
   echo "---> Deploy Application on Prod"
   kubectl apply -f /application.yaml -n prod
   # Dev
   echo "---> Deploy RabbitMq Application in Dev RabbitMQ"
   kubectl apply -f ./rabbitmq.yaml -n dev-rmq
   sed -i "66s/.*/        command: ['sh', '-c', 'until nc -zv rabbitmq.dev-rmq.svc.cluster.local 5672; do echo waiting for rabbitmq; sleep 2; done;']/" ./application.yaml
   echo "---> Deploy Application in Dev"
   kubectl apply -f ./application.yaml -n dev

   #kubectl apply -f ./aks-store-demo-hw2.yaml -n prod
}

function netPolicy {

cat << EOF > ./default-deny.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes:
  - Ingress
}
EOF

kubectl apply -f ./default-deny.yaml -n prod
kubectl apply -f ./default-deny.yaml -n prod-rmq

kubectl apply -f ./default-deny.yaml -n dev
kubectl apply -f ./default-deny.yaml -n dev-rmq

cat << EOF > ./netpol-dev-rmq.yaml
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: no-inbound-traffic
  namespace: dev-rmq
spec:
  policyTypes:
  - Ingress
  podSelector:
    matchLabels:
      app: rabbitmq
  ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: dev
      - podSelector:      
          matchLabels:
            app: order-service  
EOF

kubectl apply -f ./netpol-dev-rmq.yaml -n dev-rmq

cat << EOF > ./netpol-prod-rmq.yaml
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: no-inbound-traffic
  namespace: prod-rmq
spec:
  policyTypes:
  - Ingress
  podSelector:
    matchLabels:
      app: rabbitmq
  ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: prod
      - podSelector:      
          matchLabels:
            app: order-service      
EOF

kubectl apply -f ./netpol-prod-rmq.yaml

function configHPA {
  
cat << EOF > ./store-front-hpa.yaml
apiVersion: autoscaling/v1
kind: HorizontalPodAutoscaler
metadata:
  creationTimestamp: null
  name: store-front
spec:
  maxReplicas: 50
  minReplicas: 2
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: store-front
  targetCPUUtilizationPercentage: 50
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 15
      policies: 
      - type: Pods
        value: 4
        periodSeconds: 5 
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 20 
        periodSeconds: 20  
EOF

kubectl apply -f ./store-fron-hpa.yaml -n dev
kubectl apply -f ./store-fron-hpa.yaml -n prod

}



case $1 in
  create)
    echo "Creating AKS Cluster"
    createAKS
    k8sWorkload
  ;;
  delete)
    echo "Deleting AKS Cluster"
    az aks delete -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP_NAME -y
    az group delete -n $RESOURCE_GROUP_NAME -y
    ;;
  *)
    echo "Hello, $2!"
    ;;
esac
