output "lb_public_ip" {
  description = "IP publique du Load Balancer (à pointer dans votre DNS)"
  value       = hcloud_server.lb.ipv4_address
}

output "control_plane_public_ip" {
  description = "IP publique du Control Plane (accès SSH admin uniquement)"
  value       = hcloud_server.control_plane.ipv4_address
}

output "vpn_node_public_ip" {
  description = "IP publique du nœud VPN (WireGuard UDP 51820)"
  value       = hcloud_server.vpn_node.ipv4_address
}

output "private_network_range" {
  description = "Plage réseau privé interne"
  value       = hcloud_network.private.ip_range
}

output "ansible_inventory" {
  description = "Bloc prêt à coller dans ansible/inventory.ini"
  value = <<-EOT
    [lb]
    lb ansible_host=${hcloud_server.lb.ipv4_address} ansible_user=root

    [control_plane]
    cp ansible_host=${hcloud_server.control_plane.ipv4_address} ansible_user=root

    [vpn_nodes]
    node-01 ansible_host=${hcloud_server.vpn_node.ipv4_address} ansible_user=root

    [all:vars]
    ansible_ssh_private_key_file=~/.ssh/id_ed25519
    private_lb_ip=10.0.0.10
    private_cp_ip=10.0.0.20
    private_node_ip=10.0.0.30
  EOT
}
