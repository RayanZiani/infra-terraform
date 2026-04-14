# Projet d'Infrastructure — Portail d'Accès Sécurisé (SecureNet)

> **Entreprise fictive :** SecureNet SAS  
> **Contexte :** Infrastructure de passerelle de services sécurisée déployée sur cloud  via IaC (Terraform + Ansible)

---

## 1. Scénario & Service Rendu

SecureNet SAS fournit une **plateforme d'accès sécurisé aux ressources internes** via un portail web authentifié. Elle a besoin d'une infrastructure :

- **Disponible** : accessible 24/7, un seul point de panne réseau doit être évité
- **Sécurisée** : aucune exposition directe des serveurs backend sur Internet, authentification centralisée
- **Administrable** : déployable en quelques commandes, reproductible à l'identique
- **Évolutive** : ajouter un serveur interne = ajouter une entrée au Dashboard

**Évolutions prévues :** supervision (Prometheus + Grafana), 2FA, audit logging, multi-région.

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
                    │  Dashboard & Portal (API)   │
                    │   VM cp — 10.0.0.20         │
                    │   Docker : FastAPI :8000    │
                    │            PostgreSQL :5432 │
                    │            Redis :6379      │
                    │   Firewall : 8000 réseau    │
                    │             privé seulement │
                    │             22 admin only   │
                    │                             │
                    │ • Dashboard : Vue des services
                    │ • Gestion des accès         │
                    │ • Authentification centralisée
                    │ • API REST pour services    │
                    └─────────────┬───────────────┘
                                  │
                    HTTP API (heartbeat / sync)
                    X-API-Key auth — réseau privé
                                  │
         ┌────────────────────────┴────────────────────────┐
         │                                                 │
         ▼                                                 ▼
┌─────────────────────┐                      ┌──────────────────┐
│  Internal File      │                      │  Internal Tools  │
│  Server / Storage   │                      │  Services        │
│ VM node-01          │                      │ VM node-02       │
│ 10.0.0.30           │                      │ 10.0.0.31        │
│ (Réseau privé)      │                      │ (Réseau privé)   │
│                     │                      │                  │
│ • File Server SMB   │                      │ • Application 1  │
│ • Backup Storage    │                      │ • Application 2  │
│ • Archive           │                      │ • Service privé  │
│ • Access control    │                      │ • Access control │
│                     │                      │                  │
└─────────────────────┘                      └──────────────────┘
```

### Réseaux

| Réseau | Plage IP | Usage |
|---|---|---|
| Public (Internet) | — | Accès aux utilisateurs finaux (HTTPS) |
| Privé Hetzner | `10.0.0.0/24` | Communication interne LB ↔ CP ↔ Nodes |
| SMB / File Server | `10.0.0.0/24` | Serveurs internes (réseau privé uniquement) |

### Flux et ports

| Source | Destination | Port | Protocole | Rôle |
|---|---|---|---|---|
| Internet | LB | 80, 443 | TCP | Portail web (HTTPS) |
| Admin | LB / CP / Node | 22 | TCP | SSH administrateur uniquement |
| LB | CP | 8000 | TCP | Reverse proxy → FastAPI / Dashboard |
| Node | CP | 8000 | TCP | Heartbeat, sync état services |
| CP / Users | Node | 445, 139 | TCP | SMB / File Server (accès contrôlé) |
| CP / Users | Node | 3389, 22 | TCP | Outils internes (RDP, SSH) |

---

## 3. Tableau des Choix Techniques

| Décision | Justification | Points d'attention |
|---|---|---|
| **Terraform (IaC)** | Infra reproductible en une commande. Le fichier `terraform.tfstate` est la source de vérité de l'état réel. Permet de versionner l'infra comme du code. | Ne pas committer `terraform.tfstate` ni `terraform.tfvars` (secrets). Ajouter au `.gitignore`. |
| **Hetzner Cloud** | Coût réduit (~5€/mois par VM), datacenter européen (conformité RGPD), API simple. Provider Terraform disponible. | Moins de services managés qu'AWS. Prévoir un backup de la base manuellement si pas de snapshot auto. |
| **3 VMs séparées** (LB + CP + Nodes) | Séparation des rôles : le LB est le seul point public, le CP expose le Dashboard sécurisé, les Nodes hébergent les ressources internes. | Latence réseau interne Hetzner : ~1ms → négligeable. |
| **Nginx comme reverse proxy** | Léger, fiable, gestion native des WebSockets, facile à intégrer avec Certbot (TLS). Authentification centralisée via CP. | Configuration `proxy_set_header` obligatoire pour les WebSocket et les en-têtes proxy. |
| **Ansible pour le provisioning** | Idempotent : réexécuter les playbooks ne casse rien. Chaque rôle est indépendant et testable. Pas d'agent à installer sur les VMs cibles. | Ordre d'exécution important : CP avant Nodes (healthcheck). |
| **Docker Compose en production** | Le Control Plane / Dashboard tourne dans 3 conteneurs (API + PostgreSQL + Redis). Isolation, rolling update simple. | L'API est bindée sur `10.0.0.20:8000` uniquement, jamais sur `0.0.0.0`. |
| **FastAPI (Python async)** | Framework asynchrone pour gérer N requêtes simultanées sans bloquer. Compatible `asyncpg` (PostgreSQL async natif). Dashboard intégré. | Refus de démarrer si `SECRET_KEY=change-me-in-production` en mode prod. |
| **SMB / File Server interne** | Accès sécurisé aux fichiers et services internes via le Portal. Intégration authentification centralisée. Pas d'accès direct depuis Internet. | Réseau privé uniquement. Firewall strict sur les ports SMB. |
| **Authentification centralisée** | Tous les accès (Dashboard, File Server, Services) passent par le CP. Logging centralisé, gestion des permissions. | Basée sur API tokens (X-API-Key) pour node-to-CP, JWT OAuth2 pour utilisateurs. |
| **Réseau privé Hetzner** | Tout le trafic interne (LB→CP, CP→Nodes) passe par un réseau 10.0.0.0/24 non routable depuis Internet. Double protection avec les firewalls. | Hetzner facture le trafic privé intra-datacenter à moindre coût que le trafic public. |
| **Cloud-init** | Permet de préparer les VMs dès le premier boot (désactivation mot de passe root, SSH hardened) avant même qu'Ansible intervienne. | Exécuté une seule fois. Les modifications post-boot sont gérées par Ansible. |
| **Clé SSH ED25519** | Plus courte, plus rapide et plus sécurisée que RSA 2048/4096. L'accès SSH root est limité à l'IP admin via firewall Hetzner. | Jamais de mot de passe SSH. `PasswordAuthentication no` dans `sshd_config`. |

---

## 4. Architecture du Dashboard

Le **Control Plane** expose une interface web et une API REST centralisée :

### Frontend (Vue.js)
```
/dashboard
├── Users → Voir la liste des utilisateurs, permissions
├── Services → État des services internes (File Server, App1, App2, etc.)
├── Audit Log → Historique des accès
└── Admin → Gestion des nœuds, tokens API
```

### Backend (FastAPI)
```
POST   /auth/login           → Authentification OAuth2
POST   /auth/logout          → Déconnexion
GET    /services             → Liste des services et leur état
GET    /services/{id}/proxy  → Proxy direct vers le service interne
POST   /access/grant         → Accorder l'accès à un utilisateur
DELETE /access/{id}          → Révoquer l'accès
GET    /nodes                → État de santé des nœuds (heartbeat)
GET    /audit-log            → Logs d'accès centralisés
```

### Authentification
- **OAuth2 + JWT** pour les utilisateurs (OIDC compatible, prêt pour Google/Azure integration)
- **API Keys** pour node-to-CP (heartbeat, sync)
- **2FA optionnel** (TOTP) pour les administrateurs

---

## 5. Commandes de Déploiement

```bash
# 1. Provisionner les VMs sur Hetzner
cd terraform
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
ansible-playbook -i inventory.ini playbooks/01-setup-lb.yml
ansible-playbook -i inventory.ini playbooks/02-setup-dashboard.yml
ansible-playbook -i inventory.ini playbooks/03-setup-node-fileserver.yml

# 4. Vérifier
ansible all -i inventory.ini -m ping
```

---

## 6. Validation & Tests

### Test 1 — Connectivité SSH (bastion)
```bash
ssh -i ~/.ssh/id_ed25519 root@<LB_IP>    # ✅ Doit fonctionner
ssh -i ~/.ssh/id_ed25519 root@<CP_IP>    # ✅ Doit fonctionner (si admin_ip correct)
```

### Test 2 — LB répond sur HTTPS
```bash
curl -v https://<LB_IP>/
# Résultat attendu : 200 OK — page d'accueil Dashboard
```

### Test 3 — Dashboard accessible via le LB
```bash
curl https://<LB_IP>/dashboard
# Résultat attendu : redirection vers /login avec authentification
```

### Test 4 — Dashboard NON accessible directement depuis Internet
```bash
curl http://<CP_IP>:8000/
# Résultat attendu : timeout (firewall bloque)
```

### Test 5 — File Server accessible depuis le CP uniquement
```bash
ssh root@<FILESERVER_IP> 'smbstatus'
# Résultat attendu : interface SMB active et configurée
```

### Test 6 — Heartbeat nœud → Dashboard
```bash
# Depuis le nœud File Server :
curl -H "X-API-Key: <node_api_key>" http://10.0.0.20:8000/nodes/health
# Résultat attendu : JSON avec l'état du nœud (uptime, services, etc.)
```

### Test 7 — Isolation réseau (sécurité)
```bash
# Depuis une machine externe, tenter d'atteindre directement PostgreSQL
nc -zv <CP_IP> 5432
# Résultat attendu : Connection refused / timeout (firewall bloque)
```

---

## 7. Sécurité

### 7.1 Accès SSH
- **Clé ED25519 uniquement** — mot de passe SSH désactivé dès le premier boot (cloud-init)
- **Restriction par IP** — le firewall Hetzner n'autorise SSH que depuis `admin_ip` (variable Terraform)
- Aucun accès root par mot de passe sur aucune des 3 VMs

### 7.2 Isolation réseau
- Le **Dashboard / Control Plane** n'est jamais exposé sur Internet — accessible uniquement depuis `10.0.0.0/24`
- Le **LB** est le **seul point d'entrée public** (ports 80/443, HTTPS obligatoire)
- PostgreSQL et Redis sont bindés sur le réseau Docker interne (pas exposés en dehors du CP)
- L'API FastAPI est bindée sur `10.0.0.20:8000` — inaccessible depuis l'IP publique du CP

### 7.3 Authentification
- JWT (HS512, expiry 30 min) pour les sessions utilisateur
- `X-API-Key` pour la communication machine-à-machine (nœud → Dashboard)
- L'API refuse de démarrer si `SECRET_KEY=change-me-in-production` en mode production
- Toutes les authentifications sont loggées dans l'audit trail

### 7.4 Chiffrement
| Couche | Algorithme |
|---|---|
| HTTPS (LB) | TLS 1.3 via Certbot + renewal automatique |
| Mots de passe | Argon2id |
| JWT | HMAC-SHA512 |
| Données sensibles (DB) | AES-256-GCM (optionnel, pour production) |

### 7.5 Contrôle d'accès au File Server
- Authentification centralisée via le CP
- Contrôle d'accès granulaire (par utilisateur / groupe)
- Audit logging de tous les accès aux fichiers
- Firewall strict : port SMB (445) uniquement accessible depuis le CP / nœuds autorisés

### 7.6 Secrets
- `terraform.tfvars` et `.env` exclus du dépôt Git (`.gitignore`)
- Les secrets de production sont passés via les variables Ansible (à versionner dans un vault en production)

---

*Document — Projet Infrastructure SecureNet — Portail d'Accès Sécurisé sur Hetzner Cloud*