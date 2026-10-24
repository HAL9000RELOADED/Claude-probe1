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

### `nas-docker-redeploy.ps1` + `nas-redeploy/`
Deploy di un progetto Docker Compose sul NAS: copia la cartella locale (solo file
tracciati da git, se e' un repo) e lancia `redeploy.sh` via SSH. Se il progetto non ha
un suo `redeploy.sh`, carica il template generico `nas-redeploy/redeploy.sh`
(`-UseTemplate` per forzarlo, `-RedeployArgs "--dry-run"` per passare flag).

`nas-redeploy/redeploy.sh` e' un unico script POSIX sh da copiare **invariato** in ogni
progetto compose: autodetect del compose file, pull/build prima di toccare il container
(build fallita = vecchio container intatto), `up -d`, health check in polling
(crash-loop/unhealthy = exit 1), `--dry-run`. Lo specifico del progetto va in
`redeploy.conf` e negli hook `redeploy.pre.sh` / `redeploy.post-build.sh` /
`redeploy.post.sh`. Dettagli ed esempi di migrazione in `nas-redeploy/README.md`.

### `worktree-audit.ps1` + `worktree-audit-gui.ps1` + `Avvia_WorktreeAudit.bat`
Riordino dei worktree git creati dalle sessioni Claude Code (`.claude\worktrees\` di un
repo). Per ogni ramo dice quanti commit non sono ancora in `main`, se il suo worktree ha
file non committati (anche ignorati da git), quali cartelle in `.claude\worktrees` sono
orfane e a quale sessione Claude appartiene ogni worktree (titolo letto dai transcript in
`%USERPROFILE%\.claude\projects` e dai job in `%USERPROFILE%\.claude\jobs`).

```
powershell -File worktree-audit.ps1                          # solo controllo
powershell -File worktree-audit.ps1 -Apply                   # riordina
powershell -File worktree-audit.ps1 -Repo C:\percorso\repo -Main master
```

Senza parametri e' in **sola lettura** (default repo: `%USERPROFILE%\claude\AV`). Con
`-Apply`:
- fa il merge `--no-ff` in `main` dei rami con worktree pulito; se il conflitto riguarda
  solo `.gitignore` tiene le righe di entrambe le parti, qualsiasi altro conflitto viene
  annullato (`merge --abort`) e segnalato;
- rimuove i worktree gia' mergiati e senza file (ricontrolla subito prima di rimuoverli,
  nel caso una sessione aperta abbia scritto nel frattempo);
- cancella le cartelle orfane solo se vuote;
- stampa le sessioni da avvisare che il loro lavoro e' in `main`.

Non committa mai file non tracciati e non cancella rami: quelli restano da decidere a mano.
Una cartella che e' la directory di lavoro di una sessione aperta non si puo' cancellare
finche' la sessione non viene chiusa: lo script la segnala e basta rilanciarlo dopo.

`Avvia_WorktreeAudit.bat` (doppio clic) apre `worktree-audit-gui.ps1`, una finestra con
campo repo/ramo, pulsanti **Controlla** e **Applica...** (con conferma) e output colorato;
sotto usa lo stesso `worktree-audit.ps1`, che deve stare nella stessa cartella.

## Note per l'uso su una nuova macchina

- I percorsi usano `%USERPROFILE%` / `$env:USERPROFILE`, quindi funzionano su
  qualunque account Windows senza modifiche.
- `arduino-usage-bridge.ps1` e `statusline-arduino.ps1` hanno senso solo su una
  macchina con l'Arduino fisicamente collegato (imposta `$ComPort` con la tua porta
  reale); `verify-python.ps1` e' generico e utile ovunque ci sia un progetto Python.
