# SEE-Academy Project


# ------------ Define variables used for Authentication and Authorization for Terraform Provider ------------


variable "client_secret" {
  type = string
  default = ""
}

variable "client_id" {
  type = string
  default = ""
}

variable "tenant_id" {
  default = ""
}

variable "subscription_id" {
default = "d53beca8-7450-4196-a689-84cf17f3bfe3"

}

# ------------ Define variables of Resource Groups used in the Subscription ------------

variable "sme_netcore_oborlean_rg" {
  type    = string
  default = "sme_netcore_oborlean_rg"
}

variable "sme_aks_oborlean_rg" {
  type    = string
  default = "sme_aks_oborlean_rg"
}

variable "location" {
  type    = string
  default = "North Europe"
}

variable "hub_virtual_network" {
  type        = string
  description = "The HUB Vnet"
  default     = "sme_vnet_hub"
}

# --- Define the SPOKE Vnet
variable "aks_virtual_network" {
  type        = string
  description = "The SPOKE Vnet"
  default     = "sme_vnet_aks"
}

variable "fw_public_ip_name" {
  type    = string
  default = "management-fw01-pip"
}

#variable "aks_subnet_name" {
#  type    = string
#  default = "aksdefault"
#}

variable "aks_subnet_rt" {
  type    = string
  default = "aks-default-rt"
}

# ------------ Terraform Initialization and Main blocks ------------

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.8"
    }
    random = {
      source  = "hashicorp/random"
      version = "~>3.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  #client_id       = var.client_id
  #client_secret   = var.client_secret
  #tenant_id       = var.tenant_id
  #subscription_id = var.subscription_id

  
}

# ------------ Creating Resource Groups ------------

resource "azurerm_resource_group" "sme_netcore_oborlean_rg" {
  name     = var.sme_netcore_oborlean_rg
  location = var.location
}

resource "azurerm_resource_group" "sme_aks_oborlean_rg" {
  name     = var.sme_aks_oborlean_rg
  location = var.location
}

resource "azurerm_resource_group" "sme_core_oborlean_rg" {
  name     = "sme_core_oborlean_rg"
  location = var.location
}

# Create the NSG Rules to allow DNS queries.
resource "azurerm_network_security_group" "nsgdns" {
  name                = "nsgdns"
  location            = azurerm_resource_group.sme_netcore_oborlean_rg.location
  resource_group_name = azurerm_resource_group.sme_netcore_oborlean_rg.name

  security_rule {
    name                       = "AllowDNSRequestsUdp"
    priority                   = 500
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "53"
    source_address_prefix      = "*"
    destination_address_prefix = "10.10.1.10/32"
  }
  security_rule {
    name                       = "AllowDNSRequestsTcp"
    priority                   = 600
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "53"
    source_address_prefix      = "*"
    destination_address_prefix = "10.10.1.10/32"
  }
  security_rule {
    name                       = "AllowSSH"
    priority                   = 700
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "10.10.1.0/24"
  }
}

# ------------ Creating HUB Virtual Network and Subnets------------

resource "azurerm_virtual_network" "hubvnet" {
  name                = var.hub_virtual_network
  location            = azurerm_resource_group.sme_netcore_oborlean_rg.location
  resource_group_name = azurerm_resource_group.sme_netcore_oborlean_rg.name
  address_space       = ["10.10.0.0/16"]
  dns_servers         = ["168.63.129.16"]
} 

resource "azurerm_subnet" "sme_vnet_hub_subnet" {
  name                 = "sme_vnet_hub_subnet"
  virtual_network_name = azurerm_virtual_network.hubvnet.name
  resource_group_name  = azurerm_resource_group.sme_netcore_oborlean_rg.name
  address_prefixes = ["10.10.1.0/24"]
}

resource "azurerm_subnet" "AzureFirewallSubnet" {
  name                 = "AzureFirewallSubnet"
  virtual_network_name = azurerm_virtual_network.hubvnet.name
  resource_group_name  = azurerm_resource_group.sme_netcore_oborlean_rg.name
  address_prefixes = ["10.10.3.0/24"]
}

resource "azurerm_subnet" "AzureFirewallManagementSubnet" {
  name                 = "AzureFirewallManagementSubnet"
  virtual_network_name = azurerm_virtual_network.hubvnet.name
  resource_group_name  = azurerm_resource_group.sme_netcore_oborlean_rg.name
  address_prefixes = ["10.10.4.0/24"]
}

resource "azurerm_subnet" "AzureApplicationGateway" {
  name                 = "AzureApplicationGatewaySubnet"
  virtual_network_name = azurerm_virtual_network.hubvnet.name
  resource_group_name  = azurerm_resource_group.sme_netcore_oborlean_rg.name
  address_prefixes = ["10.10.2.0/24"]
}

resource "azurerm_subnet_network_security_group_association" "hub_subnet" {
  subnet_id                 = azurerm_subnet.sme_vnet_hub_subnet.id
  network_security_group_id = azurerm_network_security_group.nsgdns.id
  depends_on                = [azurerm_virtual_network.hubvnet,
                              azurerm_subnet.sme_vnet_hub_subnet
  ]
}

# To have the DNS Server available for the rest of resources

# ------------ Creating Virtual Machine with DNS Role ------------

resource "azurerm_network_interface" "dnsmain" {
  name                = "dnsnic"
  location            = azurerm_resource_group.sme_netcore_oborlean_rg.location
  resource_group_name = azurerm_resource_group.sme_netcore_oborlean_rg.name

  ip_configuration {
    name                          = "dnsboxconfiguration"
    subnet_id                     = azurerm_subnet.sme_vnet_hub_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.10.1.10"
  }
}

resource "azurerm_virtual_machine" "dnsvm" {
  name                  = "sme_oborlean_dns"
  location              = azurerm_resource_group.sme_netcore_oborlean_rg.location
  resource_group_name   = azurerm_resource_group.sme_netcore_oborlean_rg.name
  network_interface_ids = [azurerm_network_interface.dnsmain.id]
  vm_size               = "Standard_DS1_v2"

  delete_os_disk_on_termination = true
  delete_data_disks_on_termination = true

  storage_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
  storage_os_disk {
    name              = "myosdisk1"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }
  os_profile {
    computer_name  = "smeoborleandns"
    admin_username = "azureuser"
    admin_password = "P@ssw0rd123!"
  }
  os_profile_linux_config {
    disable_password_authentication = false
  }
  provisioner "local-exec" {
    command = "az vm run-command invoke -g sme_netcore_oborlean_rg -n sme_oborlean_dns --command-id RunShellScript --scripts 'sudo curl -o /tmp/dnsconfig.sh https://raw.githubusercontent.com/OvidiuBorlean/provision/main/dnsconfig.sh && sudo chmod +x /tmp/dnsconfig.sh && sudo bash /tmp/dnsconfig.sh'"  
  }
  tags = {
    environment = "jumpbox"
  }
  depends_on = [azurerm_network_interface.dnsmain]
}

# ------------ End of DNS VM deployment ------------

# ------------ Creating SPOKE Virtual Network and Subnets ------------

resource "azurerm_virtual_network" "sme_vnet_aks" {
  name                = var.aks_virtual_network
  location            = azurerm_resource_group.sme_aks_oborlean_rg.location
  resource_group_name = azurerm_resource_group.sme_aks_oborlean_rg.name
  address_space       = ["10.12.0.0/16"]
  dns_servers         = ["10.10.1.10"]
  depends_on          = [azurerm_virtual_machine.dnsvm]
}

resource "azurerm_subnet" "sme_vnet_aks_subnet_pods" {
  name                 = "sme_vnet_aks_subnet_pods"
  virtual_network_name = azurerm_virtual_network.sme_vnet_aks.name
  resource_group_name  = azurerm_resource_group.sme_aks_oborlean_rg.name
  address_prefixes = ["10.12.3.0/24"]
  depends_on = [azurerm_virtual_network.sme_vnet_aks, azurerm_virtual_machine.dnsvm]
}

resource "azurerm_subnet" "sme_vnet_aks_subnet_nodes" {
  name                 = "sme_vnet_aks_subnet_nodes"
  virtual_network_name = azurerm_virtual_network.sme_vnet_aks.name
  resource_group_name  = azurerm_resource_group.sme_aks_oborlean_rg.name
  address_prefixes = ["10.12.1.0/24"]
  depends_on = [azurerm_virtual_network.sme_vnet_aks]
}

# ------------ Implement the Virtual Network Peering ------------

resource "azurerm_virtual_network_peering" "sme_vnet_peering_hub" {
  name                      = "sme_vnet_peering"
  resource_group_name       = azurerm_resource_group.sme_netcore_oborlean_rg.name
  virtual_network_name      = azurerm_virtual_network.hubvnet.name
  remote_virtual_network_id = azurerm_virtual_network.sme_vnet_aks.id
}

resource "azurerm_virtual_network_peering" "sme_vnet_peering_spoke" {
  name                      = "sme_vnet_peering_spoke"
  resource_group_name       = azurerm_resource_group.sme_aks_oborlean_rg.name
  virtual_network_name      = azurerm_virtual_network.sme_vnet_aks.name
  remote_virtual_network_id = azurerm_virtual_network.hubvnet.id
}

# ------------ Create the Azure ------------

resource "azurerm_public_ip" "region1-fw01-pip" {
  name                = "region1-fw01-pip"
  resource_group_name = var.sme_netcore_oborlean_rg
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags = {
    Environment = "Production"
  }
  depends_on = [azurerm_resource_group.sme_netcore_oborlean_rg]
}

resource "azurerm_public_ip" "management-fw01-pip" {
  name                = var.fw_public_ip_name
  resource_group_name = var.sme_netcore_oborlean_rg
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  depends_on          = [azurerm_resource_group.sme_netcore_oborlean_rg]
}

resource "azurerm_firewall" "sme_oborlean_fw" {
  name                = "sme_oborlean_fw"
  location            = var.location
  resource_group_name = var.sme_netcore_oborlean_rg
  sku_tier            = "Basic"
  sku_name            = "AZFW_VNet"
  #management_ip_configuration = azurerm_public_ip.management-fw01-pip.name
  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = azurerm_subnet.AzureFirewallSubnet.id   #HERE
    public_ip_address_id = azurerm_public_ip.region1-fw01-pip.id
  }
  management_ip_configuration {
    name                 = "azfw_management_ip"
    subnet_id            = azurerm_subnet.AzureFirewallManagementSubnet.id
    public_ip_address_id = azurerm_public_ip.management-fw01-pip.id
  }
  firewall_policy_id = azurerm_firewall_policy.azfw_policy.id
}

# --- Azure Firewall Policy

resource "azurerm_firewall_policy" "azfw_policy" {
  name                     = "azfw-policy"
  resource_group_name      = azurerm_resource_group.sme_netcore_oborlean_rg.name
  location                 = azurerm_resource_group.sme_netcore_oborlean_rg.location
  sku                      = "Basic"
  threat_intelligence_mode = "Alert"
}

# --- Auzre Policies

resource "azurerm_firewall_policy_rule_collection_group" "prcg" {
  name               = "prcg"
  firewall_policy_id = azurerm_firewall_policy.azfw_policy.id
  priority           = 300
  network_rule_collection {
    name     = "netRc1"
    priority = 200
    action   = "Allow"
    rule {
      name                  = "allowall"
      protocols             = ["TCP"]
      source_addresses      = ["*"]
      destination_addresses = ["*"]
      destination_ports     = ["*"]
    }
  }
}

# ------------ End of Azure Firewall deployment ------------

# ------------ Define the Routing Table with a default route towards Private IP of Azure Firewall and associate with AKS Subnet ------------

resource "azurerm_route_table" "sme_oborlean_routetable" {
  name                          = "sme_oborlean_routetable"
  location                      = azurerm_resource_group.sme_aks_oborlean_rg.location
  resource_group_name           = azurerm_resource_group.sme_aks_oborlean_rg.name
  disable_bgp_route_propagation = false

  route {
    name                   = "default"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.sme_oborlean_fw.ip_configuration[0].private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "aks_subnet_association_nodes" {
  subnet_id      = azurerm_subnet.sme_vnet_aks_subnet_nodes.id
  route_table_id = azurerm_route_table.sme_oborlean_routetable.id
}

resource "azurerm_subnet_route_table_association" "aks_subnet_association_pods" {
  subnet_id      = azurerm_subnet.sme_vnet_aks_subnet_pods.id
  route_table_id = azurerm_route_table.sme_oborlean_routetable.id
}

# ------------ Define Azure Private DNS Zones and configures the links towards Vnets ------------

resource "azurerm_private_dns_zone" "azmk8s" {
  name                = "privatelink.northeurope.azmk8s.io"
  resource_group_name = azurerm_resource_group.sme_netcore_oborlean_rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "azmk8slink" {
  name                  = "azmkslink"
  resource_group_name   = azurerm_resource_group.sme_netcore_oborlean_rg.name
  private_dns_zone_name = azurerm_private_dns_zone.azmk8s.name
  virtual_network_id    = azurerm_virtual_network.sme_vnet_aks.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "azmk8slinkhub" {
  name                  = "azmkslinkhub"
  resource_group_name   = azurerm_resource_group.sme_netcore_oborlean_rg.name
  private_dns_zone_name = azurerm_private_dns_zone.azmk8s.name
  virtual_network_id    = azurerm_virtual_network.hubvnet.id
}

resource "azurerm_private_dns_zone" "acr_io" {
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.sme_netcore_oborlean_rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "acrlink" {
  name                  = "azmkslink"
  resource_group_name   = azurerm_resource_group.sme_netcore_oborlean_rg.name
  private_dns_zone_name = azurerm_private_dns_zone.acr_io.name
  virtual_network_id    = azurerm_virtual_network.hubvnet.id
}

# ------------ Create User Assigned Managed Identity for using in AKS and necessary roles assignments ------------

resource "azurerm_user_assigned_identity" "uami" {
  resource_group_name = azurerm_resource_group.sme_core_oborlean_rg.name
  location            = azurerm_resource_group.sme_core_oborlean_rg.location
  name = "sme_aks_oborlean_uami"
}

resource "azurerm_role_assignment" "sme_core_contributor" {
  scope                = azurerm_resource_group.sme_aks_oborlean_rg.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.uami.principal_id
}

resource "azurerm_role_assignment" "dnscontributor" {
  scope                = azurerm_private_dns_zone.azmk8s.id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.uami.principal_id
}

# ------------ Create AKS Cluster ------------

resource "azurerm_kubernetes_cluster" "sme_oborlean_aks" {
  name                = "sme_oborlean_aks"
  location            = azurerm_resource_group.sme_aks_oborlean_rg.location
  resource_group_name = azurerm_resource_group.sme_aks_oborlean_rg.name
  dns_prefix          = "sme"
  oidc_issuer_enabled       = true
  workload_identity_enabled = true
  private_cluster_enabled = true
  private_dns_zone_id     = azurerm_private_dns_zone.azmk8s.id
  azure_active_directory_role_based_access_control {
    managed             = true
    azure_rbac_enabled  = true
    admin_group_object_ids = ["fd61ff1a-d05d-488d-a363-a09121e3444e"]
  }   
  default_node_pool {
    name           = "system"
    node_count     = 1
    vm_size        = "Standard_DS2_v2"
    vnet_subnet_id = azurerm_subnet.sme_vnet_aks_subnet_nodes.id
    pod_subnet_id = azurerm_subnet.sme_vnet_aks_subnet_pods.id
  }
  network_profile {
    network_plugin    = "azure"
    load_balancer_sku = "standard"
    outbound_type     = "loadBalancer"
    service_cidr      = "10.13.1.0/24"
    dns_service_ip    = "10.13.1.10"
    
  }

  identity {
    type = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.uami.id]
  }
  depends_on = [azurerm_private_dns_zone_virtual_network_link.azmk8slink, 
                azurerm_private_dns_zone_virtual_network_link.azmk8slinkhub,
                azurerm_role_assignment.sme_core_contributor, 
                azurerm_private_dns_zone.azmk8s, 
                azurerm_firewall.sme_oborlean_fw, 
                azurerm_role_assignment.dnscontributor, 
                azurerm_route_table.sme_oborlean_routetable, 
                azurerm_subnet_route_table_association.aks_subnet_association_nodes,
                azurerm_subnet_route_table_association.aks_subnet_association_pods, 
                azurerm_user_assigned_identity.uami, 
                azurerm_virtual_network_peering.sme_vnet_peering_hub,
                azurerm_virtual_network_peering.sme_vnet_peering_spoke,
                azurerm_virtual_machine.dnsvm
                ]
  }

resource "azurerm_kubernetes_cluster_node_pool" "sme_oborlean_aks" {
  name                  = "userpool"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.sme_oborlean_aks.id
  vm_size               = "Standard_DS2_v2"
  node_count            = 2
  pod_subnet_id = azurerm_subnet.sme_vnet_aks_subnet_pods.id
  tags = {
   Environment = "Production"
  }
  depends_on  = [azurerm_kubernetes_cluster.sme_oborlean_aks]
}

# ------------ Create Azure Container Registry ------------

resource "azurerm_container_registry" "acr" {
  name                = "oborleanacr"
  resource_group_name = azurerm_resource_group.sme_core_oborlean_rg.name
  location            = azurerm_resource_group.sme_core_oborlean_rg.location
  sku                 = "Premium"
  admin_enabled       = false
}

resource "azurerm_role_assignment" "aks_acr_integration" {
  principal_id                     = azurerm_kubernetes_cluster.sme_oborlean_aks.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.acr.id
  skip_service_principal_aad_check = true
}

resource "azurerm_private_endpoint" "acr_private_endpoint" {
  name                = "acr_private_endpoint"
  location            = var.location
  resource_group_name = azurerm_resource_group.sme_core_oborlean_rg.name
  subnet_id           = azurerm_subnet.sme_vnet_hub_subnet.id

  private_service_connection {
    name                           = "acr"
    private_connection_resource_id = azurerm_container_registry.acr.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }
  private_dns_zone_group {
    name                 = "acr_io"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr_io.id]
  }
  depends_on            = [azurerm_subnet.sme_vnet_hub_subnet,
                           azurerm_container_registry.acr,
                           azurerm_private_dns_zone.acr_io


  ]
}

# ------------ Create Jumpbox Virtual Machine ------------

resource "azurerm_public_ip" "jumpbox_pip" {
  name                = "jumpbox-pip"
  resource_group_name = "sme_core_oborlean_rg"
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  depends_on          = [azurerm_resource_group.sme_core_oborlean_rg]
}

resource "azurerm_network_interface" "main" {
  name                = "jumpboxnic"
  location            = azurerm_resource_group.sme_core_oborlean_rg.location
  resource_group_name = azurerm_resource_group.sme_core_oborlean_rg.name

  ip_configuration {
    name                          = "jumpboxconfiguration"
    subnet_id                     = azurerm_subnet.sme_vnet_hub_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jumpbox_pip.id
  }
  depends_on          = [azurerm_resource_group.sme_core_oborlean_rg]
}

resource "azurerm_virtual_machine" "jumpbox" {
  name                  = "smeoborleanjumpbox"
  location              = azurerm_resource_group.sme_core_oborlean_rg.location
  resource_group_name   = azurerm_resource_group.sme_core_oborlean_rg.name
  network_interface_ids = [azurerm_network_interface.main.id]
  vm_size               = "Standard_DS1_v2"

  delete_os_disk_on_termination = true
  delete_data_disks_on_termination = true

  storage_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
  storage_os_disk {
    name              = "myosdisk1"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }
  os_profile {
    computer_name  = "smeoborleanjumpbox"
    admin_username = "azureuser"
    admin_password = "P@ssw0rd123!!"
  }
  os_profile_linux_config {
    disable_password_authentication = false
  }
  tags = {
    environment = "jumpbox"
  }
  depends_on = [azurerm_public_ip.jumpbox_pip, azurerm_resource_group.sme_core_oborlean_rg]
}

# ------------ End of Jumpbox Virtual Machine deployment ------------
