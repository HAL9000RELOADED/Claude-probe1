# arduino-usage-bridge.ps1
# Daemon da avviare MANUALMENTE (non e' invocato da Claude Code).
# Tiene aperta UNA sola connessione seriale verso l'Arduino e gli inoltra la
# telemetria scritta da statusline-arduino.ps1 in usage-arduino.json.
#
# IMPORTANTE: l'Arduino Uno si resetta (toggle DTR) ad OGNI apertura della porta.
# Per questo la porta viene aperta una volta sola e lasciata aperta: NON viene
# richiusa/riaperta a ogni aggiornamento, altrimenti il display si riavvierebbe
# di continuo perdendo i frame.
#
# --------------------------------------------------------------------------
# COME TROVARE LA PORTA COM GIUSTA:
#   Get-CimInstance Win32_PnPEntity |
#     Where-Object { $_.Name -match 'Arduino|CH340|USB.?Serial|USB-SERIAL' } |
#     Select-Object Name
#
#   La porta e' indicata tra parentesi nel nome, es. "USB-SERIAL CH340 (COM5)".
#   ATTENZIONE: le porte "Standard Serial over Bluetooth link" NON sono l'Arduino,
#   ignorale. Una volta individuata la porta reale, modifica $ComPort qui sotto.
# --------------------------------------------------------------------------

$ComPort  = "COM9"   # <-- MODIFICA con la tua porta reale (es. "COM5")
$BaudRate = 9600
$JsonPath = Join-Path $env:USERPROFILE ".claude\usage-arduino.json"

function Log($msg) {
    Write-Host ("[{0}] {1}" -f (Get-Date).ToString("HH:mm:ss"), $msg)
}

$port      = $null
$lastWrite = [DateTime]::MinValue

Log ("Bridge avviato. Porta configurata: {0} @ {1} baud." -f $ComPort, $BaudRate)

while ($true) {

    # --- Assicura che la porta sia aperta (con retry ogni 5s) ---
    if (($port -eq $null) -or (-not $port.IsOpen)) {
        try {
            if ($port -ne $null) {
                try { $port.Dispose() } catch { }
            }
            $port = New-Object System.IO.Ports.SerialPort($ComPort, $BaudRate)
            $port.ReadTimeout  = 1000
            $port.WriteTimeout = 1000
            $port.NewLine      = "`n"
            $port.Open()
            Log ("Connesso a {0}." -f $ComPort)
            # L'Arduino si resetta all'apertura: aspetta il boot prima di scrivere.
            Start-Sleep -Seconds 2
            # Forza il reinvio dei dati correnti dopo una (ri)connessione.
            $lastWrite = [DateTime]::MinValue
        }
        catch {
            Log ("Porta {0} non disponibile: {1}. Riprovo tra 5s..." -f $ComPort, $_.Exception.Message)
            Start-Sleep -Seconds 5
            continue
        }
    }

    # --- Legge il file di telemetria (errori di lettura NON chiudono la porta) ---
    $haveData    = $false
    $ctxPercent  = 0
    $ctxTokens   = 0
    $ratePercent = -1

    try {
        if (Test-Path $JsonPath) {
            $info = Get-Item $JsonPath
            if ($info.LastWriteTimeUtc -ne $lastWrite) {
                $data        = Get-Content -Path $JsonPath -Raw | ConvertFrom-Json
                $ctxPercent  = [int]$data.ctxPercent
                $ctxTokens   = [long]$data.ctxTokens
                $ratePercent = [int]$data.ratePercent
                $lastWrite   = $info.LastWriteTimeUtc
                $haveData    = $true
            }
        }
    }
    catch {
        # File a meta' scrittura o momentaneamente assente: riprova al prossimo giro.
        Log ("Lettura JSON fallita (riprovo): {0}" -f $_.Exception.Message)
    }

    # --- Invia i comandi all'Arduino (errori seriali -> riapre la porta) ---
    if ($haveData) {
        try {
            $port.Write("U$ctxPercent`n")
            $port.Write("K$ctxTokens`n")
            $port.Write("R$ratePercent`n")
            Log ("Inviato: U{0} K{1} R{2}" -f $ctxPercent, $ctxTokens, $ratePercent)
        }
        catch {
            Log ("Errore scrittura seriale: {0}. Riapro la porta..." -f $_.Exception.Message)
            try { $port.Close() }   catch { }
            try { $port.Dispose() } catch { }
            $port = $null
            Start-Sleep -Seconds 5
            continue
        }
    }

    Start-Sleep -Seconds 1
}
