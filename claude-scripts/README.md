# claude-scripts

Script di utilita' personali usati da Claude Code su piu' macchine.

## Contenuto

### `verify-python.ps1`
Verifica sintattica (`py_compile`) di tutti i file `.py` sotto un percorso dato.
Uso pensato per l'assistente stesso (dopo che un subagent modifica file Python, specie
quando il subagent non ha un tool Bash per auto-verificarsi):

```
powershell -File verify-python.ps1 -Path "C:\percorso\progetto" [-Recurse]
```

Auto-scopre l'interprete Python piu' recente sotto `%LOCALAPPDATA%\Programs\Python`.
Nessuna dipendenza esterna oltre a un Python installato.

### `statusline-arduino.ps1`
Script statusLine per Claude Code (vedi `settings.json` -> `statusLine`). Legge il JSON
di stato di Claude Code da stdin, scrive `%USERPROFILE%\.claude\usage-arduino.json`
(scrittura atomica) con percentuale di context usato, token totali e percentuale di
rate limit 5h, e stampa una riga compatta per il terminale. Pensato per non lanciare
mai eccezioni (fallback a "status unavailable").

### `arduino-usage-bridge.ps1`
Daemon da avviare **manualmente** (non invocato da Claude Code). Apre una connessione
seriale verso un Arduino e gli inoltra la telemetria scritta da `statusline-arduino.ps1`
in `usage-arduino.json`, per mostrarla su un display fisico collegato all'Arduino.
La porta COM va impostata a mano nello script (variabile `$ComPort`, di default
placeholder "COM9") -- vedi commento in testa al file per come trovarla. La porta
viene aperta una volta sola e mai richiusa/riaperta ad ogni update, perche' un
Arduino Uno si resetta ad ogni apertura porta (toggle DTR) e richiudere/riaprire
continuamente farebbe perdere i frame al display.

### `nas-docker-redeploy.ps1` + `nas-redeploy.sh`
Sincronizza un progetto locale sul NAS (`/Volume1/public/Docker/<Progetto>/`) e ne
esegue il redeploy Docker:

```
powershell -File nas-docker-redeploy.ps1 -ProjectName my-service -LocalPath "C:\percorso\docker"
```

`nas-redeploy.sh` e' il `redeploy.sh` **generico**, valido per tutti i container:
se il progetto non ha un suo `redeploy.sh`, lo script PowerShell lo copia
automaticamente (convertito a LF). Fa `down` -> `build` -> `up -d`, trova da solo
`docker compose`/`docker-compose` e aggiunge al PATH i percorsi tipici del NAS.
Opzioni via variabili d'ambiente: `COMPOSE_FILE`, `NO_BUILD=1`, `PULL=1`, `PRUNE=1`.
Un `redeploy.sh` presente nel progetto ha la precedenza (override per casi speciali).

## Note per l'uso su una nuova macchina

- I percorsi usano `%USERPROFILE%` / `$env:USERPROFILE`, quindi funzionano su
  qualunque account Windows senza modifiche.
- `arduino-usage-bridge.ps1` e `statusline-arduino.ps1` hanno senso solo su una
  macchina con l'Arduino fisicamente collegato (imposta `$ComPort` con la tua porta
  reale); `verify-python.ps1` e' generico e utile ovunque ci sia un progetto Python.
