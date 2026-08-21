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

$items = Get-ChildItem -Path $LocalPath -Force
if (-not $items) {
    Write-Host "LocalPath e' vuoto: $LocalPath" -ForegroundColor Red
    exit 1
}
$paths = $items | ForEach-Object { $_.FullName }

Write-Host "Copio $($paths.Count) elementi da $LocalPath verso ${SshUser}@${SshHost}:$remoteDir/ ..." -ForegroundColor Cyan
& scp -P $SshPort -i $SshKey -r @paths "${SshUser}@${SshHost}:${remoteDir}/"
if ($LASTEXITCODE -ne 0) { Write-Host "scp fallito" -ForegroundColor Red; exit 1 }

Write-Host "Eseguo redeploy.sh su $ProjectName (docker-compose down/build/up)..." -ForegroundColor Cyan
& ssh -p $SshPort -i $SshKey "$SshUser@$SshHost" "sh '$remoteDir/redeploy.sh'"
if ($LASTEXITCODE -ne 0) { Write-Host "redeploy.sh ha restituito un errore" -ForegroundColor Red; exit 1 }

Write-Host "Redeploy completato per $ProjectName." -ForegroundColor Green
