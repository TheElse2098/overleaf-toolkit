#!/usr/bin/env bash
# Génère le Secret k8s "overleaf-secrets" à partir de la config du Toolkit.
# - récupère OVERLEAF_INVITE_TOKEN_SECRET depuis ../config/variables.env (bin/init)
# - génère des valeurs aléatoires pour les secrets manquants
# - le secret web<->git (GIT_SERVICE_SECRET) est aligné sur WEB_API_PASSWORD
#
# Usage : ./gen-secrets.sh | kubectl apply -f -
#   (ou  ./gen-secrets.sh > 02-secrets.yaml  pour relire avant d'appliquer)
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE="../config/variables.env"

# Lit une clé dans variables.env (ignore les lignes commentées), sinon valeur vide
read_env() {
  [ -f "$ENV_FILE" ] || { echo ""; return; }
  grep -E "^[[:space:]]*$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' || echo ""
}

rand() { openssl rand -hex 24; }

INVITE=$(read_env OVERLEAF_INVITE_TOKEN_SECRET); INVITE=${INVITE:-$(rand)}
SESSION=$(read_env OVERLEAF_SESSION_SECRET);     SESSION=${SESSION:-$(rand)}
WEB_API_USER=$(read_env WEB_API_USER);           WEB_API_USER=${WEB_API_USER:-overleaf}
WEB_API_PASS=$(read_env WEB_API_PASSWORD);       WEB_API_PASS=${WEB_API_PASS:-$(rand)}

cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: overleaf-secrets
  namespace: overleaf
type: Opaque
stringData:
  OVERLEAF_SESSION_SECRET: "${SESSION}"
  OVERLEAF_INVITE_TOKEN_SECRET: "${INVITE}"
  WEB_API_USER: "${WEB_API_USER}"
  WEB_API_PASSWORD: "${WEB_API_PASS}"
  GIT_SERVICE_SECRET: "${WEB_API_PASS}"
YAML
