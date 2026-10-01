locals {
  # Round-robin the requested VM count across regions, so vm_count need not
  # divide evenly (17 across 4 regions gives 5/4/4/4).
  region_names = sort(keys(var.regions))

  vm_instances = {
    for i in range(var.vm_count) :
    format("twitchy-%s-%d",
      local.region_names[i % length(local.region_names)],
      floor(i / length(local.region_names)) + 1
      ) => {
      region = local.region_names[i % length(local.region_names)]
      idx    = floor(i / length(local.region_names))
      i      = i
    }
  }

  scripts = ["bootstrap.ps1", "launch.ps1", "capture.ps1", "upload.ps1", "keepalive.ps1", "control.ps1"]

  # Source IPs allowed to RDP: your primary (my_ip, from .env) plus any extra
  # locations. Deduplicated so overlaps are harmless.
  rdp_allow_ips = distinct(concat([var.my_ip], var.extra_rdp_ips))

  # ISP static proxies: one `host:port` per line in proxies.txt (gitignored),
  # one endpoint per VM. Assigned by VM index so each VM gets its own dedicated
  # residential IP. element() cycles if the list is short, but for ISP you want
  # at least vm_count lines (see the proxy_endpoints output for a mismatch flag).
  proxy_raw = try(trimspace(file("${path.module}/${var.proxy_file}")), "")
  proxy_list = local.proxy_raw == "" ? [] : [
    for l in split("\n", local.proxy_raw) :
    trimspace(l) if trimspace(l) != "" && !startswith(trimspace(l), "#")
  ]
  proxy_enabled = var.use_proxy && var.proxy_user != "" && length(local.proxy_list) > 0
  vm_proxy = {
    for k, v in local.vm_instances :
    k => local.proxy_enabled ? element(local.proxy_list, v.i) : ""
  }
}

resource "random_string" "suffix" {
  length  = 10
  special = false
  upper   = false
}

resource "time_static" "sas_start" {}

# ---------------------------------------------------------------------------
# Shared resources: one storage account for bootstrap scripts and screenshots,
# so the dashboard has a single place to read from.
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "shared" {
  name     = "twitchy-shared"
  location = var.primary_region
}

resource "azurerm_storage_account" "shared" {
  name                     = "twitchy${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.shared.name
  location                 = azurerm_resource_group.shared.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "scripts" {
  name                  = "scripts"
  storage_account_name  = azurerm_storage_account.shared.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "screens" {
  name                  = "screens"
  storage_account_name  = azurerm_storage_account.shared.name
  container_access_type = "private"
}

# Command channel. The dashboard writes command.json; each VM polls it and
# writes back ack-<vm>.json. Blob polling rather than WinRM or Run Command:
# no inbound ports, no extra auth on the laptop, and a new URL reaches every
# VM within one poll interval instead of a per-VM round trip.
resource "azurerm_storage_container" "control" {
  name                  = "control"
  storage_account_name  = azurerm_storage_account.shared.name
  container_access_type = "private"
}

# Scripts reach the VM as private blobs pulled by the Custom Script Extension
# via fileUris. Inlining PowerShell into commandToExecute (as the old main.tf
# did) means every quote has to survive JSON *and* shell escaping, which is why
# that version was a single unreadable line.
resource "azurerm_storage_blob" "script" {
  for_each               = toset(local.scripts)
  name                   = each.value
  storage_account_name   = azurerm_storage_account.shared.name
  storage_container_name = azurerm_storage_container.scripts.name
  type                   = "Block"
  source                 = "${path.module}/../scripts/${each.value}"
  content_md5            = filemd5("${path.module}/../scripts/${each.value}")
}

# Container-scoped SAS rather than account-scoped, so a VM holds no more
# authority than its job needs: push frames, read commands, acknowledge them.

data "azurerm_storage_account_blob_container_sas" "vm_screens" {
  connection_string = azurerm_storage_account.shared.primary_connection_string
  container_name    = azurerm_storage_container.screens.name
  https_only        = true

  start  = time_static.sas_start.rfc3339
  expiry = timeadd(time_static.sas_start.rfc3339, "${var.sas_valid_days * 24}h")

  permissions {
    read   = false
    add    = false
    create = true
    write  = true
    delete = false
    list   = false
  }
}

# Read the command, write the ack -- both live in the control container.
data "azurerm_storage_account_blob_container_sas" "vm_control" {
  connection_string = azurerm_storage_account.shared.primary_connection_string
  container_name    = azurerm_storage_container.control.name
  https_only        = true

  start  = time_static.sas_start.rfc3339
  expiry = timeadd(time_static.sas_start.rfc3339, "${var.sas_valid_days * 24}h")

  permissions {
    read   = true
    add    = false
    create = true
    write  = true
    delete = false
    list   = false
  }
}

data "azurerm_storage_account_blob_container_sas" "monitor_screens" {
  connection_string = azurerm_storage_account.shared.primary_connection_string
  container_name    = azurerm_storage_container.screens.name
  https_only        = true

  start  = time_static.sas_start.rfc3339
  expiry = timeadd(time_static.sas_start.rfc3339, "${var.sas_valid_days * 24}h")

  permissions {
    read   = true
    add    = false
    create = false
    write  = false
    delete = false
    list   = true
  }
}

data "azurerm_storage_account_blob_container_sas" "monitor_control" {
  connection_string = azurerm_storage_account.shared.primary_connection_string
  container_name    = azurerm_storage_container.control.name
  https_only        = true

  start  = time_static.sas_start.rfc3339
  expiry = timeadd(time_static.sas_start.rfc3339, "${var.sas_valid_days * 24}h")

  permissions {
    read   = true
    add    = false
    create = true
    write  = true
    delete = false
    list   = true
  }
}

# ---------------------------------------------------------------------------
# Per-region networking
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "rg" {
  for_each = var.regions
  name     = "twitchy-${each.key}"
  location = each.key
}

resource "azurerm_virtual_network" "vnet" {
  for_each            = var.regions
  name                = "twitchy-vnet-${each.key}"
  address_space       = ["10.${each.value}.0.0/16"]
  location            = each.key
  resource_group_name = azurerm_resource_group.rg[each.key].name
}

resource "azurerm_subnet" "subnet" {
  for_each             = var.regions
  name                 = "twitchy-subnet-${each.key}"
  resource_group_name  = azurerm_resource_group.rg[each.key].name
  virtual_network_name = azurerm_virtual_network.vnet[each.key].name
  address_prefixes     = ["10.${each.value}.1.0/24"]
}

resource "azurerm_network_security_group" "nsg" {
  for_each            = var.regions
  name                = "twitchy-nsg-${each.key}"
  location            = each.key
  resource_group_name = azurerm_resource_group.rg[each.key].name

  security_rule {
    name                   = "RDP"
    priority               = 1000
    direction              = "Inbound"
    access                 = "Allow"
    protocol               = "Tcp"
    source_port_range      = "*"
    destination_port_range = "3389"
    # Every location you might RDP from: my_ip (home, from .env) plus any extra
    # locations in extra_rdp_ips. Changing this is an in-place NSG update (no VM
    # reboot), so you can add a new location and re-apply in seconds.
    source_address_prefixes    = local.rdp_allow_ips
    destination_address_prefix = "*"
  }
}

# ---------------------------------------------------------------------------
# Per-VM resources
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "pip" {
  for_each            = local.vm_instances
  name                = "${each.key}-pip"
  resource_group_name = azurerm_resource_group.rg[each.value.region].name
  location            = each.value.region
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "nic" {
  for_each            = local.vm_instances
  name                = "${each.key}-nic"
  location            = each.value.region
  resource_group_name = azurerm_resource_group.rg[each.value.region].name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet[each.value.region].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip[each.key].id
  }
}

resource "azurerm_network_interface_security_group_association" "nsg_assoc" {
  for_each                  = local.vm_instances
  network_interface_id      = azurerm_network_interface.nic[each.key].id
  network_security_group_id = azurerm_network_security_group.nsg[each.value.region].id
}

resource "azurerm_windows_virtual_machine" "vm" {
  for_each              = local.vm_instances
  name                  = each.key
  computer_name         = "vm-${substr(each.value.region, 0, 4)}${each.value.idx + 1}"
  resource_group_name   = azurerm_resource_group.rg[each.value.region].name
  location              = each.value.region
  size                  = var.vm_size
  admin_username        = "azureadmin"
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.nic[each.key].id]

  secure_boot_enabled = var.trusted_launch
  vtpm_enabled        = var.trusted_launch

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsDesktop"
    offer     = var.image_offer
    sku       = var.image_sku
    version   = "latest"
  }
}

resource "azurerm_virtual_machine_extension" "bootstrap" {
  for_each             = local.vm_instances
  name                 = "bootstrap"
  virtual_machine_id   = azurerm_windows_virtual_machine.vm[each.key].id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  # Forces the extension to re-run whenever any script changes.
  settings = jsonencode({
    script_hashes = { for name, blob in azurerm_storage_blob.script : name => blob.content_md5 }
  })

  protected_settings = jsonencode({
    fileUris = [for name in local.scripts : azurerm_storage_blob.script[name].id]

    # The SAS is base64-encoded so its & and = characters survive the trip
    # through JSON, cmd.exe and PowerShell argument parsing intact.
    commandToExecute = join(" ", [
      "powershell -ExecutionPolicy Bypass -File bootstrap.ps1",
      "-TargetUrl \"${var.target_url}\"",
      "-BrowserCount ${var.browsers_per_vm}",
      "-VmName \"${each.key}\"",
      "-ScreensBaseUrl \"${azurerm_storage_account.shared.primary_blob_endpoint}${azurerm_storage_container.screens.name}\"",
      "-ScreensSasB64 \"${base64encode(data.azurerm_storage_account_blob_container_sas.vm_screens.sas)}\"",
      "-ControlBaseUrl \"${azurerm_storage_account.shared.primary_blob_endpoint}${azurerm_storage_container.control.name}\"",
      "-ControlSasB64 \"${base64encode(data.azurerm_storage_account_blob_container_sas.vm_control.sas)}\"",
      "-IntervalSeconds ${var.screenshot_interval_seconds}",
      "-ControlPollSeconds ${var.control_poll_seconds}",
      "-AutoLogon ${var.auto_logon ? 1 : 0}",
      "-AdminPasswordB64 \"${base64encode(var.admin_password)}\"",
      "-MaxWidth ${var.screenshot_max_width}",
      "-ProxyEndpoint \"${local.vm_proxy[each.key]}\"",
      "-ProxyUserB64 \"${base64encode(var.proxy_user)}\"",
      "-ProxyPassB64 \"${base64encode(var.proxy_password)}\"",
    ])

    storageAccountName = azurerm_storage_account.shared.name
    storageAccountKey  = azurerm_storage_account.shared.primary_access_key
  })

  timeouts {
    create = "45m"
  }
}

# Cost backstop: 17 VMs left running is roughly £2k/month.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "auto_shutdown" {
  for_each              = var.auto_shutdown_time == null ? {} : local.vm_instances
  virtual_machine_id    = azurerm_windows_virtual_machine.vm[each.key].id
  location              = each.value.region
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = "UTC"

  notification_settings {
    enabled = false
  }
}
