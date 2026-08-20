output "dns_az_ip" {
  value       = "10.0.40.53"
  description = "bind9 DNS VM (az.home.lab authoritative + flipper)"
}

output "ingress_east_ip" {
  value       = "10.0.40.61"
  description = "East region ingress VIP (HAProxy F5 sim)"
}

output "ingress_central_ip" {
  value       = "10.0.40.62"
  description = "Central region ingress VIP (HAProxy F5 sim)"
}

output "vm_ids" {
  value = {
    dns_az          = module.dns_az.vm_id
    ingress_east    = module.ingress_east.vm_id
    ingress_central = module.ingress_central.vm_id
  }
  description = "Proxmox VM IDs"
}
