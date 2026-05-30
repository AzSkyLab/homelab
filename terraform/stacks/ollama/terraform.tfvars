proxmox_endpoint = "https://10.0.10.13:8006"

clone_template_id = 9001
target_node       = "pve-desktop"

cores     = 8
memory    = 16384
disk_size = 200

vlan_id    = 20
ip_address = "10.0.20.30/24"
gateway    = "10.0.20.1"

storage_pool = "local-ssd"

ssh_public_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDbnmCZMMU6BMdMdSxpVyaG13sD0QSd+63VUECrV/Kt6 zerocool@cachyos"]
