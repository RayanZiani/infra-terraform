# Projet d'Infrastructure — Déploiement d'une Plateforme VPN

> **Entreprise fictive :** SecureNet SAS  
> **Contexte :** Infrastructure de VPN commerciale déployée sur cloud (Hetzner) via IaC (Terraform + Ansible)

---

## 1. Scénario & Service Rendu

SecureNet SAS est une start-up proposant un **service VPN grand public** et **proxy résidentiel** pour des entreprises. Elle a besoin d'une infrastructure :

- **Disponible** : accessible 24/7, un seul point de panne réseau doit être évité
- **Sécurisée** : aucune exposition directe des serveurs backend sur Internet
- **Administrable** : déployable en quelques commandes, reproductible à l'identique
- **Évolutive** : ajouter un nœud VPN = réexécuter un playbook Ansible

**Évolutions prévues :** supervision (Prometheus + Grafana), sauvegarde chiffrée des états WireGuard, multi-région.

---

## 2. Schéma LLD (Low Level Design)

```
                         INTERNET (trafic public)
                                  │
                    ┌─────────────▼──────────────┐
                    │   Load Balancer / Proxy     │
                    │   VM lb — IP publique X.X.X.X│
                    │   Nginx — ports 80 / 443    │
                    │   Firewall : 80,443 public  │
                    │             22 admin only   │
                    └─────────────┬───────────────┘
                                  │ HTTP (réseau privé 10.0.0.0/24)
                                  │ 10.0.0.10 → 10.0.0.20:8000
                    ┌─────────────▼──────────────┐
                    │     Control Plane (API)     │
                    │   VM cp — 10.0.0.20         │
                    │   Docker : FastAPI :8000    │
                    │            PostgreSQL :5432 │
                    │            Redis :6379      │
                    │   Firewall : 8000 réseau    │
                    │             privé seulement │
                    │             22 admin only   │
                    └─────────────────────────────┘
                                  │
                    Heartbeat HTTP (polling 30s)
                    X-API-Key auth — réseau privé
                                  │
                    ┌─────────────▼──────────────┐
                    │        VPN Node 01          │
                    │   VM node-01 — 10.0.0.30   │
                    │   IP publique Y.Y.Y.Y       │
                    │   Go Agent (vpn-agent)      │
                    │   WireGuard wg0 UDP 51820   │
                    │   Pool clients : 10.8.0.0/16│
                    │   Firewall : 51820 public   │
                    │             22 admin only   │
                    └─────────────┬───────────────┘
                                  │ Tunnel WireGuard chiffré
                                  │ ChaCha20-Poly1305 + Curve25519
                         ┌────────▼────────┐
                         │  Clients VPN    │
                         │  IP : 10.8.0.x  │
                         └─────────────────┘
```

### Réseaux

| Réseau | Plage IP | Usage |
|---|---|---|
| Public (Internet) | — | Accès utilisateurs finaux, WireGuard |
| Privé Hetzner | `10.0.0.0/24` | Communication interne LB ↔ CP ↔ Nodes |
| Tunnel VPN | `10.8.0.0/16` | IPs attribuées aux clients VPN connectés |

### Flux et ports

| Source | Destination | Port | Protocole | Rôle |
|---|---|---|---|---|
| Internet | LB | 80, 443 | TCP | API HTTP/HTTPS (utilisateurs) |
| Admin | LB / CP / Node | 22 | TCP | SSH administrateur uniquement |
| LB | CP | 8000 | TCP | Reverse proxy → FastAPI |
| Node | CP | 8000 | TCP | Heartbeat, sync peers |
| Clients VPN | Node | 51820 | UDP | Tunnel WireGuard |

---

## 3. Tableau des Choix Techniques

| Décision | Justification | Points d'attention |
|---|---|---|
| **Terraform (IaC)** | Infra reproductible en une commande. Le fichier `terraform.tfstate` est la source de vérité de l'état réel. Permet de versionner l'infra comme du code. | Ne pas committer `terraform.tfstate` ni `terraform.tfvars` (secrets). Ajouter au `.gitignore`. |
| **Hetzner Cloud** | Coût réduit (~5€/mois par VM), datacenter européen (conformité RGPD), API simple. Provider Terraform disponible. | Moins de services managés qu'AWS. Prévoir un backup de la base manuellement si pas de snapshot auto. |
| **3 VMs séparées** (LB + CP + Node) | Séparation des rôles : le LB est le seul point public, le CP n'est jamais exposé directement. Si le node est compromis, l'API reste protégée. | Latence réseau interne Hetzner : ~1ms → négligeable. |
| **Nginx comme reverse proxy** | Léger, fiable, gestion native des WebSockets (proxy pool extension), facile à intégrer avec Certbot (TLS). | Configuration `proxy_set_header Upgrade` obligatoire pour le WebSocket. |
| **Ansible pour le provisioning** | Idempotent : réexécuter les playbooks ne casse rien. Chaque rôle est indépendant et testable. Pas d'agent à installer sur les VMs cibles. | Ordre d'exécution important : CP avant Node (l'agent Go a besoin de l'API disponible). |
| **Docker Compose en production** | Le Control Plane tourne dans 3 conteneurs (API + PostgreSQL + Redis). Isolation, rolling update simple, pas de Kubernetes pour un projet de taille raisonnable. | L'API est bindée sur `10.0.0.20:8000` uniquement, jamais sur `0.0.0.0`. |
| **WireGuard (protocole VPN)** | Cryptographie moderne (ChaCha20-Poly1305, Curve25519). Code minimaliste (~4000 lignes vs ~70 000 pour OpenVPN). Intégré au kernel Linux depuis 5.6. | Nécessite `CAP_NET_ADMIN` pour l'agent. Géré via systemd capabilities (pas `--privileged`). |
| **Go pour le node agent** | Compile en binaire statique sans runtime. Goroutines natives pour paralléliser heartbeat, sync, health check. Cross-compilation simple (`GOOS=linux GOARCH=amd64`). | Les tests mockent les commandes système (`wg`, `iptables`) pour ne pas requérir root. |
| **FastAPI (Python async)** | Framework asynchrone pour gérer N heartbeats simultanés sans bloquer. Compatible `asyncpg` (PostgreSQL async natif). | Refus de démarrer si `SECRET_KEY=change-me-in-production` en mode prod. |
| **Réseau privé Hetzner** | La communication LB→CP et Node→CP passe par un réseau 10.0.0.0/24 non routable depuis Internet. Double protection avec les firewalls. | Hetzner facture le trafic privé intra-datacenter à moindre coût que le trafic public. |
| **Cloud-init** | Permet de préparer les VMs dès le premier boot (désactivation mot de passe root, SSH hardened) avant même qu'Ansible intervienne. | Exécuté une seule fois. Les modifications post-boot sont gérées par Ansible. |
| **Clé SSH ED25519** | Plus courte, plus rapide et plus sécurisée que RSA 2048/4096. L'accès SSH root est limité à l'IP admin via firewall Hetzner. | Jamais de mot de passe SSH. `PasswordAuthentication no` dans `sshd_config`. |

---

## 4. Commandes de Déploiement

```bash
# 1. Provisionner les VMs sur Hetzner
cd cours-infra/terraform
cp terraform.tfvars.example terraform.tfvars
# Éditer terraform.tfvars avec vos valeurs
terraform init
terraform plan
terraform apply

# 2. Récupérer l'inventaire Ansible généré
terraform output ansible_inventory
# Coller dans ansible/inventory.ini

# 3. Configurer les VMs (dans l'ordre)
cd ../ansible
ansible-playbook -i inventory.ini playbooks/02-setup-control-plane.yml
ansible-playbook -i inventory.ini playbooks/01-setup-lb.yml
ansible-playbook -i inventory.ini playbooks/03-setup-vpn-node.yml

# 4. Vérifier
ansible all -i inventory.ini -m ping
```

---

## 5. Validation & Tests

### Test 1 — Connectivité SSH (bastion)
```bash
ssh -i ~/.ssh/id_ed25519 root@<LB_IP>    # ✅ Doit fonctionner
ssh -i ~/.ssh/id_ed25519 root@<CP_IP>    # ✅ Doit fonctionner (si admin_ip correct)
```

### Test 2 — LB répond sur HTTP
```bash
curl -v http://<LB_IP>/health
# Résultat attendu : 200 OK — "ok"
```

### Test 3 — API accessible via le LB
```bash
curl http://<LB_IP>/health
# Résultat attendu : {"status": "ok"} (proxy vers CP:8000)
```

### Test 4 — API NON accessible directement depuis Internet
```bash
curl http://<CP_IP>:8000/health
# Résultat attendu : timeout (firewall bloque)
```

### Test 5 — WireGuard actif sur le nœud
```bash
ssh root@<NODE_IP> 'wg show wg0'
# Résultat attendu : interface wg0 listée avec clé publique et port 51820
```

### Test 6 — Heartbeat nœud → API
```bash
# Depuis le nœud VPN :
curl -H "X-API-Key: <agent_api_key>" http://10.0.0.20:8000/nodes/self
# Résultat attendu : JSON avec les infos du nœud
```

### Test 7 — Isolation réseau (sécurité)
```bash
# Depuis une machine externe, tenter d'atteindre directement PostgreSQL
nc -zv <CP_IP> 5432
# Résultat attendu : Connection refused / timeout (firewall bloque)
```

---

## 6. Sécurité

### 6.1 Accès SSH
- **Clé ED25519 uniquement** — mot de passe SSH désactivé dès le premier boot (cloud-init)
- **Restriction par IP** — le firewall Hetzner n'autorise SSH que depuis `admin_ip` (variable Terraform)
- Aucun accès root par mot de passe sur aucune des 3 VMs

### 6.2 Isolation réseau
- Le **Control Plane** n'est jamais exposé sur Internet — accessible uniquement depuis `10.0.0.0/24`
- Le **LB** est le **seul point d'entrée public** (ports 80/443)
- PostgreSQL et Redis sont bindés sur le réseau Docker interne (pas exposés en dehors du CP)
- L'API FastAPI est bindée sur `10.0.0.20:8000` — inaccessible depuis l'IP publique du CP

### 6.3 Authentification
- JWT (HS512, expiry 30 min) pour les sessions utilisateur
- `X-API-Key` pour la communication machine-à-machine (nœud → API)
- L'API refuse de démarrer si `SECRET_KEY=change-me-in-production` en mode production

### 6.4 Chiffrement
| Couche | Algorithme |
|---|---|
| Tunnel VPN | ChaCha20-Poly1305 + Curve25519 (WireGuard) |
| HTTPS (LB) | TLS 1.3 via Certbot |
| Mots de passe | Argon2id |
| JWT | HMAC-SHA512 |

### 6.5 Kill Switch (nœud VPN)
Si le nœud perd contact avec l'API pendant plus de 5 minutes, `iptables` bloque tout le trafic pour éviter les fuites IP des utilisateurs connectés.

### 6.6 Secrets
- `terraform.tfvars` et `.env` exclus du dépôt Git (`.gitignore`)
- Les secrets de production sont passés via les variables Ansible (à versionner dans un vault en production)

---

*Document — Projet Infrastructure SecureNet — Déploiement VPN sur Hetzner Cloud*
