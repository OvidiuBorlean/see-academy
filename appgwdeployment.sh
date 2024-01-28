#/bin/bash

RESOURCE_GROUP_NAME="sme_netcore_oborlean_rg"
APPLICATION_GATEWAY_NAME="smeoborleanappgw"
APPLICATION_GATEWAY_PUBLICIP="appgwfrontendIP"
USER_ASSIGNED_IDENTITY_NAME="appgwuami"
FEDERATED_IDENTITY_CREDENTIAL_NAME="aksfederated"
VNET_NAME="sme_vnet_hub"
APPLICATION_GATEWAY_SUBNET_NAME="AzureApplicationGatewaySubnet"
AKS_RESOURCE_GROUP_NAME="sme_aks_oborlean_rg"

# Creating Public IP address that will be defines as the Frontend IP of the Application Gateway
az network public-ip create -g "${RESOURCE_GROUP_NAME}" -n "${APPLICATION_GATEWAY_PUBLICIP}" --allocation-method Static --sku Standard --tier Regional

# Creating Azure Application Gateway resource
az network application-gateway create -g "${RESOURCE_GROUP_NAME}" -n "${APPLICATION_GATEWAY_NAME}" --sku Standard_v2 --public-ip-address "${APPLICATION_GATEWAY_PUBLICIP}" --vnet-name "${VNET_NAME}" --subnet "${APPLICATION_GATEWAY_SUBNET_NAME}" --priority 105

# Create the User Assigned Identity that will be used by AGIC pods to modify the configuration of Application Gateway
az identity create --name "${USER_ASSIGNED_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" 

export USER_ASSIGNED_IDENTITY_CLIENT_ID="$(az identity show --resource-group "${RESOURCE_GROUP_NAME}" --name "${USER_ASSIGNED_IDENTITY_NAME}" --query 'clientId' -otsv)"

echo $USER_ASSIGNED_IDENTITY_CLIENT_ID 
echo "User Assigned Identity:  $USER_ASSIGNED_IDENTITY_CLIENT_ID" >> deployment.report

export AKS_OIDC_ISSUER="$(az aks show -n sme_oborlean_aks -g sme_aks_oborlean_rg --query "oidcIssuerProfile.issuerUrl" -otsv)"
echo $AKS_OIDC_ISSUER

# Create the Federated Identity for the Default namespace where the Azure-Ingress Pods will run
az identity federated-credential create --resource-group ${RESOURCE_GROUP_NAME} --name ${FEDERATED_IDENTITY_CREDENTIAL_NAME} --identity-name ${USER_ASSIGNED_IDENTITY_NAME} --issuer ${AKS_OIDC_ISSUER} --subject system:serviceaccount:default:ingress-azure

export APPLICATION_GATEWAY_RESOURCE_ID="$(az network application-gateway show --name "${APPLICATION_GATEWAY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" --query 'id' --output tsv)"
echo $APPLICATION_GATEWAY_RESOURCE_ID
echo "Application Gateway Resource Id: $APPLICATION_GATEWAY_RESOURCE_ID" >> deployment.report

# Create the necesary roles for our Identity. DO not forget the Role for Hub Vnet
az role assignment create --assignee "${USER_ASSIGNED_IDENTITY_CLIENT_ID}" --scope "${APPLICATION_GATEWAY_RESOURCE_ID}" --role Contributor
#export VIRTUAL_NETWORK_RESOURCE_ID="$(az network vnet show --name "${VNET_NAME}" --resource-group "${AKS_RESOURCE_GROUP_NAME}" --query 'id' --output tsv)"

# Adding Contributor role to Resource Group of AKS
az role assignment create --assignee "${USER_ASSIGNED_IDENTITY_CLIENT_ID}" --scope /subscriptions/d53beca8-7450-4196-a689-84cf17f3bfe3/resourceGroups/sme_aks_oborlean_rg --role Contributor

export APPLICATION_GATEWAY_PUBLICIP_RESOURCE_ID="$(az network public-ip show --name "${APPLICATION_GATEWAY_PUBLICIP}" --resource-group "${RESOURCE_GROUP_NAME}" --query 'id' --output tsv)"
az role assignment create --assignee c1ec9750-fb6b-439c-9fc4-e400969aa8f5 --scope /subscriptions/d53beca8-7450-4196-a689-84cf17f3bfe3/resourceGroups/sme_aks_oborlean_rg/providers/Microsoft.Network/virtualNetworks/sme_vnet_aks --role Contributor

export subscriptionId="$(az account list --query "[?isDefault].id" -o tsv)"
echo "Subscription Id: $subscriptionId" >> deployment.report

#echo $RESOURCE_GROUP_NAME
#echo $APPLICATION_GATEWAY_NAME

export USER_ASSIGNED_IDENTITY_CLIENT_ID="$(az identity show --resource-group "${RESOURCE_GROUP_NAME}" --name "${USER_ASSIGNED_IDENTITY_NAME}" --query 'clientId' -otsv)"
echo $USER_ASSIGNED_IDENTITY_CLIENT_ID

# Generate the custom helm-config.yaml
cat << EOF > ./helm-config.yaml
# This file contains the essential configs for the ingress controller helm chart

# Verbosity level of the App Gateway Ingress Controller
verbosityLevel: 3

################################################################################
# Specify which application gateway the ingress controller will manage
#
appgw:
    subscriptionId: $subscriptionId
    resourceGroup: $RESOURCE_GROUP_NAME
    name: $APPLICATION_GATEWAY_NAME
    usePrivateIP: false

    # Setting appgw.shared to "true" will create an AzureIngressProhibitedTarget CRD.
    # This prohibits AGIC from applying config for any host/path.
    # Use "kubectl get AzureIngressProhibitedTargets" to view and change this.
    shared: false

################################################################################
# Specify which kubernetes namespace the ingress controller will watch
# Default value is "default"
# Leaving this variable out or setting it to blank or empty string would
# result in Ingress Controller observing all acessible namespaces.
#
# kubernetes:
#   watchNamespace: <namespace>

################################################################################
# Specify the authentication with Azure Resource Manager
#
# Two authentication methods are available:
# - Option 1: AAD-Pod-Identity (https://github.com/Azure/aad-pod-identity)
armAuth:
    type: workloadIdentity
    identityClientID: $USER_ASSIGNED_IDENTITY_CLIENT_ID

## Alternatively you can use Service Principal credentials
# armAuth:
#    type: servicePrincipal
#    secretJSON: <<Generate this value with: "az ad sp create-for-rbac --subscription <subscription-uuid> --sdk-auth | base64 -w0" >>

################################################################################
# Specify if the cluster is RBAC enabled or not
rbac:
    enabled: true 
EOF

helm install ingress-azure -f helm-config.yaml application-gateway-kubernetes-ingress/ingress-azure 
