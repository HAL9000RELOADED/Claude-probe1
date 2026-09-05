# Sincronizza un progetto locale e ne esegue il (ri)deploy Docker su un NAS,
# seguendo la convenzione gia' in uso per gli altri progetti Docker li' presenti:
# ogni progetto vive in /Volume1/public/Docker/<ProjectName>/ con un proprio
# redeploy.sh che richiama docker-compose (down/build/up). Il redeploy.sh deve
# gia' esistere dentro LocalPath insieme a Dockerfile/docker-compose.yml/sorgenti.
#
# Accesso NAS: SSH su porta non-standard con un account/chiave dedicati.
# docker/docker-compose potrebbero non essere in PATH di default sul NAS - i
# redeploy.sh esistenti fanno gia' l'export PATH necessario se serve, quindi non
# serve rifarlo qui.
#
# Uso per uso proprio dell'assistente (adatta i parametri di default sotto
# all'host/account/porta del proprio NAS):
#   powershell -File nas-docker-redeploy.ps1 -ProjectName my-service -LocalPath "$env:USERPROFILE\my-service\docker"

param(
    [Parameter(Mandatory = $true)][string]$ProjectName,
    [Parameter(Mandatory = $true)][string]$LocalPath,
    [string]$SshKey = "$env:USERPROFILE\.ssh\id_ed25519_blackhole_claude",
    [string]$SshUser = "claude",
    [string]$SshHost = "Blackhole",
    [int]$SshPort = 9224,
    [string]$RemoteBase = "/Volume1/public/Docker"
)

if (-not (Test-Path $LocalPath)) {
    Write-Host "Percorso locale non trovato: $LocalPath" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $SshKey)) {
    Write-Host "Chiave SSH non trovata: $SshKey" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path (Join-Path $LocalPath "redeploy.sh"))) {
    Write-Host "Manca redeploy.sh in $LocalPath - crealo prima (vedi redeploy.sh di un progetto esistente come riferimento)." -ForegroundColor Red
    exit 1
}

$remoteDir = "$RemoteBase/$ProjectName"

Write-Host "Creo la cartella remota $remoteDir (se non esiste)..." -ForegroundColor Cyan
& ssh -p $SshPort -i $SshKey "$SshUser@$SshHost" "mkdir -p '$remoteDir'"
if ($LASTEXITCODE -ne 0) { Write-Host "SSH mkdir fallito" -ForegroundColor Red; exit 1 }

## Esclusioni sempre applicate, a prescindere dalla modalita' sotto: .git non
## serve mai per far girare un container (e sul SECONDO deploy di un repo gia'
## tracciato, scp fallisce con "Permission denied" sui suoi .git/objects/* gia'
## caricati, che git scrive read-only) - .env va escluso perche' per convenzione
## vive SOLO sul NAS (mai committato, spesso nemmeno presente in locale) e un
## deploy non deve mai rischiare di sovrascrivere credenziali reali gia'
## presenti li' con un file locale stantio/di esempio.
$ExcludeNames = @(".git", ".claude", ".env", "__pycache__", ".pytest_cache", ".DS_Store", "Thumbs.db")

## Modalita' preferita: se LocalPath e' un repo git, sincronizza SOLO i file
## tracciati + non ignorati (`git ls-files -c -o --exclude-standard`), ricorsivo
## e rispettoso del .gitignore di ciascun progetto - non solo i nomi di primo
## livello elencati sopra. Motivo (incidente reale, 2026-09-05): la vecchia
## esclusione per nome operava solo sui figli diretti di LocalPath, quindi un
## file di stato runtime ANNIDATO (es. data/price_history/2026-09-05.json,
## scritto localmente da un test non isolato) non veniva escluso e lo scp lo ha
## sovrascritto sopra ai dati reali gia' presenti sul NAS nella stessa cartella
## bind-mounted - anche se quel percorso era gia' correttamente in .gitignore.
## Usare l'elenco di git chiude la falla una volta per tutte per qualunque
## pattern un progetto abbia gia' in .gitignore (SQLite di stato, report,
## cache), senza dover mantenere un secondo elenco di esclusione qui.
$isGitRepo = Test-Path (Join-Path $LocalPath ".git")
$stagingDir = $null

if ($isGitRepo -and -not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "git non e' installato - ricado sull'esclusione per nome (solo primo livello, non protegge dati annidati ignorati)." -ForegroundColor Yellow
    $isGitRepo = $false
}

if ($isGitRepo) {
    Write-Host "LocalPath e' un repo git - sincronizzo solo i file tracciati/non ignorati (git ls-files)..." -ForegroundColor DarkGray
    Push-Location $LocalPath
    try {
        $relPaths = git ls-files -c -o --exclude-standard 2>$null
        $gitOk = ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
    if (-not $gitOk -or -not $relPaths) {
        Write-Host "git ls-files non disponibile o vuoto - ricado sull'esclusione per nome (solo primo livello, non protegge dati annidati ignorati)." -ForegroundColor Yellow
        $isGitRepo = $false
    }
}

try {
    if ($isGitRepo) {
        # Difesa in profondita': filtra comunque i nomi noti anche dall'elenco
        # git, nel caso in cui uno di essi non sia coperto dal .gitignore di
        # un progetto.
        $relPaths = $relPaths | Where-Object {
            $segments = $_ -split '[\\/]'
            -not ($ExcludeNames | Where-Object { $segments -contains $_ })
        }
        if (-not $relPaths) {
            Write-Host "Nessun file tracciato/non ignorato trovato in $LocalPath" -ForegroundColor Red
            exit 1
        }

        # $stagingDir e' assegnato PRIMA di scrivere, cosi' se New-Item/
        # Copy-Item lancia un errore la cartella parziale viene comunque
        # ripulita dal blocco finally sotto (che gia' vive nello stesso try).
        $stagingDir = Join-Path $env:TEMP ("nas-deploy-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $stagingDir | Out-Null
        Write-Host "Preparo una copia filtrata di $($relPaths.Count) file in $stagingDir ..." -ForegroundColor DarkGray
        foreach ($rel in $relPaths) {
            $src = Join-Path $LocalPath $rel
            if (-not (Test-Path $src -PathType Leaf)) { continue }  # submodule/symlink strani: salta
            $dst = Join-Path $stagingDir $rel
            $dstDir = Split-Path $dst -Parent
            if ($dstDir -and -not (Test-Path $dstDir)) {
                New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
            }
            Copy-Item -Path $src -Destination $dst -Force
        }
        $effectiveLocalPath = $stagingDir
    } else {
        $effectiveLocalPath = $LocalPath
    }

    $items = Get-ChildItem -Path $effectiveLocalPath -Force | Where-Object { $ExcludeNames -notcontains $_.Name }
    if (-not $items) {
        Write-Host "LocalPath e' vuoto (o contiene solo elementi esclusi): $LocalPath" -ForegroundColor Red
        exit 1
    }
    $paths = $items | ForEach-Object { $_.FullName }
    if (-not $isGitRepo) {
        Write-Host "Esclusi dalla sincronizzazione (solo primo livello, se presenti): $($ExcludeNames -join ', ')" -ForegroundColor DarkGray
    }

    Write-Host "Copio $($paths.Count) elementi da $LocalPath verso ${SshUser}@${SshHost}:$remoteDir/ ..." -ForegroundColor Cyan
    & scp -P $SshPort -i $SshKey -r @paths "${SshUser}@${SshHost}:${remoteDir}/"
    if ($LASTEXITCODE -ne 0) { Write-Host "scp fallito" -ForegroundColor Red; exit 1 }
} finally {
    if ($stagingDir -and (Test-Path $stagingDir)) {
        Remove-Item -Recurse -Force $stagingDir -ErrorAction SilentlyContinue
    }
}

Write-Host "Eseguo redeploy.sh su $ProjectName (docker-compose down/build/up)..." -ForegroundColor Cyan
& ssh -p $SshPort -i $SshKey "$SshUser@$SshHost" "sh '$remoteDir/redeploy.sh'"
if ($LASTEXITCODE -ne 0) { Write-Host "redeploy.sh ha restituito un errore" -ForegroundColor Red; exit 1 }

Write-Host "Redeploy completato per $ProjectName." -ForegroundColor Green
