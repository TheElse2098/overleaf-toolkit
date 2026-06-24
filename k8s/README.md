# Overleaf Artishow sur Kubernetes (microservices)

Ces manifestes remplacent `bin/up` du Toolkit : ils font tourner Overleaf en
**microservices** (un Deployment + Service par composant) sur une **VM**.
Kubernetes joue le rôle d'orchestrateur à la place de docker-compose.

> ⚠️ C'est un **point de départ structuré**, pas un déploiement clé-en-main.
> Lis la section « Points à valider » : certains éléments dépendent de ton
> environnement (provisioner RWX, images par service, TeXLive de clsi).

## Architecture

| Tier | Composants |
|------|-----------|
| Données | `mongo` (StatefulSet, replica set `overleaf`), `redis` |
| Backend | `filestore`, `docstore`, `history-v1`, `document-updater`, `project-history`, `clsi`, `chat`, `notifications`, `references` |
| Frontaux | `real-time`, `web`, `git` |
| Réseau | `proxy` (nginx, **hostPort 8080**) : `/` → web, `/socket.io` → real-time, PDF/sorties depuis le volume. Alternative : `Ingress`. |
| Stockage | PVC RWX `overleaf-data` partagé par **web + git + clsi + proxy** ; PVC mongo/redis |

Le câblage inter-services se fait via le ConfigMap `overleaf-hosts` (les `*_HOST`
pointent sur les noms de Service k8s au lieu de `127.0.0.1`).

## Prérequis sur la VM

1. **Un cluster** : [k3s](https://k3s.io) recommandé pour une VM (`curl -sfL https://get.k3s.io | sh -`).
   k3s fournit déjà `local-path` (RWO) pour les volumes mongo/redis — rien à faire.
2. **Stockage RWX partagé** via NFS natif (volume `nfs:` in-tree, **aucun provisioner**) :
   ```bash
   sudo apt-get install -y nfs-kernel-server nfs-common
   sudo mkdir -p /srv/overleaf-data && sudo chown nobody:nogroup /srv/overleaf-data
   echo "/srv/overleaf-data *(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports
   sudo exportfs -ra && sudo systemctl enable --now nfs-kernel-server
   ```
   Puis renseigne `<IP_DE_LA_VM>` dans [`03-storage.yaml`](03-storage.yaml).
3. **Point d'entrée** : par défaut le pod `proxy` ([`31-proxy.yaml`](31-proxy.yaml)) expose
   la **sortie web sur le port 8080 de la VM** (`hostPort: 8080`). Rien d'autre à installer.
   - _Alternative_ : `ingress-nginx` + [`30-ingress.yaml`](30-ingress.yaml) si tu préfères un
     contrôleur ingress. **N'utilise qu'un seul des deux** (sinon conflit sur le 8080).
4. **Les images par service** publiées (voir ci-dessous).

## Flux réseau (entrée libre, sortie imposée sur 8080)

- **Sortie web d'Overleaf = port 8080 de la VM** (imposé). C'est le pod `proxy`
  (`hostPort: 8080`) qui réunit web + websockets + fichiers PDF en un seul flux.
- **Entrée = n'importe quel port.** Ton proxy externe (devant la VM) peut écouter
  sur 80/443/autre et **forwarder vers le 8080**. En interne, les services écoutent
  sur leurs propres ports (web 3000, real-time 3026, …) : sans importance, ils ne
  sont pas exposés directement.
- Règle `OVERLEAF_SITE_URL` ([`01-config.yaml`](01-config.yaml)) sur l'**URL publique**
  servie par ton proxy externe (pas forcément `:8080`).

## Images par service (à construire/publier)

Les Deployments référencent `ghcr.io/theelse2098/overleaf-artishow-<svc>:latest`.
Ces images n'existent pas encore : aujourd'hui la CI ne build que le monolithe.

Construire manuellement (depuis la racine du repo overleaf-artishow) :
```bash
for svc in web git clsi docstore filestore document-updater \
           project-history history-v1 chat notifications references real-time; do
  docker build -f services/$svc/Dockerfile -t ghcr.io/theelse2098/overleaf-artishow-$svc:latest .
  docker push ghcr.io/theelse2098/overleaf-artishow-$svc:latest
done
```
À terme : faire produire ces images par la CI ([.github/workflows/docker-publish.yml](../../.github/workflows/docker-publish.yml)).

Si ton cluster a besoin d'un identifiant pour ghcr, crée un `imagePullSecret` et
référence-le dans les pods (non inclus ici).

## Déploiement

```bash
# 1. Secrets : génère-les depuis la config du Toolkit (bin/init au préalable)
cd ..            # dossier overleaf-toolkit
bin/init         # génère config/variables.env (OVERLEAF_INVITE_TOKEN_SECRET, etc.)
cd k8s
./gen-secrets.sh > 02-secrets.yaml      # remplit le Secret automatiquement

# 2. Règle 01-config.yaml : OVERLEAF_SITE_URL = http://<IP_de_ta_VM>
# 3. Règle 03-storage.yaml : storageClassName de ton provisioner RWX

# 4. Applique tout dans l'ordre (namespace → données → services → proxy)
./apply-all.sh

# 5. Suivre
kubectl -n overleaf get pods -w
kubectl -n overleaf logs -f deploy/web
```

> `apply-all.sh` applique les manifestes dans le bon ordre ; le Job Mongo initialise
> le replica set tout seul. Le proxy expose la sortie web sur le **port 8080** de la VM.

Accès : la sortie web est sur **`http://<IP_de_la_VM>:8080`** (que ton proxy externe
consomme). En test rapide sans proxy externe :
```bash
curl http://<IP_de_la_VM>:8080/status        # depuis la VM
# ou, sans hostPort :
kubectl -n overleaf port-forward svc/proxy 8080:8080   # http://localhost:8080
```

## Vérification

1. `kubectl -n overleaf get pods` → tout `Running`/`Ready`.
2. Mongo : `kubectl -n overleaf exec mongo-0 -- mongosh --quiet --eval 'rs.status().ok'` = `1`.
3. Web répond : `curl` sur `/status` (via port-forward) → `200`.
4. Création de compte + login.
5. **Compilation** d'un `.tex` → PDF (valide clsi + volume partagé).
6. **Intégration git** : import d'un dépôt, création de branche, commit/push, `addAll`
   (valide web ↔ git ↔ clsi via le volume RWX et les Services).
7. `kubectl -n overleaf delete pod -l app=web` → auto-réparation + données persistées.

## Points à valider / limites connues (honnêteté)

- **Images par service** : elles lisent les `settings.defaults` natifs de chaque
  service (variables `*_HOST`, `MONGO_CONNECTION_STRING`, `REDIS_HOST`…). Certains
  réglages de confort `OVERLEAF_*` du monolithe ne s'appliquent **pas** à ces images ;
  à compléter au cas par cas pour `web` (selon les logs de démarrage).
- **clsi + TeXLive** : la CI build clsi avec la cible `with-texlive` (image lourde,
  multi-Go) pour que la compilation fonctionne. Build plus long ; si la CI sature,
  on peut revenir à la cible légère `app` (sans compilation).
- **references** : retiré (CI + manifestes) car son Dockerfile est incompatible avec
  ce monorepo. À réintégrer après régénération de son Dockerfile.
- **history-v1** : configuré par fichiers JSON (`node-config`), pas par les mêmes
  variables d'env ; valider son adresse d'écoute et son accès mongo/redis.
- **RWX obligatoire** : sans provisioner ReadWriteMany, web/git/clsi ne partagent
  pas le disque → l'intégration git et la compilation cassent.
- **Secrets** : `GIT_SERVICE_SECRET` doit être identique côté web et côté git.
- **replicas: 1** partout pour démarrer. Le scaling viendra après le redesign HTTP
  (cf. plan) qui supprime le couplage par système de fichiers.
