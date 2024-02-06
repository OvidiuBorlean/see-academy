#!/bin/bash

# Deploy AKS Cluster

RESOURCE_GROUP_NAME="homework"
AKS_CLUSTER_NAME="akswork"
REGION="NorthEurope"



function createAKS {
  az group create -n $RESOURCE_GROUP_NAME --location $REGION
  az aks create -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP_NAME --network-plugin azure \
  --network-policy azure --enable-cluster-autoscaler --max-count 3 --min-count 1 \
  --generate-ssh-keys --enable-oidc-issuer --enable-workload-identity \
  --node-vm-size Standard_D2s_v3
}

function k8sWorkload {
   echo "Getting AKS cluster credentials"
   az aks get-credentials -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP_NAME
   kubectl create namespace dev
   kubectl create namespace dev-rmq
   kubectl create namespace prod
   kubectl create namespace prod-rmq
   echo "Download deployment files"
   curl -v https://seeacademyhw2.blob.core.windows.net/aks-store-demo-hw2/aks-store-demo-hw2.yaml -o aks-store-demo-hw2.yaml
   echo "Splitting applications"
   sed -n '1,72 p' ./aks-store-demo-hw2.yaml > rabbitmq.yaml
   sed -n '74,286 p' ./aks-store-demo-hw2.yaml > application.yaml  
   # Prod
   kubectl apply -f ./rabbitmq.yaml -n prod-rmq
   sed -i "66s/.*/        command: ['sh', '-c', 'until nc -zv rabbitmq.prod-rmq.svc.cluster.local 5672; do echo waiting for rabbitmq; sleep 2; done;']/" ./application.yaml
   kubectl apply -f /application.yaml -n prod
   # Dev
   kubectl apply -f ./rabbitmq.yaml -n dev-rmq
   sed -i "66s/.*/        command: ['sh', '-c', 'until nc -zv rabbitmq.dev-rmq.svc.cluster.local 5672; do echo waiting for rabbitmq; sleep 2; done;']/" ./application.yaml
   kubectl apply -f ./application.yaml -n dev

   #kubectl apply -f ./aks-store-demo-hw2.yaml -n prod


}



case $1 in
  create)
    echo "Creating AKS Cluster"
    createAKS
    k8sWorkload
  ;;
  delete)
    echo "Deleting AKS Cluster"
    az aks delete -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP_NAME
    az group delete -n $RESOURCE_GROUP_NAME
    ;;
  *)
    echo "Hello, $2!"
    ;;
esac
