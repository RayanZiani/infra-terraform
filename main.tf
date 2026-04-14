terraform {
  required_providers {
    lxd = {
      source = "terraform-lxd/lxd"
    }
  }
}

locals {
  ma_cle = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCe7A5sd2F6c+Ov+4ON5R8jCT/+j0X6CAZTH/YMFJRRwg9Sib5dVkQvg/RHS1iQTtLX6Fw4h8UJciSEWhJxtVW0Kc0Jakh+rBqIOl5qwEpI9J7PcHf0q9rGmrUipeEAAHIEWZ50lu5HmD5dJJJDj9UTl3if9VAYmRyU6+yGNK/3JXopM2KYr6xCaR1vAs4DyOuDkPVl/ZlZmGKpZULLBYtS+cAo42Rv0XHKm7+qbE5GVHTlE+xdDJeMV6v7WxhFY0ti2ah1WL4G4xJcojWbFQ7sDBNtq+IiNQ3F80iZowQrsQg+iKtfBnHkJNuOcTrKlHsuvF2Gd1QmVhXiFGAtqf0P root@epsi-m1-g2-AMOR"

  cle_rayan = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDx8qdvxcX6S98fbxJ3qeKmLTNHpq5RBM9Aj4UU3Cws7 rayan_ziani.web@yahoo.com"
}

# Réseau privé interne
resource "lxd_network" "private_net" {
  name = "secure-priv"
  config = {
    "ipv4.address" = "10.0.0.1/24"
    "ipv4.nat"     = "true"
  }
}

# On installe Docker direct pour Rayan sur le CP et le Node
locals {
  cloud_init_config = <<-EOT
    #cloud-config
    ssh_authorized_keys:
      - ${local.ma_cle}
      - ${local.cle_rayan}
    package_update: true
    packages:
      - curl
      - git
  EOT
}

# 1. Le Load Balancer (LB)
resource "lxd_instance" "lb" {
  name      = "secure-lb"
  image     = "ubuntu:24.04"
  type      = "virtual-machine"
  config = {
    "user.user-data" = local.cloud_init_config
  }
  device {
    name = "eth0"
    type = "nic"
    properties = { network = "lxdbr0" } # Public
  }
  device {
    name = "eth1"
    type = "nic"
    properties = {
      network = lxd_network.private_net.name
      "ipv4.address" = "10.0.0.10"
    }
  }
}

# 2. Le Control Plane (CP) - API et DB
resource "lxd_instance" "cp" {
  name      = "secure-cp"
  image     = "ubuntu:24.04"
  type      = "virtual-machine"
  config = {
    "user.user-data" = local.cloud_init_config
  }
  device {
    name = "eth0"
    type = "nic"
    properties = {
      network = lxd_network.private_net.name
      "ipv4.address" = "10.0.0.20"
    }
  }
}

# 3. Le Node VPN (WireGuard)
resource "lxd_instance" "vpn_node" {
  name      = "secure-node-01"
  image     = "ubuntu:24.04"
  type      = "virtual-machine"
  config = {
    "user.user-data" = local.cloud_init_config
  }
  device {
    name = "eth0"
    type = "nic"
    properties = { network = "lxdbr0" } # Public pour le tunnel
  }
  device {
    name = "eth1"
    type = "nic"
    properties = {
      network = lxd_network.private_net.name
      "ipv4.address" = "10.0.0.30"
    }
  }
}

# 4. La VM Admin (Bastion + DNS)
resource "lxd_instance" "admin" {
  name      = "secure-admin"
  image     = "ubuntu:24.04"
  type      = "virtual-machine"
  config = {
    "user.user-data" = local.cloud_init_config
  }
  device {
    name = "eth0"
    type = "nic"
    properties = { network = "lxdbr0" }
  }
  device {
    name = "eth1"
    type = "nic"
    properties = {
      network = lxd_network.private_net.name
      "ipv4.address" = "10.0.0.250" # IP fixe pour l'admin
    }
  }
}