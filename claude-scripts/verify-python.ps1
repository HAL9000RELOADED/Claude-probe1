# Verifica sintattica (py_compile) dei file Python in un percorso qualsiasi.
# Uso per uso proprio dell'assistente (non richiede che l'utente lo lanci):
#   powershell -File verify-python.ps1 -Path "C:\percorso\progetto" [-Recurse]

param(
    [string]$Path = ".",
    [switch]$Recurse
)

$python = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python" -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1 |
    ForEach-Object { Join-Path $_.FullName "python.exe" }

if (-not $python -or -not (Test-Path $python)) {
    Write-Host "Nessun interprete Python trovato sotto $env:LOCALAPPDATA\Programs\Python" -ForegroundColor Red
    exit 1
}

$getChildParams = @{ Path = $Path; Filter = "*.py" }
if ($Recurse) { $getChildParams.Recurse = $true }
$pyFiles = Get-ChildItem @getChildParams | Where-Object { $_.FullName -notmatch '\__pycache__\' }

if (-not $pyFiles) {
    Write-Host "Nessun file .py trovato in $Path" -ForegroundColor Yellow
    exit 0
}

$hasError = $false
foreach ($file in $pyFiles) {
    & $python -m py_compile $file.FullName
    if ($LASTEXITCODE -eq 0) {
        Write-Host "OK    $($file.FullName)" -ForegroundColor Green
    } else {
        Write-Host "ERROR $($file.FullName)" -ForegroundColor Red
        $hasError = $true
    }
}

if ($hasError) { exit 1 } else { exit 0 }
