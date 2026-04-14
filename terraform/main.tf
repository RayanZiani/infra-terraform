# ---------------------------------------------------------------------------
# SSH Key
# ---------------------------------------------------------------------------

resource "hcloud_ssh_key" "admin" {
  name       = "${var.project_name}-admin-key"
  public_key = var.ssh_public_key
}

# ---------------------------------------------------------------------------
# Private Network (réseau interne entre les VMs)
# ---------------------------------------------------------------------------

resource "hcloud_network" "private" {
  name     = "${var.project_name}-network"
  ip_range = "10.0.0.0/24"
}

resource "hcloud_network_subnet" "private" {
  network_id   = hcloud_network.private.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.0.0/24"
}

# ---------------------------------------------------------------------------
# Firewall — Load Balancer (seule VM exposée publiquement)
# ---------------------------------------------------------------------------

resource "hcloud_firewall" "lb" {
  name = "${var.project_name}-lb-fw"

  # HTTP/HTTPS publics
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # SSH uniquement depuis l'IP admin
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = ["${var.admin_ip}/32"]
  }
}

# ---------------------------------------------------------------------------
# Firewall — Control Plane (accessible uniquement depuis le réseau privé + admin)
# ---------------------------------------------------------------------------

resource "hcloud_firewall" "control_plane" {
  name = "${var.project_name}-cp-fw"

  # API FastAPI — réseau privé uniquement
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "8000"
    source_ips = ["10.0.0.0/24"]
  }

  # SSH admin
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = ["${var.admin_ip}/32"]
  }
}

# ---------------------------------------------------------------------------
# Firewall — VPN Node
# ---------------------------------------------------------------------------

resource "hcloud_firewall" "vpn_node" {
  name = "${var.project_name}-node-fw"

  # WireGuard
  rule {
    direction = "in"
    protocol  = "udp"
    port      = "51820"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # SSH admin
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = ["${var.admin_ip}/32"]
  }
}

# ---------------------------------------------------------------------------
# VM : Load Balancer / Reverse Proxy
# ---------------------------------------------------------------------------

resource "hcloud_server" "lb" {
  name        = "${var.project_name}-lb"
  server_type = var.server_type_small
  image       = "ubuntu-24.04"
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.lb.id]

  user_data = templatefile("${path.module}/cloud-init/base.yaml", {
    hostname = "lb"
  })

  labels = {
    project = var.project_name
    role    = "lb"
  }
}

resource "hcloud_server_network" "lb" {
  server_id  = hcloud_server.lb.id
  network_id = hcloud_network.private.id
  ip         = "10.0.0.10"
}

# ---------------------------------------------------------------------------
# VM : Control Plane (API FastAPI + PostgreSQL + Redis)
# ---------------------------------------------------------------------------

resource "hcloud_server" "control_plane" {
  name        = "${var.project_name}-cp"
  server_type = var.server_type_medium
  image       = "ubuntu-24.04"
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.control_plane.id]

  user_data = templatefile("${path.module}/cloud-init/base.yaml", {
    hostname = "control-plane"
  })

  labels = {
    project = var.project_name
    role    = "control-plane"
  }
}

resource "hcloud_server_network" "control_plane" {
  server_id  = hcloud_server.control_plane.id
  network_id = hcloud_network.private.id
  ip         = "10.0.0.20"
}

# ---------------------------------------------------------------------------
# VM : VPN Node (Go Agent + WireGuard)
# ---------------------------------------------------------------------------

resource "hcloud_server" "vpn_node" {
  name        = "${var.project_name}-node-01"
  server_type = var.server_type_medium
  image       = "ubuntu-24.04"
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.vpn_node.id]

  user_data = templatefile("${path.module}/cloud-init/base.yaml", {
    hostname = "vpn-node-01"
  })

  labels = {
    project = var.project_name
    role    = "vpn-node"
  }
}

resource "hcloud_server_network" "vpn_node" {
  server_id  = hcloud_server.vpn_node.id
  network_id = hcloud_network.private.id
  ip         = "10.0.0.30"
}

# ---------------------------------------------------------------------------
# DNS (enregistrements Hetzner DNS — optionnel si domaine géré ailleurs)
# ---------------------------------------------------------------------------

# Note : Adapter au registrar utilisé (OVH, Cloudflare, etc.)
# Les IPs publiques sont dans les outputs ci-dessous.
