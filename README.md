# Projet Infrastructure : SecureNet

Membres du groupe : Elyès & Rayan
Sujet : Déploiement d'une infrastructure réseau isolée et d'un portail de supervision.

---

## 1. Proposition de service

Pour ce projet, nous avons simulé le besoin d'une entreprise souhaitant superviser ses serveurs internes (comme des serveurs de stockage ou de backup) sans jamais les exposer directement sur Internet. 

Plutôt que de monter un tunnel VPN complexe et lourd à maintenir, nous avons opté pour une approche "Portail Centralisé" (Dashboard) :
- Les serveurs internes (Nodes) remontent leur état de santé en interne.
- Un Control Plane centralise ces données.
- Un Load Balancer sert d'unique point d'entrée sécurisé pour les administrateurs qui veulent consulter le Dashboard.

## 2. Schéma Technique (LLD)

                        INTERNET
                           │
                    ┌──────▼──────┐
                    │  secure-lb  │  <-- Load Balancer (Nginx)
                    │  IP Publique│      Ports ouverts : 80, 443
                    └──────┬──────┘
                           │
                           │ Reverse Proxy (Réseau privé 10.0.0.0/24)
                           │
                    ┌──────▼──────┐
                    │  secure-cp  │  <-- Control Plane (FastAPI)
                    │  10.0.0.20  │      Héberge le Dashboard
                    └──────┬──────┘
                           │
                           │ API POST /heartbeat (Réseau privé)
                           │
                    ┌──────┴──────┐
                    │ secure-node │  <-- Serveur Interne (Agent)
                    │  10.0.0.30  │      Envoie son statut toutes les 10s
                    └─────────────┘

* Note : L'accès SSH se fait uniquement via la machine "secure-admin" (Bastion).

## 3. Choix Techniques

Voici les décisions que nous avons prises pour répondre aux enjeux de l'infrastructure.

| Technologie / Outil | Justification | Points d'attention |

| Terraform (IaC) | Permet d'automatiser et de reproduire la création des 4 VMs et du réseau privé. On gagne un temps fou si on doit tout recréer. | Bien exclure le fichier terraform.tfstate du dépôt Git pour ne pas fuiter d'infos sensibles. |

| LXD / Hetzner | Conteneurs système/VMs très légers, parfaits pour simuler un vrai datacenter à moindre coût. | Gérer la configuration réseau pour s'assurer que les IPs privées sont bien fixes (10.0.0.x). |

| Nginx (Load Balancer) | Très performant pour faire du Reverse Proxy. C'est le seul composant qui écoute sur Internet. | Configurer correctement le proxy_pass vers l'IP 10.0.0.20:8000 du Control Plane. |

| Réseau Privé (10.0.0.0/24) | Cœur de notre sécurité. Les nœuds et le Control Plane n'ont pas d'IP publique, ils sont invisibles de l'extérieur. | S'assurer que le Load Balancer est bien connecté aux deux réseaux (public + privé). |

| Clés SSH (ED25519) | Plus sécurisé que le RSA classique. Désactivation totale de l'authentification par mot de passe. | Il faut obligatoirement passer par la VM d'administration (Rebond/Bastion) pour accéder aux machines. |

| Python (FastAPI + Requests) | Très rapide à mettre en place pour notre "Proof of Concept". Permet de créer un serveur web léger et un agent de monitoring. | Gestion des dépendances (pip) directement sur les VMs Ubuntu. |

## 4. Sécurité

La sécurité a été pensée "By Design" dès le départ de l'atelier :
1. Isolation réseau : Impossible d'accéder au port 8000 (le Dashboard) depuis Internet. Il faut obligatoirement passer par Nginx.
2. Architecture Bastion : L'accès SSH aux serveurs internes est bloqué depuis l'extérieur. L'administrateur doit d'abord se connecter à la VM secure-admin (avec sa clé privée), puis rebondir vers les autres machines.
3. Cloud-init : Utilisé avec Terraform pour injecter les clés publiques dès la création des VMs et verrouiller le compte root immédiatement.

## 5. Validation et Tests (Proof of Concept)

Pour valider le fonctionnement de l'infrastructure, nous avons effectué cette série de tests :

* Test de l'isolation (Échec attendu) :
  Tentative d'accès direct à l'IP 10.0.0.20:8000 depuis l'extérieur.
  Résultat : Connection refused. Le réseau privé bloque bien le trafic public.

* Test du Reverse Proxy (Nginx) :
  Requête curl -I http://<IP_LB> avant l'allumage du backend.
  Résultat : Erreur 502 Bad Gateway. Prouve que Nginx cherche bien à contacter le Control Plane.

* Test applicatif global :
  Lancement de l'agent sur le Node, puis requête HTTP sur l'IP publique du Load Balancer.
  Résultat : Affichage de la page HTML "SecureNet Dashboard" avec les informations du noeud (Nom, Statut Online) mises à jour en temps réel. La chaîne Node -> Control Plane -> Load Balancer -> Client est validée.