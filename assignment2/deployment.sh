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
}


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



function agicDeployment {

az network public-ip create -n agicPublicIP -g $RESOURCE_GROUP_NAME --allocation-method Static --sku Standard
az network vnet create -n agicVnet -g $RESOURCE_GROUP_NAME --address-prefix 10.0.0.0/16 --subnet-name agicSubnet --subnet-prefix 10.0.0.0/24 
az network application-gateway create -n storeGateway -g $RESOURCE_GROUP_NAME --sku Standard_v2 --public-ip-address agicPublicIP --vnet-name agicVnet --subnet agicSubnet --priority 100

appgwId="$(az network application-gateway show -n storeGateway -g $RESOURCE_GROUP_NAME -o tsv --query 'id')" 
az aks enable-addons -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP_NAME -a ingress-appgw --appgw-id $appgwId

nodeResourceGroup="$(az aks show -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP_NAME -o tsv --query 'nodeResourceGroup')"
echo $nodeResourceGroup

aksVnetName="$(az network vnet list -g $nodeResourceGroup -o tsv --query '[0].name')"
echo $aksVnetName

aksVnetId="$(az network vnet show -n $aksVnetName -g $nodeResourceGroup -o tsv --query 'id')"

az network vnet peering create -n AppGWtoAKSVnetPeering -g $RESOURCE_GROUP_NAME --vnet-name agicVnet --remote-vnet $aksVnetId --allow-vnet-access

appGWVnetId="$(az network vnet show -n agicVnet -g $RESOURCE_GROUP_NAME -o tsv --query 'id')"
az network vnet peering create -n AKStoAppGWVnetPeering -g $nodeResourceGroup --vnet-name $aksVnetName --remote-vnet $appGWVnetId --allow-vnet-access

kubectl patch svc store-front -n prod -p '{"spec": {"type": "ClusterIP"}}'

echo "Creating Ingress Object for Prod"

cat << EOF > ./ingress-prod.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: storefront-prod
  namespace: prod
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway      
spec:
  rules:
  - http:
      paths:
        - path: /
          pathType: Prefix
          backend:
            service:
              name: store-front
              port:
                number: 80
EOF

kubectl apply -f ./ingress-prod.yaml


}


function nginxDeployment {

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-dev ingress-nginx/ingress-nginx \
    --namespace dev \
    --set controller.replicaCount=2 \
    --set controller.nodeSelector."kubernetes\.io/os"=linux \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-internal"=true \
    --set controller.ingressClassResource.name=ingressdev

echo "Changing Store Front Dev service from Load Balancer to ClusterIP in order to be used as a Ingress Backend service"
kubectl patch svc store-front -n prod -p '{"spec": {"type": "ClusterIP"}}'

echo "Creating Ingress Object for Dev"

cat << EOF > ./ingress-dev.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: storefront-dev
  namespace: dev
spec:
  ingressClass: ingressdev
  rules:
  - http:
      paths:
        - path: /
          pathType: Prefix
          backend:
            service:
              name: store-front
              port:
                number: 80
EOF

kubectl apply -f ./ingress-dev.yaml


}

function taintsAndToleration {

az aks nodepool add --cluster-name $AKS_CLUSTER_NAME -g $RESOURCE_GROUP_NAME --name devpool --node-count 1 --labels=env=dev --node-taints env=dev:NoSchedule

kubectl patch deploy store-front -n dev --patch '{"spec": {"template": { "spec": {"tolerations": [{"key": "env", "operator": "Equal", "value": "dev", "effect": "NoSchedule"}]}}}}'
kubectl patch deploy order-service -n dev --patch '{"spec": {"template": { "spec": {"tolerations": [{"key": "env", "operator": "Equal", "value": "dev", "effect": "NoSchedule"}]}}}}'
kubectl patch deploy product-service -n dev --patch '{"spec": {"template": { "spec": {"tolerations": [{"key": "env", "operator": "Equal", "value": "dev", "effect": "NoSchedule"}]}}}}'
kubectl rollout restart deployment store-front -n dev
kubectl rollout restart deployment order-service -n dev
kubectl rollout restart deployment product-service -n dev


az aks nodepool add --cluster-name $AKS_CLUSTER_NAME -g $RESOURCE_GROUP_NAME --name prodpool --node-count 1 --labels=env=prod --node-taints env=prod:NoSchedule

kubectl patch deploy store-front -n prod --patch '{"spec": {"template": { "spec": {"tolerations": [{"key": "env", "operator": "Equal", "value": "prod", "effect": "NoSchedule"}]}}>'
kubectl patch deploy order-service -n dev --patch '{"spec": {"template": { "spec": {"tolerations": [{"key": "env", "operator": "Equal", "value": "prod", "effect": "NoSchedule"}]>'
kubectl patch deploy product-service -n dev --patch '{"spec": {"template": { "spec": {"tolerations": [{"key": "env", "operator": "Equal", "value": "prod", "effect": "NoSchedule">'
kubectl rollout restart deployment store-front -n prod
kubectl rollout restart deployment order-service -n prod
kubectl rollout restart deployment product-service -n prod


}

function azureFileShare {

export STORAGE_RESOURCE_GROUP="SEE-Academy-HW2"
export STORAGE_ACCOUNT_NAME="seeacademyfileshare"
export FILE_SHARE_NAME="oborleanfileshare"

az group create -n $STORAGE_RESOURCE_GROUP --location eastus
az storage account create -n STORAGE_ACCOUNT_NAME -g $STORAGE_RESOURCE_GROUP -l EastUS --sku Standard_LRS
export AZURE_STORAGE_CONNECTION_STRING=$(az storage account show-connection-string -n $STORAGE_ACCOUNT_NAME -g $STORAGE_RESOURCE_GROUP -o tsv)
az storage share create -n $FILE_SHARE_NAME --connection-string $AZURE_STORAGE_CONNECTION_STRING
STORAGE_KEY=$(az storage account keys list --resource-group $STORAGE_RESOURCE_GROUP --account-name $STORAGE_ACCOUNT_NAME --query "[0].value" -o tsv)
echo Storage account key: $STORAGE_KEY

kubectl create secret generic azure-secret --from-literal=azurestorageaccountname=$STORAGE_ACCOUNT_NAME --from-literal=azurestorageaccountkey=$STORAGE_KEY

echo "Generate Storage Account Config Files"
cat << EOF > ./azurefiles.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  annotations:
    pv.kubernetes.io/provisioned-by: file.csi.azure.com
  name: azurefile
spec:
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: azurefile-csi
  csi:
    driver: file.csi.azure.com
    volumeHandle: unique-volumeid  # make sure this volumeid is unique for every identical share in the cluster
    volumeAttributes:
      resourceGroup: $STORAGE_RESOURCE_GROUP
      shareName: $FILE_SHARE_NAME
    nodeStageSecretRef:
      name: azure-secret
      namespace: default
  mountOptions:
    - dir_mode=0777
    - file_mode=0777
    - uid=0
    - gid=0
    - mfsymlinks
    - cache=strict
    - nosharesock
    - nobrl
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: azurefile
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azurefile-csi
  volumeName: azurefile
  resources:
    requests:
      storage: 5Gi
---       
apiVersion: v1
kind: Pod
metadata:
  name: mypod2
spec:
  nodeSelector:
    kubernetes.io/os: linux
  containers:
    - image: 'mcr.microsoft.com/oss/nginx/nginx:1.15.5-alpine'
      name: mypod
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: 250m
          memory: 256Mi
      volumeMounts:
        - name: azure
          mountPath: /mnt/azure
          readOnly: false
  volumes:
    - name: azure
      csi:
        driver: file.csi.azure.com
        volumeAttributes:
          secretName: azure-secret  # required
          shareName: $FILE_SHARE_NAME
          mountOptions: 'dir_mode=0777,file_mode=0777,cache=strict,actimeo=30,nosharesock'  # optional
EOF

}

function secretStore {

echo "Enable KeyVault AddOn"
#az aks enable-addons --addons azure-keyvault-secrets-provider --name $AKS_CLUSTER_NAME --resource-group $RESOURCE_GROUP_NAME
#az keyvault create -n smeoborlean -g $RESOURCE_GROUP_NAME -l eastus --enable-rbac-authorization

#az keyvault secret set --vault-name smeoborlean -n username --value username
#az keyvault secret set --vault-name smeoborlean -n password --value password
AKS_UAMI="$(az aks show -g $RESOURCE_GROUP_NAME -n $AKS_CLUSTER_NAME --query addonProfiles.azureKeyvaultSecretsProvider.identity.objectId -o tsv)"
NODE_RESOURCE_GROUP="$(az aks show -n aks -g aks -o tsv --query nodeResourceGroup)"
IDENTITY_OBJECT_ID="$(az identity show -g $NODE_RESOURCE_GROUP --name $AKS_UAMI --query 'principalId' -o tsv)"
KEYVAULT_SCOPE="$(az keyvault show --name smeoborlean --query id -o tsv)"



az role assignment create --role "Key Vault Administrator" --assignee $IDENTITY_OBJECT_ID --scope $KEYVAULT_SCOPE

cat << EOF > ./spclass.yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: smeoborlean
spec:
  provider: azure
  secretObjects:
  - secretName: secretusername
    type: Opaque
    data:
     - objectName: username
       key: username
  - secretName: secretpassword
    type: Opaque
    data:
     - objectName: password
       key: password
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "true"          # Set to true for using managed identity
    userAssignedIdentityID: 20b28714-0358-4194-9d4d-21dc33ab725c
    keyvaultName: smeoborlean
    cloudName: ""                         # [OPTIONAL for Azure] if not provided, the Azure environment defaults to AzurePublicCloud
    objects:  |
      array:
        - |
          objectName: username
          objectType: secret              # object types: secret, key, or cert
          objectVersion: ""
        - |
          objectName: password
          objectType: secret
          objectVersion: ""
    tenantId: "72f988bf-86f1-41af-91ab-2d7cd011db47"                 # The tenant ID of the key vault
---
kind: Pod
apiVersion: v1
metadata:
  name: spclass6
spec:
  containers:
    - name: busybox
      image: registry.k8s.io/e2e-test-images/busybox:1.29-1
      command:
        - "/bin/sleep"
        - "10000"
      volumeMounts:
      - name: secrets-store01-inline
        mountPath: "/mnt/secrets-store"
        readOnly: true
      env:
      - name: RABBITMQ_DEFAULT_USER
        valueFrom:
          secretKeyRef:
            name: secretusername
            key: username
      - name: RABBITMQ_DEFAULT_PASS
        valueFrom:
          secretKeyRef: 
            name: secretpassword
            key: password
  volumes:
    - name: secrets-store01-inline
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: "smeoborlean"
EOF

kubectl apply -f ./spclass.yaml

}


function serviceaccount {
echo "---> Creating Service Account"

kubectl create sa dev-team-sa

kubectl create clusterrole dev --verb=* --resource=*
kubectl create clusterrole prod --verb=get,list,watch --resource=pod,deployments

kubectl create clusterrolebinding dev --clusterrole=dev --serviceaccount=dev:dev-team-sa
kubectl create clusterrolebinding dev --clusterrole=dev --serviceaccount=dev-rmq:dev-team-sa

kubectl create clusterrolebinding prod --clusterrole=prod --serviceaccount=prod:dev-team-sa
kubectl create clusterrolebinding prod --clusterrole=prod --serviceaccount=prod-rmq:dev-team-sa

echo "Done"
}

case $1 in
  create)
    echo "Creating AKS Cluster"
    #createAKS
    #k8sWorkload
    ;;
  delete)
    echo "Deleting AKS Cluster"
    #az aks delete -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP_NAME -y
    #az group delete -n $RESOURCE_GROUP_NAME -y
    ;;
  agic)
    echo "Deploy AGIC"
    #agicDeployment
    ;;
  nginx)
    echo "Deploy NGINX Ingress Controller"
    #nginxDeployment
    ;;
  secret)
    echo "Deploy Secret Store"
    secretStore
    ;;
  *)
    echo -n "unknown"
    ;;
esac
