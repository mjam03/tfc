# Region -> second octet of the VNet address space.
#
# The octet is pinned per region rather than derived from list position (as the
# an earlier version did with index(keys(...))). Position-derived addressing
# renumbers every existing VNet the moment a region is added or renamed, which
# forces replacement of VMs you may already have running.
variable "regions" {
  description = "Azure regions to deploy into, mapped to a unique VNet octet (1-254)."
  type        = map(number)
  default = {
    uksouth = 1
  }
}

variable "vm_count" {
  description = "Total VMs, distributed round-robin across regions. 1 for the test; 17 for the fleet."
  type        = number
  default     = 1
}

variable "primary_region" {
  description = "Region holding the shared resource group: bootstrap scripts and the screenshot container."
  type        = string
  default     = "uksouth"
}

variable "my_ip" {
  description = "Your public IP in CIDR form, e.g. 203.0.113.4/32. Sole source allowed to RDP."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.my_ip))
    error_message = "my_ip must be CIDR notation, e.g. 203.0.113.4/32."
  }
}

variable "admin_password" {
  description = "RDP password for the azureadmin account."
  type        = string
  sensitive   = true
}

variable "vm_size" {
  description = "Azure VM size. B2ms is 2 vCPU / 8 GB -- three browsers fit; B2s (4 GB) does not."
  type        = string
  default     = "Standard_B2ms"
}

# Windows *client* images need an eligible subscription. win10-21h2-pro is what
# the previous deployment used successfully; switch to windows-11 / win11-23h2-pro
# if you want a current, still-supported OS.
variable "image_offer" {
  description = "Marketplace image offer."
  type        = string
  default     = "windows-11"
}

# win10-21h2-pro (what the earlier build used) has been withdrawn from the
# marketplace and now 404s at create time. Windows 11 images are Gen2 and
# need Trusted Launch.
variable "image_sku" {
  description = "Marketplace image SKU."
  type        = string
  default     = "win11-25h2-pro"
}

variable "trusted_launch" {
  description = "Secure boot + vTPM. Required by the Windows 11 Gen2 images; must be false for a Gen1 Windows 10 SKU."
  type        = bool
  default     = true
}

variable "target_url" {
  description = "URL the browsers open on login, and that the connectivity probe measures."
  type        = string
  default     = "https://glastonbury.seetickets.com/content/extras"
}

variable "browsers_per_vm" {
  description = "Browser windows per VM, tiled side by side. Each is a distinct browser (Firefox, Chrome, Edge), not N copies of one."
  type        = number
  default     = 3

  validation {
    condition     = var.browsers_per_vm >= 1 && var.browsers_per_vm <= 3
    error_message = "browsers_per_vm must be 1-3 (Firefox, Chrome, Edge)."
  }
}

variable "screenshot_interval_seconds" {
  description = "Desktop capture cadence. Each frame is a JPEG of roughly 100-250 KB."
  type        = number
  default     = 15
}

variable "screenshot_max_width" {
  description = "Screenshots are downscaled to this width before upload, to keep the dashboard responsive."
  type        = number
  default     = 1280
}

variable "sas_valid_days" {
  description = "Lifetime of the SAS tokens used for screenshot upload and dashboard read."
  type        = number
  default     = 90
}

variable "auto_shutdown_time" {
  description = "Daily auto-shutdown in 24h HHmm, UTC. A cost backstop for when a teardown is forgotten. Set to null to disable."
  type        = string
  default     = "2300"
}

variable "auto_logon" {
  description = <<-EOT
    Log the admin user in automatically at boot, so browsers and the screenshot
    loop start without anyone connecting first. Writes the password to the
    Winlogon registry key in plaintext -- acceptable only because RDP is
    firewalled to my_ip. Set false to require a manual RDP login per VM.
  EOT
  type        = bool
  default     = true
}

variable "control_poll_seconds" {
  description = "How often each VM checks the control container for a new command. This is the lag between hitting Relaunch and the browsers reopening."
  type        = number
  default     = 5
}
