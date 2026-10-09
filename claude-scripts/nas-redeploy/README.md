# redeploy.sh — redeploy generico per progetti Docker Compose sul NAS

Uno script POSIX `sh` unico, **project-agnostic**, da copiare invariato nella
cartella di qualsiasi progetto Compose sul NAS (TerraMaster TOS 6.0, dash).
Sostituisce le ~25 varianti scritte a mano. Tutto il comportamento specifico
del progetto sta in un `redeploy.conf` opzionale e/o negli hook, **mai** dentro
`redeploy.sh`.

## Cosa fa (in ordine)

1. Si posiziona nella cartella progetto (arg posizionale o cartella dello script).
2. Carica `./redeploy.conf` se presente.
3. Trova il compose file (o usa `COMPOSE_FILE`).
4. Legge la config via `docker-compose config` + `python3`/PyYAML (gli errori,
   es. variabili `.env` mancanti, vengono mostrati e fermano tutto).
5. **Preflight** senza modifiche: blocca se un `container_name` e' gia' occupato
   da un container di un altro progetto / creato con `docker run`; crea le reti
   esterne mancanti; crea le bind-dir interne mancanti (le altre → WARNING).
6. Hook `pre` → **build PRIMA dello spegnimento** (un build fallito lascia su il
   vecchio container, niente downtime) → hook `post-build` → `down` opzionale →
   `up -d` → hook `post` → `ps` + log → **health check in polling**.

Lo script **non passa mai `-p`** e **non usa mai `--remove-orphans`**: progetti
diversi con il compose nella stessa dir (es. `docker/`) condividono nome e rete,
e quelle opzioni cancellerebbero i container dell'altro bot. Per lo stesso
motivo **`--down` viene rifiutato** se la rete del progetto ha container di un
altro `config_files` (bot gemello, es. crypto/equity entrambi progetto
`docker`): un down toglierebbe la rete anche all'altro.

## Flag

| Flag | Effetto |
|------|---------|
| `DIR` (posizionale) | cartella progetto (default: cartella dello script) |
| `--dry-run` | stampa i comandi muta-stato con prefisso `+ ` senza eseguirli; gli hook vengono elencati, non eseguiti; `config`/`inspect`/`ps`/`logs` (sola lettura) girano comunque |
| `--down` | `down` prima di `up` (reti/subnet cambiate); rifiutato su progetto condiviso |
| `--no-down` | forza `DOWN_FIRST=0` (ignora la conf) |
| `--build-only` | solo build, nessun `up` |
| `--up` | forza il deploy completo (`BUILD_ONLY=0`, ignora la conf) |
| `--no-logs` | niente log finali |
| `--no-health` | salta l'health check (equivale a `HEALTH_WAIT=0`) |
| `-h`, `--help` | aiuto |

Flag sconosciuto → errore.

## Health check

Dopo l'`up` lo script fa **polling ogni 3s** fino al budget `HEALTH_WAIT`
(default 45s). Individua i container del progetto col filtro
`com.docker.compose.project.config_files` (fallback a `project`+`service` con
WARNING se vuoto). Un container e' considerato sano se:
- **one-shot completato**: `State=exited`, exit code `0` e restart policy `no`/vuota; oppure
- **running** senza health `starting`/`unhealthy` e con `RestartCount` **non** aumentato rispetto al primo campionamento (intercetta i crash-loop).

Esce con `OK` appena tutti sono sani **e** sono passati almeno 15s dall'inizio dell'health check (non dall'up, che sul NAS puo' durare decine di secondi). Al
timeout fallisce (exit 1) elencando ciascun container problematico come
`nome[stato/health/restarts=N]` e stampandone le ultime 30 righe di log; un
health `starting` ancora presente allo scadere del budget conta come fallimento.

## Autodetect del compose file

Se `COMPOSE_FILE` non e' impostato, cerca tra `docker-compose.yml/.yaml`,
`compose.yml/.yaml` e gli stessi sotto `docker/`. Con **un solo** candidato lo
usa; con **piu'** candidati disambigua dai container gia' esistenti
(`com.docker.compose.project.config_files`). **Al primo deploy**, quando ci sono
piu' candidati e nessun container ancora attivo, la disambiguazione non e'
possibile: impostare `COMPOSE_FILE` in `redeploy.conf`.

## Variabili di `redeploy.conf`

Vedi `redeploy.conf.example` per la documentazione completa. In sintesi:
`COMPOSE_FILE` (auto), `PROFILES` (vuoto), `BUILD_ONLY` (auto), `DOWN_FIRST=0`,
`PULL=1`, `LOG_TAIL=30`, `HEALTH_WAIT=45`, `MKDIR_BINDS=1`, `EXTRA_DIRS` (vuoto).
I flag da riga di comando hanno la precedenza sulla conf.

`BUILD_ONLY` auto = 1 quando **tutti** i servizi sono profile-gated e `PROFILES`
e' vuoto: in quel caso fa solo il build e stampa, per ogni servizio,
`Run manuale: docker-compose --profile <prof> run --rm <svc>`.

## Hook (opzionali)

File `sh` accanto allo script, eseguiti con `. ` in subshell: vedono la
funzione `dc()` e le variabili `$PROJECT`, `$COMPOSE_FILE`, `$PROJECT_DIR`. Se
un hook fallisce, il redeploy si ferma.

| Hook | Quando | Uso tipico |
|------|--------|------------|
| `redeploy.pre.sh` | prima di pull/build | migrazioni una-tantum, check prerequisiti |
| `redeploy.post-build.sh` | dopo build, prima di `up` | seed di file nelle bind-dir dall'immagine appena buildata |
| `redeploy.post.sh` | dopo `up` | passi finali |

## Non gestito

Progetti **senza** compose (solo `docker run`): tenere il loro script dedicato,
oppure migrarli prima a Compose.

## Migrazione dei vecchi script (esempi reali)

- **polymarket-arb-bot** — `redeploy.conf`: `EXTRA_DIRS="data/logs"`; più
  `redeploy.pre.sh` che copia `wallets.json` → `data/wallets.json` se manca.
- **news-scanner-agent / polymarket-signal-agent / mcp-stack** —
  `redeploy.pre.sh` con la migrazione una-tantum "copia dal vecchio named volume
  se la data dir e' vuota". La dipendenza di polymarket-signal-agent da
  `news-scanner-agent/data` e' gia' coperta dal WARNING sul bind esterno
  mancante (renderla fatale nel pre hook se la si vuole bloccante).
- **netmap / ibkr-gateway / transmission** — niente: image-only ⇒ pull automatico.
- **ibkr-forecastex-bot** — `redeploy.post-build.sh` con i due seed, es.:
  ```sh
  dc run --rm --no-deps --entrypoint sh <svc> -c 'cat /app/seed/x.json' > data/x.json
  ```
  La rete `ibkr-net` (esterna nel compose) viene creata in automatico.
- **russiabond-tracker / wsb-scanner-agent** — niente: `BUILD_ONLY` auto (tutti
  i servizi gated), fa il build e stampa l'hint `run --rm`.
- **equity-trading-bot / crypto-trading-bot** — niente, oppure per esplicitezza
  `COMPOSE_FILE=docker/docker-compose.yml` (crypto-trading-bot ha sia
  `./docker-compose.yml` sia `docker/docker-compose.yml`: il vivo e' `docker/`).
  Non passare mai `-p`/`--remove-orphans`: condividono il progetto `docker`.
  Per i sub-bot multi-asset (`docker/bonds`, ecc.) copiare lo script in quella
  sottocartella; se servono dir di stato fuori dal progetto usare `EXTRA_DIRS`
  con percorso assoluto, es.
  `EXTRA_DIRS="/Volume1/public/Docker/bonds-trading-bot/state"`.
- **tuya-orologi** — `redeploy.pre.sh`:
  ```sh
  [ -f config/config.json ] || { echo "config/config.json mancante"; exit 1; }
  ```

## Requisiti ambiente (gia' soddisfatti sul NAS)

`PATH` dei binari Docker e `DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0` sono
impostati dallo script. Richiede `docker-compose` v2.x standalone,
`/usr/bin/python3` con PyYAML.
