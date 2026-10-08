#!/bin/sh
# redeploy.sh GENERICO per i progetti Docker sul NAS (/Volume1/public/Docker/<Progetto>/).
# Non va ricreato per ogni progetto: nas-docker-redeploy.ps1 lo copia da solo
# nella cartella remota come redeploy.sh quando il progetto non ne ha uno suo.
# Se un progetto ha esigenze particolari, basta mettere un redeploy.sh nel suo
# LocalPath: quello ha la precedenza su questo.
#
# Cosa fa: si sposta nella propria cartella (quella del progetto), trova docker
# e il comando compose disponibile, poi esegue down -> build -> up -d.
#
# Variabili opzionali (es. `COMPOSE_FILE=prod.yml sh redeploy.sh`):
#   COMPOSE_FILE   file compose da usare (default: quello standard nella cartella)
#   NO_BUILD=1     salta la fase di build (progetti solo-immagine)
#   PULL=1         esegue anche `pull` delle immagini prima della build
#   PRUNE=1        rimuove le immagini dangling a fine deploy

set -eu

cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"

# docker/docker-compose spesso non sono nel PATH di una sessione SSH non
# interattiva sul NAS: aggiunge i percorsi comuni.
PATH="$PATH:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/bin"
for d in /Volume1/@apps/*/bin /Volume1/@apps/*/*/bin /volume1/@appstore/*/usr/bin; do
    if [ -d "$d" ]; then PATH="$PATH:$d"; fi
done
export PATH

if ! command -v docker >/dev/null 2>&1; then
    echo "ERRORE: docker non trovato nel PATH ($PATH)" >&2
    exit 1
fi

if docker compose version >/dev/null 2>&1; then
    compose() { docker compose "$@"; }
elif command -v docker-compose >/dev/null 2>&1; then
    compose() { docker-compose "$@"; }
else
    echo "ERRORE: ne' 'docker compose' ne' 'docker-compose' disponibili" >&2
    exit 1
fi

if [ -z "${COMPOSE_FILE:-}" ] && ! ls docker-compose.yml docker-compose.yaml compose.yml compose.yaml >/dev/null 2>&1; then
    echo "ERRORE: nessun file compose trovato in $PROJECT_DIR" >&2
    exit 1
fi

echo ">> [$PROJECT_DIR] down"
compose down --remove-orphans

if [ "${PULL:-0}" = "1" ]; then
    echo ">> pull"
    compose pull --ignore-pull-failures
fi

if [ "${NO_BUILD:-0}" != "1" ]; then
    echo ">> build"
    compose build
fi

echo ">> up -d"
compose up -d --remove-orphans

if [ "${PRUNE:-0}" = "1" ]; then
    echo ">> prune immagini dangling"
    docker image prune -f
fi

compose ps
echo ">> redeploy completato: $PROJECT_DIR"
