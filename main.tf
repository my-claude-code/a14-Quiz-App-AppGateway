terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  prefix         = "quiz-app"
  app_private_ip = "10.0.1.10"
}

data "azurerm_client_config" "current" {}

# ── Key Vault ─────────────────────────────────────────────────────────────────
data "azurerm_key_vault" "kv" {
  name                = "vault-test-subscription"
  resource_group_name = "Vault_RG"
}

data "azurerm_key_vault_secret" "entra_tenant_id" {
  name         = "quiz-entra-tenant-id"
  key_vault_id = data.azurerm_key_vault.kv.id
}

data "azurerm_key_vault_secret" "entra_client_id" {
  name         = "quiz-entra-client-id"
  key_vault_id = data.azurerm_key_vault.kv.id
}

data "azurerm_key_vault_secret" "entra_client_secret" {
  name         = "quiz-entra-client-secret"
  key_vault_id = data.azurerm_key_vault.kv.id
}

data "azurerm_key_vault_secret" "admin_password" {
  name         = "quiz-admin-password"
  key_vault_id = data.azurerm_key_vault.kv.id
}

data "azurerm_key_vault_secret" "flask_secret_key" {
  name         = "quiz-flask-secret-key"
  key_vault_id = data.azurerm_key_vault.kv.id
}

data "azurerm_key_vault_secret" "db_password" {
  name         = "quiz-db-password"
  key_vault_id = data.azurerm_key_vault.kv.id
}

data "azurerm_key_vault_certificate" "tls" {
  name         = "quiz-agw-tls"
  key_vault_id = data.azurerm_key_vault.kv.id
}

# ── Resource Group ────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.prefix}"
  location = var.location
}

# ── Virtual Network ───────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${local.prefix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "app" {
  name                 = "subnet-app"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "postgres" {
  name                 = "subnet-postgres"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]

  delegation {
    name = "postgres-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "agw" {
  name                 = "subnet-agw"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.3.0/24"]
}

# ── NSG for VM ────────────────────────────────────────────────────────────────
resource "azurerm_network_security_group" "vm" {
  name                = "nsg-vm"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-http-from-agw"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "10.0.3.0/24"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "app" {
  network_interface_id      = azurerm_network_interface.app.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

# ── NSG for App Gateway ───────────────────────────────────────────────────────
resource "azurerm_network_security_group" "agw" {
  name                = "nsg-agw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "allow-http"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-https"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-agw-management"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "agw" {
  subnet_id                 = azurerm_subnet.agw.id
  network_security_group_id = azurerm_network_security_group.agw.id
}

# ── Public IPs ────────────────────────────────────────────────────────────────
resource "azurerm_public_ip" "agw" {
  name                = "pip-agw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "vm" {
  name                = "pip-vm"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ── NIC ───────────────────────────────────────────────────────────────────────
resource "azurerm_network_interface" "app" {
  name                = "nic-app"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig-app"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.app_private_ip
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

# ── Private DNS Zone for PostgreSQL ──────────────────────────────────────────
resource "azurerm_private_dns_zone" "postgres" {
  name                = "quizapp.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "postgres-dns-link"
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  resource_group_name   = azurerm_resource_group.rg.name
  registration_enabled  = false

  depends_on = [
    azurerm_virtual_network.vnet,
    azurerm_subnet.app,
    azurerm_subnet.postgres,
  ]
}

# ── PostgreSQL Flexible Server ────────────────────────────────────────────────
resource "azurerm_postgresql_flexible_server" "db" {
  name                          = "psql-quiz-${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = azurerm_resource_group.rg.location
  version                       = "16"
  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  administrator_login           = "quizadmin"
  administrator_password        = data.azurerm_key_vault_secret.db_password.value
  storage_mb                    = 32768
  sku_name                      = "B_Standard_B1ms"
  public_network_access_enabled = false

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "quiz" {
  name      = "quiz"
  server_id = azurerm_postgresql_flexible_server.db.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

# ── App VM ────────────────────────────────────────────────────────────────────
resource "azurerm_linux_virtual_machine" "app" {
  name                            = "vm-app"
  location                        = azurerm_resource_group.rg.location
  resource_group_name             = azurerm_resource_group.rg.name
  size                            = var.vm_size
  admin_username                  = "ivansto"
  admin_password                  = data.azurerm_key_vault_secret.admin_password.value
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.app.id]

  identity {
    type = "SystemAssigned"
  }

  custom_data = base64encode(templatefile("${path.module}/scripts/app-setup.sh", {
    entra_client_id     = data.azurerm_key_vault_secret.entra_client_id.value
    entra_client_secret = data.azurerm_key_vault_secret.entra_client_secret.value
    entra_tenant_id     = data.azurerm_key_vault_secret.entra_tenant_id.value
    flask_secret_key    = data.azurerm_key_vault_secret.flask_secret_key.value
    pg_host             = azurerm_postgresql_flexible_server.db.fqdn
    db_password         = data.azurerm_key_vault_secret.db_password.value
    github_repo         = var.github_repo
    domain              = var.domain
  }))

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  depends_on = [azurerm_postgresql_flexible_server_database.quiz]
}

resource "azurerm_role_assignment" "vm_kv" {
  scope                = data.azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.app.identity[0].principal_id
}

# ── User-assigned identity for App Gateway to read KV cert ───────────────────
resource "azurerm_user_assigned_identity" "agw" {
  name                = "id-agw"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_role_assignment" "agw_kv" {
  scope                = data.azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.agw.principal_id
}

# ── WAF Policy ────────────────────────────────────────────────────────────────
resource "azurerm_web_application_firewall_policy" "waf" {
  name                = "waf-policy-quiz-app"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  policy_settings {
    enabled                     = true
    mode                        = "Prevention"
    request_body_check          = true
    max_request_body_size_in_kb = 128
    file_upload_limit_in_mb     = 100
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }
}

# ── Application Gateway ───────────────────────────────────────────────────────
resource "azurerm_application_gateway" "agw" {
  name                = "agw-quiz-app"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  firewall_policy_id  = azurerm_web_application_firewall_policy.waf.id

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  autoscale_configuration {
    min_capacity = 1
    max_capacity = 3
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.agw.id]
  }

  gateway_ip_configuration {
    name      = "agw-ip-config"
    subnet_id = azurerm_subnet.agw.id
  }

  frontend_port {
    name = "port-80"
    port = 80
  }

  frontend_port {
    name = "port-443"
    port = 443
  }

  frontend_ip_configuration {
    name                 = "agw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.agw.id
  }

  backend_address_pool {
    name         = "vm-backend-pool"
    ip_addresses = [local.app_private_ip]
  }

  backend_http_settings {
    name                  = "http-settings"
    cookie_based_affinity = "Enabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 60
    probe_name            = "health-probe"
  }

  probe {
    name                = "health-probe"
    protocol            = "Http"
    path                = "/login"
    host                = var.domain
    interval            = 30
    timeout             = 30
    unhealthy_threshold = 3

    match {
      status_code = ["200-399"]
    }
  }

  ssl_certificate {
    name                = "quiz-tls"
    key_vault_secret_id = data.azurerm_key_vault_certificate.tls.secret_id
  }

  http_listener {
    name                           = "https-listener"
    frontend_ip_configuration_name = "agw-frontend-ip"
    frontend_port_name             = "port-443"
    protocol                       = "Https"
    ssl_certificate_name           = "quiz-tls"
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "agw-frontend-ip"
    frontend_port_name             = "port-80"
    protocol                       = "Http"
  }

  redirect_configuration {
    name                 = "http-to-https"
    redirect_type        = "Permanent"
    target_listener_name = "https-listener"
    include_path         = true
    include_query_string = true
  }

  request_routing_rule {
    name                       = "https-rule"
    rule_type                  = "Basic"
    http_listener_name         = "https-listener"
    backend_address_pool_name  = "vm-backend-pool"
    backend_http_settings_name = "http-settings"
    priority                   = 100
  }

  request_routing_rule {
    name                        = "http-redirect-rule"
    rule_type                   = "Basic"
    http_listener_name          = "http-listener"
    redirect_configuration_name = "http-to-https"
    priority                    = 200
  }

  depends_on = [azurerm_role_assignment.agw_kv]
}
