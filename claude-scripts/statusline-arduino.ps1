# statusline-arduino.ps1
# Invocato da Claude Code come statusLine (vedi settings.json).
# Legge il JSON di stato da stdin, scrive %USERPROFILE%\.claude\usage-arduino.json
# (scrittura atomica) e stampa una riga compatta per la statusline del terminale.
# Deve essere robusto: qualsiasi errore -> stampa comunque qualcosa e non lancia.

try {
    $raw = [Console]::In.ReadToEnd()

    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Output "status unavailable"
        return
    }

    $data = $raw | ConvertFrom-Json

    # --- Modello ---
    $model = "Claude"
    if ($data.model -and $data.model.display_name) {
        $model = [string]$data.model.display_name
    }

    # --- Costo ---
    $cost = 0.0
    if ($data.cost -and ($data.cost.total_cost_usd -ne $null)) {
        $cost = [double]$data.cost.total_cost_usd
    }

    # --- Context window (puo' essere null dopo /compact o prima della prima chiamata API) ---
    $ctxPercent = 0
    $ctxTokens  = 0
    if ($data.context_window) {
        if ($data.context_window.used_percentage -ne $null) {
            $ctxPercent = [int][math]::Round([double]$data.context_window.used_percentage)
        }
        $inTok  = 0
        $outTok = 0
        if ($data.context_window.total_input_tokens -ne $null) {
            $inTok = [long]$data.context_window.total_input_tokens
        }
        if ($data.context_window.total_output_tokens -ne $null) {
            $outTok = [long]$data.context_window.total_output_tokens
        }
        $ctxTokens = $inTok + $outTok
    }

    # --- Rate limit 5h (presente solo per Pro/Max; puo' mancare del tutto) ---
    $ratePercent = -1
    if ($data.rate_limits -and $data.rate_limits.five_hour -and ($data.rate_limits.five_hour.used_percentage -ne $null)) {
        $ratePercent = [int][math]::Round([double]$data.rate_limits.five_hour.used_percentage)
    }

    # --- Scrittura atomica del file di telemetria ---
    $out = [ordered]@{
        ctxPercent  = $ctxPercent
        ctxTokens   = $ctxTokens
        ratePercent = $ratePercent
        updatedAt   = (Get-Date).ToString("o")
    }

    $target = Join-Path $env:USERPROFILE ".claude\usage-arduino.json"
    $tmp    = "$target.tmp"
    try {
        $json = $out | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -Path $tmp -Destination $target -Force
    }
    catch {
        Remove-Item -Path $tmp -ErrorAction SilentlyContinue
        throw
    }

    # --- Riga per la statusline del terminale (compatta, singola riga) ---
    $costStr = "{0:N2}" -f $cost
    $line = $model + " | ctx " + $ctxPercent + "% | $" + $costStr
    Write-Output $line
}
catch {
    try {
        if ($model) {
            Write-Output $model
        } else {
            Write-Output "status unavailable"
        }
    } catch {
        Write-Output "status unavailable"
    }
}
