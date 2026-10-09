#!/bin/sh
# =============================================================================
# redeploy.sh  -  redeploy generico e project-agnostic per progetti Docker
#                 Compose sul NAS (TerraMaster TOS 6.0 / dash / POSIX sh).
#
# Copiarlo INVARIATO nella cartella di un progetto compose. Il comportamento
# specifico del progetto va messo in ./redeploy.conf (vedi redeploy.conf.example)
# e/o negli hook opzionali, MAI dentro questo script.
#
# USO:
#   ./redeploy.sh [DIR] [--dry-run] [--down|--no-down] [--build-only|--up]
#                 [--no-logs] [--no-health] [-h]
#     DIR          cartella progetto (default: cartella dello script)
#     --dry-run    stampa i comandi muta-stato (prefisso "+ ") senza eseguirli
#     --down       esegue "down" prima di "up" (serve se cambiano reti/subnet)
#     --no-down    forza DOWN_FIRST=0 (ignora la conf)
#     --build-only forza solo build (niente up), con hint "run manuale"
#     --up         forza il deploy completo (BUILD_ONLY=0, ignora la conf)
#     --no-logs    non stampa i log finali
#     --no-health  salta l'health check (equivale a HEALTH_WAIT=0)
#     -h|--help    questo aiuto
#
# redeploy.conf (tutte opzionali):
#   COMPOSE_FILE  percorso compose (default: autodetect)
#   PROFILES      profili compose, separati da spazio (default: vuoto)
#   BUILD_ONLY    0/1 (default: auto = 1 se tutti i servizi sono gated e
#                 PROFILES e' vuoto)
#   DOWN_FIRST    0/1 (default 0)
#   PULL          0/1 pull delle immagini image-only (default 1)
#   LOG_TAIL      righe di log finali (default 30)
#   HEALTH_WAIT   budget secondi dell'health-check (polling ogni 3s),
#                 0=disabilita (default 45)
#   MKDIR_BINDS   0/1 crea le bind-dir mancanti interne al progetto (default 1)
#   EXTRA_DIRS    dir extra da creare (spazio-separate; assolute o relative)
#
# Hook opzionali (sorgenti con "." : vedono dc(), $PROJECT, $COMPOSE_FILE,
#   $PROJECT_DIR); un fallimento aborta tutto:
#   redeploy.pre.sh         prima di pull/build (migrazioni, check prerequisiti)
#   redeploy.post-build.sh  dopo build, prima di up (seed dati dall'immagine)
#   redeploy.post.sh        dopo up
#
# ATTENZIONE: questo script NON passa MAI -p e NON usa MAI --remove-orphans.
# Piu' progetti il cui compose sta nella stessa dir (es. docker/) condividono
# nome-progetto e rete: -p o --remove-orphans cancellerebbero i container
# dell'altro bot. Per lo stesso motivo --down viene RIFIUTATO se la rete del
# progetto ha container di un altro config_files (bot gemello): un down
# toglierebbe la rete anche all'altro (es. crypto/equity, entrambi progetto
# "docker").
#
# NON gestito: progetti senza compose (plain "docker run") -> tenere il loro
# script o migrarli a compose.
# =============================================================================

set -eu
set -f  # noglob: il '*' dei profili non deve essere espanso dalla shell

export PATH=/Volume1/@apps/DockerEngine/dockerd/bin:$PATH
export DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0

TAB=$(printf '\t')

# stampa il blocco di commento d'intestazione (fino alla prima riga non-#)
usage() { awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,"");print}' "$0"; }

# --- argomenti e flag --------------------------------------------------------
DRY_RUN=0; NO_LOGS=0; PROJECT_DIR=""
flag_down=0; flag_no_down=0; flag_build_only=0; flag_up=0; flag_no_health=0
for a in "$@"; do
  case "$a" in
    --dry-run)    DRY_RUN=1 ;;
    --down)       flag_down=1 ;;
    --no-down)    flag_no_down=1 ;;
    --build-only) flag_build_only=1 ;;
    --up)         flag_up=1 ;;
    --no-logs)    NO_LOGS=1 ;;
    --no-health)  flag_no_health=1 ;;
    -h|--help)    usage; exit 0 ;;
    -*)           echo "ERRORE: flag sconosciuto: $a" >&2; exit 2 ;;
    *)            if [ -z "$PROJECT_DIR" ]; then PROJECT_DIR="$a";
                  else echo "ERRORE: troppi argomenti" >&2; exit 2; fi ;;
  esac
done

[ -n "$PROJECT_DIR" ] || PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"
PROJECT_DIR="$(pwd)"

# --- default + conf ----------------------------------------------------------
COMPOSE_FILE=""; PROFILES=""; BUILD_ONLY=""; DOWN_FIRST=0; PULL=1
LOG_TAIL=30; HEALTH_WAIT=45; MKDIR_BINDS=1; EXTRA_DIRS=""
[ -f ./redeploy.conf ] && . ./redeploy.conf

# i flag hanno la precedenza sulla conf
[ "$flag_down" = 1 ] && DOWN_FIRST=1
[ "$flag_no_down" = 1 ] && DOWN_FIRST=0
[ "$flag_build_only" = 1 ] && BUILD_ONLY=1
[ "$flag_up" = 1 ] && BUILD_ONLY=0
[ "$flag_no_health" = 1 ] && HEALTH_WAIT=0

PROFILE_ARGS=""
for p in $PROFILES; do PROFILE_ARGS="$PROFILE_ARGS --profile $p"; done

# --- helper ------------------------------------------------------------------
run() {               # esegue un comando muta-stato (o lo stampa in dry-run)
  echo "+ $*"
  [ "$DRY_RUN" = 1 ] && return 0
  "$@"
}
dc() { docker-compose -f "$COMPOSE_FILE" $PROFILE_ARGS "$@"; }  # read-only usano questo
run_dc() {            # comando compose muta-stato, echo espanso + dry-run
  echo "+ docker-compose -f $COMPOSE_FILE $PROFILE_ARGS $*"
  [ "$DRY_RUN" = 1 ] && return 0
  docker-compose -f "$COMPOSE_FILE" $PROFILE_ARGS "$@"
}
dc_config() { docker-compose -f "$COMPOSE_FILE" --profile '*' config; }

run_hook() {
  h="$1"
  [ -f "$h" ] || return 0
  if [ "$DRY_RUN" = 1 ]; then echo "+ (hook) . $h"; return 0; fi
  echo ">> hook: $h"
  ( . "$h" )
}

ERRF=$(mktemp)
HWDIR=$(mktemp -d)
trap 'rm -f "$ERRF"; rm -rf "$HWDIR"' EXIT INT TERM

# --- 4. autodetect compose file ----------------------------------------------
CANDS="docker-compose.yml docker-compose.yaml compose.yml compose.yaml \
docker/docker-compose.yml docker/docker-compose.yaml docker/compose.yml docker/compose.yaml"

if [ -n "$COMPOSE_FILE" ]; then
  [ -f "$COMPOSE_FILE" ] || { echo "ERRORE: COMPOSE_FILE non esiste: $COMPOSE_FILE" >&2; exit 1; }
else
  found=""
  for c in $CANDS; do [ -f "$c" ] && found="$found $c"; done
  found=${found# }
  set -- $found
  if [ "$#" -eq 0 ]; then
    echo "ERRORE: nessun compose file trovato; questo script gestisce solo progetti compose." >&2
    exit 1
  elif [ "$#" -eq 1 ]; then
    COMPOSE_FILE="$1"
  else
    # >1 candidato: disambigua con i container esistenti
    live=$(docker ps -a --format '{{.Label "com.docker.compose.project.config_files"}}' 2>/dev/null || true)
    matches=""
    for c in $found; do
      if printf '%s\n' "$live" | grep -Fq "$PROJECT_DIR/$c"; then matches="$matches $c"; fi
    done
    matches=${matches# }
    set -- $matches
    if [ "$#" -eq 1 ]; then
      COMPOSE_FILE="$1"
    else
      echo "ERRORE: piu' compose file ($found); imposta COMPOSE_FILE in redeploy.conf" >&2
      echo "        (al primo deploy la disambiguazione automatica non e' possibile)." >&2
      exit 1
    fi
  fi
fi
echo ">> compose file: $COMPOSE_FILE"

# percorso assoluto del compose, come lo scrive compose nel label config_files
case "$COMPOSE_FILE" in
  /*) EXPECTED_CF="$COMPOSE_FILE" ;;
  *)  EXPECTED_CF="$PROJECT_DIR/$COMPOSE_FILE" ;;
esac

# --- 5. parse della config (con profili gated visibili) ----------------------
PYPARSE='import sys, yaml
d = yaml.safe_load(sys.stdin) or {}
print("PROJECT\t%s" % (d.get("name") or ""))
for k, v in (d.get("networks") or {}).items():
    v = v or {}
    if v.get("external"):
        print("EXTNET\t%s" % (v.get("name") or k))
for name, s in (d.get("services") or {}).items():
    s = s or {}
    kind = "build" if s.get("build") is not None else "image"
    profs = s.get("profiles") or []
    gated = "1" if profs else "0"
    cn = s.get("container_name") or "-"
    print("SVC\t%s\t%s\t%s\t%s\t%s" % (name, kind, gated, cn, ",".join(profs) or "-"))
    for vol in (s.get("volumes") or []):
        if isinstance(vol, dict) and vol.get("type") == "bind" and vol.get("source"):
            print("BIND\t%s" % vol["source"])
'

if ! CONFIG_YAML=$(dc_config 2>"$ERRF"); then
  echo "ERRORE: 'docker-compose config' fallito (variabili .env mancanti o errore compose):" >&2
  cat "$ERRF" >&2; exit 1
fi
if ! PARSED=$(printf '%s\n' "$CONFIG_YAML" | /usr/bin/python3 -I -c "$PYPARSE" 2>"$ERRF"); then
  echo "ERRORE: parsing della config YAML fallito:" >&2
  cat "$ERRF" >&2; exit 1
fi

PROJECT=$(printf '%s\n' "$PARSED" | awk -F"$TAB" '$1=="PROJECT"{print $2}')
[ -n "$PROJECT" ] || { echo "ERRORE: nome progetto non determinato." >&2; exit 1; }
echo ">> progetto: $PROJECT"

SVC_TOTAL=$(printf '%s\n' "$PARSED" | awk -F"$TAB" '$1=="SVC"' | wc -l | tr -d ' ')
SVC_GATED=$(printf '%s\n' "$PARSED" | awk -F"$TAB" '$1=="SVC" && $4=="1"' | wc -l | tr -d ' ')
HAS_BUILD=$(printf '%s\n' "$PARSED" | awk -F"$TAB" '$1=="SVC" && $3=="build"' | head -n1)
HAS_IMAGE=$(printf '%s\n' "$PARSED" | awk -F"$TAB" '$1=="SVC" && $3=="image"' | head -n1)

# --- 6. BUILD_ONLY auto ------------------------------------------------------
if [ -z "$BUILD_ONLY" ]; then
  if [ "$SVC_TOTAL" -gt 0 ] && [ "$SVC_GATED" = "$SVC_TOTAL" ] && [ -z "$PROFILES" ]; then
    BUILD_ONLY=1
  else
    BUILD_ONLY=0
  fi
fi

# --- 7a. conflitti container_name -------------------------------------------
while IFS="$TAB" read -r _ name kind gated cname profs; do
  [ "$cname" = "-" ] || [ -z "$cname" ] && continue
  if docker inspect "$cname" >/dev/null 2>&1; then
    owner=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$cname" 2>/dev/null || true)
    if [ "$owner" != "$PROJECT" ]; then
      echo "ERRORE: il container '$cname' esiste gia' e NON appartiene al progetto '$PROJECT'" >&2
      echo "        (owner compose: '${owner:-<nessuno: creato con docker run>}'). Nessuna modifica." >&2
      exit 1
    fi
  fi
done <<EOF
$(printf '%s\n' "$PARSED" | grep '^SVC' || true)
EOF

# --- 7b. reti esterne --------------------------------------------------------
while IFS="$TAB" read -r _ net; do
  [ -n "$net" ] || continue
  docker network inspect "$net" >/dev/null 2>&1 || run docker network create "$net"
done <<EOF
$(printf '%s\n' "$PARSED" | grep '^EXTNET' || true)
EOF

# --- 7c. bind dir + EXTRA_DIRS ----------------------------------------------
if [ "$MKDIR_BINDS" = 1 ]; then
  while IFS="$TAB" read -r _ src; do
    [ -n "$src" ] || continue
    [ -e "$src" ] && continue
    case "$src" in
      "$PROJECT_DIR"/*)
        base=$(basename "$src")
        case "$base" in
          *.*) echo "WARNING: bind mancante (sembra un file), non creato: $src" ;;
          *)   run mkdir -p "$src" ;;
        esac ;;
      *) echo "WARNING: bind esterno al progetto mancante: $src" ;;
    esac
  done <<EOF
$(printf '%s\n' "$PARSED" | grep '^BIND' || true)
EOF
fi
for d in $EXTRA_DIRS; do
  case "$d" in /*) t="$d" ;; *) t="$PROJECT_DIR/$d" ;; esac
  [ -d "$t" ] || run mkdir -p "$t"
done

# --- 7d. sicurezza --down su progetto condiviso -----------------------------
# Se e' richiesto il down ma la rete del progetto ha container di un ALTRO
# config_files (bot gemello), il down toglierebbe la rete anche a lui: rifiuta.
if [ "$DOWN_FIRST" = 1 ]; then
  foreign=""
  for net in $(docker network ls --filter "label=com.docker.compose.project=$PROJECT" -q 2>/dev/null); do
    for c in $(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$net" 2>/dev/null); do
      cf=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$c" 2>/dev/null || true)
      [ -n "$cf" ] || continue
      if ! printf '%s\n' "$cf" | grep -Fq "$EXPECTED_CF"; then
        case " $foreign " in *" $c "*) : ;; *) foreign="$foreign $c" ;; esac
      fi
    done
  done
  if [ -n "$foreign" ]; then
    echo "ERRORE: --down rifiutato: la rete del progetto '$PROJECT' ha container di" >&2
    echo "        un altro config_files (bot gemello):$foreign" >&2
    echo "        Un down toglierebbe la rete anche a loro. Rilancia senza --down." >&2
    exit 1
  fi
fi

# --- 8. hook pre -------------------------------------------------------------
run_hook ./redeploy.pre.sh

# --- 6/9. build-only: build e stop ------------------------------------------
if [ "$BUILD_ONLY" = 1 ]; then
  if [ -n "$HAS_BUILD" ]; then
    run docker-compose -f "$COMPOSE_FILE" --profile '*' build
  fi
  printf '%s\n' "$PARSED" | awk -F"$TAB" '$1=="SVC" && $4=="1"{p=$6; sub(/,.*/,"",p); print p"\t"$2}' \
    | while IFS="$TAB" read -r prof svc; do
        [ "$prof" = "-" ] && prof="<profilo>"
        echo "Run manuale: docker-compose --profile $prof run --rm $svc"
      done
  echo "OK: build-only completato."
  exit 0
fi

# --- 9. pull (image-only) + build (buildable) BEFORE down --------------------
if [ "$PULL" = 1 ] && [ -n "$HAS_IMAGE" ]; then
  run_dc pull --ignore-buildable
fi
if [ -n "$HAS_BUILD" ]; then
  run_dc build
fi

# --- 10. hook post-build -----------------------------------------------------
run_hook ./redeploy.post-build.sh

# --- 11. down (opzionale) + up ----------------------------------------------
if [ "$DOWN_FIRST" = 1 ]; then
  run_dc down || true
fi
run_dc up -d

# --- 12. hook post -----------------------------------------------------------
run_hook ./redeploy.post.sh

# --- 13. ps + log ------------------------------------------------------------
dc ps || true
if [ "$NO_LOGS" != 1 ]; then
  echo "--- Log ultimi $LOG_TAIL righe ---"
  dc logs --tail "$LOG_TAIL" || true
fi

# --- 14. health check (polling) ---------------------------------------------
if [ "$DRY_RUN" = 1 ] || [ "$HEALTH_WAIT" = 0 ]; then
  exit 0
fi

# container di un servizio: prima per config_files, fallback project+service
containers_of() {
  svc="$1"
  out=$(docker ps -a \
    --filter "label=com.docker.compose.project.config_files=$EXPECTED_CF" \
    --filter "label=com.docker.compose.service=$svc" \
    --format '{{.Names}}')
  if [ -z "$out" ]; then
    out=$(docker ps -a \
      --filter "label=com.docker.compose.project=$PROJECT" \
      --filter "label=com.docker.compose.service=$svc" \
      --format '{{.Names}}')
    [ -n "$out" ] && echo "WARNING: filtro config_files vuoto per '$svc', uso project+service" >&2
  fi
  printf '%s\n' "$out"
}

# costruisci l'elenco dei container da sorvegliare + RestartCount iniziale
WATCH=""; MISSING=""
while IFS="$TAB" read -r _ name kind gated cname profs; do
  [ -n "$name" ] || continue
  check=0
  if [ "$gated" = 0 ]; then
    check=1
  else
    for p in $(printf '%s' "$profs" | tr ',' ' '); do
      case " $PROFILES " in *" $p "*) check=1 ;; esac
    done
  fi
  [ "$check" = 1 ] || continue
  conts=$(containers_of "$name")
  if [ -z "$conts" ]; then MISSING="$MISSING $name"; continue; fi
  for cn in $conts; do
    WATCH="$WATCH $cn"
    rc=$(docker inspect -f '{{.RestartCount}}' "$cn" 2>/dev/null || echo 0)
    echo "$cn $rc" >> "$HWDIR/init"
  done
done <<EOF
$(printf '%s\n' "$PARSED" | grep '^SVC' || true)
EOF

if [ -n "$MISSING" ]; then
  echo "ERRORE health check: nessun container per i servizi:$MISSING" >&2
  exit 1
fi
set -- $WATCH; N_WATCH=$#
[ "$N_WATCH" -gt 0 ] || { echo "OK: nessun container da verificare"; exit 0; }

# La finestra minima parte da ADESSO, non dall'up: su questo NAS `up -d` puo'
# durare decine di secondi, e un container in crash-loop campionato una sola
# volta nella sua breve fase "Up" risulterebbe sano (bug visto dal vivo).
HC_TS=$(date +%s)
MINWIN=15; [ "$HEALTH_WAIT" -lt "$MINWIN" ] && MINWIN=$HEALTH_WAIT
MINOK=$((HC_TS + MINWIN))      # osservazione minima per intercettare i crash-loop
DEADLINE=$((HC_TS + HEALTH_WAIT))
echo ">> health check: sorveglio $N_WATCH container (budget ${HEALTH_WAIT}s)..."

ALLOK=0; BADPASS=""
while :; do
  ALLOK=1; BADPASS=""
  for cn in $WATCH; do
    info=$(docker inspect -f '{{.State.Status}}|{{.State.ExitCode}}|{{.RestartCount}}|{{.HostConfig.RestartPolicy.Name}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$cn" 2>/dev/null || echo "missing|-|-|-|-")
    state=${info%%|*};   rest=${info#*|}
    excode=${rest%%|*};  rest=${rest#*|}
    rc=${rest%%|*};      rest=${rest#*|}
    policy=${rest%%|*};  health=${rest##*|}
    initrc=$(awk -v n="$cn" '$1==n{print $2; exit}' "$HWDIR/init"); [ -n "$initrc" ] || initrc=0
    ok=0
    if [ "$state" = exited ] && [ "$excode" = 0 ] && { [ "$policy" = no ] || [ -z "$policy" ]; }; then
      ok=1                                                   # one-shot completato
    elif [ "$state" = running ] && [ "$health" != unhealthy ] && [ "$health" != starting ] \
         && [ "${rc:-0}" -le "${initrc:-0}" ]; then
      ok=1                                                   # running e sano, nessun restart
    fi
    if [ "$ok" = 0 ]; then
      ALLOK=0
      BADPASS="$BADPASS $cn[$state/$health/restarts=$rc]"
    fi
  done
  now=$(date +%s)
  if [ "$ALLOK" = 1 ] && [ "$now" -ge "$MINOK" ]; then
    echo "OK: $N_WATCH container sani"
    exit 0
  fi
  [ "$now" -ge "$DEADLINE" ] && break
  sleep 3
done

echo "ERRORE health check (timeout ${HEALTH_WAIT}s): container non sani:$BADPASS" >&2
for b in $BADPASS; do
  cn=${b%%[*}
  echo "--- log $cn (ultime 30 righe) ---" >&2
  docker logs --tail 30 "$cn" 1>&2 || true
done
exit 1
