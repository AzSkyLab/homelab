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
  description = "Proxmox node for Ollama VM"
  default     = "pve-desktop"
}

variable "cores" {
  type        = number
  description = "CPU cores"
  default     = 8
}

variable "memory" {
  type        = number
  description = "Memory in MB"
  default     = 16384
}

variable "disk_size" {
  type        = number
  description = "Disk size in GB"
  default     = 200
}

variable "vlan_id" {
  type        = number
  description = "VLAN ID for k8s network"
  default     = 20
}

variable "ip_address" {
  type        = string
  description = "Static IP for Ollama VM"
  default     = "10.0.20.30/24"
}

variable "gateway" {
  type        = string
  description = "Gateway for k8s VLAN"
  default     = "10.0.20.1"
}

variable "cloud_init_file_id" {
  type        = string
  description = "Proxmox snippet ID for cloud-init"
  default     = null
}

variable "ssh_public_keys" {
  type        = list(string)
  description = "SSH public keys for VM access"
}

variable "storage_pool" {
  type        = string
  description = "Storage pool for VM disk"
  default     = "local-ssd"
}
