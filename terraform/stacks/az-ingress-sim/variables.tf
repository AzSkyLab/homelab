variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox API endpoint URL"
}

variable "proxmox_api_token" {
  type        = string
  description = "Proxmox API token"
  sensitive   = true
}

variable "clone_template_id" {
  type        = number
  description = "VM ID of the Ubuntu template to clone"
  default     = 9000
}

variable "target_node" {
  type        = string
  description = "Proxmox node for az-ingress-sim VMs"
  default     = "pve-r720"
}

variable "vlan_id" {
  type        = number
  description = "VLAN for the sim (Sandbox)"
  default     = 40
}

variable "gateway" {
  type        = string
  description = "Gateway for the sim VLAN"
  default     = "10.0.40.1"
}

variable "storage_pool" {
  type        = string
  description = "Storage pool for VM disks"
  default     = "local-ssd"
}

variable "ssh_public_keys" {
  type        = list(string)
  description = "SSH public keys for the default user"
}
