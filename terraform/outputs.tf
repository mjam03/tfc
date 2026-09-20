output "rdp_targets" {
  description = "VM name -> public IP. Enter these in Windows App; username is azureadmin."
  value       = { for k, pip in azurerm_public_ip.pip : k => pip.ip_address }
}

output "vm_count" {
  description = "Total VMs deployed."
  value       = length(local.vm_instances)
}

output "vcpus_per_region" {
  description = "vCPUs requested per region. Quota is granted per region, per VM family -- check this before scaling."
  value = {
    for region in local.region_names :
    region => 2 * length([for _, v in local.vm_instances : v if v.region == region])
  }
}

# Consumed by scripts/monitor.py. Contains a read SAS, so it is written to a
# gitignored file rather than printed:
#   terraform output -raw monitor_config > ../scripts/monitor.config.json
output "monitor_config" {
  description = "Config blob for the local dashboard."
  sensitive   = true
  value = jsonencode({
    container_url = "${azurerm_storage_account.shared.primary_blob_endpoint}${azurerm_storage_container.screens.name}"
    sas           = data.azurerm_storage_account_blob_container_sas.monitor_screens.sas
    control_url   = "${azurerm_storage_account.shared.primary_blob_endpoint}${azurerm_storage_container.control.name}"
    control_sas   = data.azurerm_storage_account_blob_container_sas.monitor_control.sas
    targets       = { for k, pip in azurerm_public_ip.pip : k => pip.ip_address }
    username      = "azureadmin"
    default_url   = var.target_url
    browser_count = var.browsers_per_vm
  })
}
