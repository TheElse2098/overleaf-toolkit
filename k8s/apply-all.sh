#!/usr/bin/env bash
# Applique tous les manifestes Overleaf dans l'ordre, sur le cluster courant.
# Usage : ./apply-all.sh   (depuis le dossier overleaf-toolkit/k8s)
set -euo pipefail
cd "$(dirname "$0")"

ORDER=(
  00-namespace
  01-config
  02-secrets
  03-storage
  10-mongo      # le Job initialise le replica set automatiquement
  11-redis
  20-backend
  21-frontend
  31-proxy      # sortie web sur le port 8080 de la VM
  # 30-ingress  # alternative au proxy (ne pas utiliser les deux)
)

for f in "${ORDER[@]}"; do
  echo ">>> kubectl apply -f ${f}.yaml"
  kubectl apply -f "${f}.yaml"
done

echo
echo "Déployé. Suivi des pods :"
echo "  kubectl -n overleaf get pods -w"
echo "Accès web : http://<IP_de_la_VM>:8080"
