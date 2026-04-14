variable "hcloud_token" {
  description = "Token API Hetzner Cloud (créer sur console.hetzner.cloud)"
  type        = string
  sensitive   = true
}

variable "project_name" {
  description = "Préfixe utilisé pour nommer toutes les ressources"
  type        = string
  default     = "securenet-vpn"
}

variable "ssh_public_key" {
  description = "Clé SSH publique de l'administrateur (~/.ssh/id_ed25519.pub)"
  type        = string
}

variable "admin_ip" {
  description = "IP publique de l'administrateur (restreint l'accès SSH)"
  type        = string
  # Exemple : "82.64.12.34"
}

variable "location" {
  description = "Datacenter Hetzner (nbg1=Nuremberg, fsn1=Falkenstein, hel1=Helsinki)"
  type        = string
  default     = "nbg1"
}

variable "server_type_small" {
  description = "Type de VM pour le LB (2 vCPU, 2 GB RAM)"
  type        = string
  default     = "cx22"
}

variable "server_type_medium" {
  description = "Type de VM pour le Control Plane et le nœud VPN (2 vCPU, 4 GB RAM)"
  type        = string
  default     = "cx32"
}
