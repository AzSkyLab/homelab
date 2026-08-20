# az-ingress-sim — home-lab validation of the az.comp.app ingress blueprint
# (see docs/az-ingress-sim.md and ai-gov-review/az-ingress-blueprint.md)
#
#   dns-az-01        bind9 "Azure DNS" for az.home.lab + DNS health flipper
#   ingress-east     HAProxy (F5 sim) -> nginx (AGW sim) -> k3s "east env"
#   ingress-central  HAProxy (F5 sim) -> nginx (AGW sim) -> k3s "central env"

module "dns_az" {
  source = "../../modules/proxmox-vm"

  name        = "dns-az-01"
  target_node = var.target_node
  vm_id       = 450

  clone_template_id = var.clone_template_id
  cores             = 1
  memory            = 1024
  disk_size         = 30
  storage_pool      = var.storage_pool

  vlan_id    = var.vlan_id
  ip_address = "10.0.40.53/24"
  gateway    = var.gateway

  ssh_public_keys = var.ssh_public_keys

  tags = ["terraform", "az-ingress-sim"]
}

module "ingress_east" {
  source = "../../modules/proxmox-vm"

  name        = "ingress-east"
  target_node = var.target_node
  vm_id       = 451

  clone_template_id = var.clone_template_id
  cores             = 2
  memory            = 2048
  disk_size         = 30
  storage_pool      = var.storage_pool

  vlan_id    = var.vlan_id
  ip_address = "10.0.40.61/24"
  gateway    = var.gateway

  ssh_public_keys = var.ssh_public_keys

  tags = ["terraform", "az-ingress-sim"]
}

module "ingress_central" {
  source = "../../modules/proxmox-vm"

  name        = "ingress-central"
  target_node = var.target_node
  vm_id       = 452

  clone_template_id = var.clone_template_id
  cores             = 2
  memory            = 2048
  disk_size         = 30
  storage_pool      = var.storage_pool

  vlan_id    = var.vlan_id
  ip_address = "10.0.40.62/24"
  gateway    = var.gateway

  ssh_public_keys = var.ssh_public_keys

  tags = ["terraform", "az-ingress-sim"]
}
