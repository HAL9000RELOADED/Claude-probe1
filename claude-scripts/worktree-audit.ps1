<#
.SYNOPSIS
  Controlla (e con -Apply riordina) i worktree Claude di un repo: rami non mergiati in main,
  file non committati, cartelle orfane in .claude\worktrees, sessione Claude associata.

.DESCRIPTION
  Default = sola lettura, stampa il rapporto.
  -Apply:
    1. git worktree prune
    2. merge --no-ff in main di ogni ramo con commit non in main, se il suo worktree (se c'e') e' pulito.
       Conflitto solo su .gitignore -> tiene entrambe le parti; qualsiasi altro conflitto -> merge --abort e segnala.
    3. rimuove i worktree il cui ramo e' in main e che non hanno file sporchi/non tracciati
    4. cancella le cartelle orfane in .claude\worktrees solo se non contengono file
  Non committa mai file non tracciati e non cancella rami: quelli vanno decisi a mano.
  Alla fine elenca le sessioni Claude da avvisare ("si puo' cancellare").

.EXAMPLE
  & "$env:USERPROFILE\.claude\scripts\worktree-audit.ps1"
  & "$env:USERPROFILE\.claude\scripts\worktree-audit.ps1" -Apply
  & "$env:USERPROFILE\.claude\scripts\worktree-audit.ps1" -Repo "$env:USERPROFILE\claude\altro" -Main master
#>
param(
    [string]$Repo = "$env:USERPROFILE\claude\AV",
    [string]$Main = 'main',
    [switch]$Apply
)

$ErrorActionPreference = 'Continue'
$Repo = (Resolve-Path $Repo).Path
$WtRoot = Join-Path $Repo '.claude\worktrees'
$ProjDir = Join-Path $env:USERPROFILE '.claude\projects'
$JobsDir = Join-Path $env:USERPROFILE '.claude\jobs'

# stderr scartato: l'output serve solo come valore; l'esito sta in $gitOk
function RunGit { param([Parameter(ValueFromRemainingArguments)]$a) $o = & git.exe -C $Repo @a 2>$null; $script:gitOk = ($LASTEXITCODE -eq 0); $o }
function Norm($p) { ($p -replace '/', '\').TrimEnd('\').ToLower() }
function CountOf($range) { $s = (RunGit rev-list --count $range | Out-String).Trim(); $n = $s -as [int]; if ($null -eq $n) { -1 } else { $n } }

# file sporchi del worktree, compresi gli ignorati (worktree remove --force li cancellerebbe); cache python esclusa.
# Se git status fallisce il worktree conta come sporco.
function WtDirty($path) {
    $o = @(& git.exe -C $path status --porcelain --untracked-files=all --ignored 2>$null | Where-Object { $_ -and $_ -notmatch '(__pycache__/|\.pyc)$' })
    if ($LASTEXITCODE -ne 0) { return @("?? (git status fallito in $path)") }
    $o
}

# file in una cartella; se la lettura di qualche sottocartella fallisce restituisce -1 (= non vuota)
function FileCount($path) {
    $err = $null
    $n = @(Get-ChildItem $path -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable err).Count
    if ($err) { -1 } else { $n }
}

# --- sessioni Claude per cartella: transcript (~\.claude\projects\<path codificato>) + job bg (~\.claude\jobs\*\state.json)
# titolo dall'ultimo MB del transcript (i file arrivano a 100+ MB, scansione completa troppo lenta)
function TitleOf($file) {
    $fs = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
    try {
        $n = [Math]::Min($fs.Length, 1MB)
        [void]$fs.Seek(-$n, 'End')
        $buf = New-Object byte[] $n
        [void]$fs.Read($buf, 0, $n)
        $m = [regex]::Matches([Text.Encoding]::UTF8.GetString($buf), '"aiTitle":"([^"]*)"')
        if ($m.Count) { return $m[$m.Count - 1].Groups[1].Value }
    } finally { $fs.Close() }
    '(senza titolo)'
}

function SessionsFor($path) {
    $out = @()
    $enc = ($path -replace '[^A-Za-z0-9]', '-')
    $pd = Join-Path $ProjDir $enc
    if (Test-Path $pd) {
        foreach ($f in Get-ChildItem $pd -Filter *.jsonl -File) {
            $title = TitleOf $f.FullName
            $out += "$title [$($f.BaseName.Substring(0,8)), ultimo $($f.LastWriteTime.ToString('dd/MM HH:mm'))]"
        }
    }
    if (Test-Path $JobsDir) {
        $leaf = Split-Path $path -Leaf
        foreach ($s in Get-ChildItem $JobsDir -Directory | ForEach-Object { Join-Path $_.FullName 'state.json' } | Where-Object { Test-Path $_ }) {
            $txt = Get-Content $s -Raw
            if ($txt -match ('worktrees[\\/]+' + [regex]::Escape($leaf) + '["\\/]')) {
                $n = if ($txt -match '"name":\s*"([^"]*)"') { $Matches[1] } else { '?' }
                $out += "$n [job $(Split-Path (Split-Path $s) -Leaf)]"
            }
        }
    }
    $out | Select-Object -Unique
}

# --- stato
if ($Apply) { RunGit worktree prune | Out-Null }
$cur = (RunGit rev-parse --abbrev-ref HEAD | Out-String).Trim()
$mainDirty = @(RunGit status --porcelain --untracked-files=all | Where-Object { $_ })
$wts = @()
$block = $null
foreach ($l in (RunGit worktree list --porcelain)) {
    if ($l -like 'worktree *') { $block = [ordered]@{ Path = ($l.Substring(9)); Branch = '' }; $wts += $block }
    elseif ($l -like 'branch refs/heads/*' -and $block) { $block.Branch = $l.Substring(18) }
}
$wts = @($wts | Where-Object { (Norm $_.Path) -ne (Norm $Repo) })
$branches = @(RunGit for-each-ref --format='%(refname:short)' refs/heads | Where-Object { $_ -and $_ -ne $Main })

$rows = foreach ($b in $branches) {
    $wt = $wts | Where-Object { $_.Branch -eq $b } | Select-Object -First 1
    $dirty = @()
    if ($wt -and (Test-Path $wt.Path)) { $dirty = @(WtDirty $wt.Path) }
    [pscustomobject]@{
        Branch   = $b
        Ahead    = CountOf "$Main..$b"
        Behind   = CountOf "$b..$Main"
        Worktree = if ($wt) { $wt.Path } else { '' }
        Dirty    = $dirty
    }
}
$registered = @($wts | ForEach-Object { Norm $_.Path })
$orphans = @()
if (Test-Path $WtRoot) {
    $orphans = @(Get-ChildItem $WtRoot -Directory | Where-Object { $registered -notcontains (Norm $_.FullName) } | ForEach-Object {
        [pscustomobject]@{ Path = $_.FullName; Files = (FileCount $_.FullName) }
    })
}

# --- rapporto
Write-Host "`n=== Repo $Repo  (checkout su '$cur')" -ForegroundColor Cyan
if ($mainDirty.Count) { Write-Host "main NON pulito ($($mainDirty.Count) voci):" -ForegroundColor Yellow; $mainDirty | Select-Object -First 30 | ForEach-Object { "  $_" } }
else { Write-Host 'main pulito' -ForegroundColor Green }

Write-Host "`n=== Rami (commit fuori da $Main / indietro)" -ForegroundColor Cyan
foreach ($r in $rows | Sort-Object { -$_.Ahead }) {
    $st = if ($r.Ahead) { 'DA MERGIARE' } else { 'in main' }
    $wtTxt = if ($r.Worktree) { "worktree: $(Split-Path $r.Worktree -Leaf)" } else { 'nessun worktree' }
    $col = if ($r.Ahead -or $r.Dirty.Count) { 'Yellow' } else { 'Gray' }
    Write-Host ("  {0,-40} +{1,-3} -{2,-4} {3,-12} {4}" -f $r.Branch, $r.Ahead, $r.Behind, $st, $wtTxt) -ForegroundColor $col
    if ($r.Dirty.Count) { Write-Host "      file non committati: $($r.Dirty.Count)" -ForegroundColor Yellow; $r.Dirty | Select-Object -First 8 | ForEach-Object { "        $_" } }
}
Write-Host "`n=== Cartelle orfane in .claude\worktrees" -ForegroundColor Cyan
if (-not $orphans.Count) { '  nessuna' }
foreach ($o in $orphans) { "  $(Split-Path $o.Path -Leaf): $($o.Files) file" + $(if ($o.Files) { '  <- NON vuota, controllare a mano' } else { '' }) }

Write-Host "`n=== Sessioni Claude per worktree" -ForegroundColor Cyan
$sessMap = @{}
foreach ($p in @($wts.Path) + @($orphans.Path)) {
    if (-not $p) { continue }
    $s = @(SessionsFor ($p -replace '/', '\'))
    $sessMap[(Split-Path $p -Leaf)] = $s
    "  $(Split-Path $p -Leaf): " + $(if ($s.Count) { $s -join '; ' } else { '(nessuna trovata)' })
}

if (-not $Apply) { Write-Host "`nSola lettura. Rilancia con -Apply per mergiare/rimuovere." -ForegroundColor Cyan; return }

# --- applica
if ($cur -ne $Main) { Write-Host "`nIl checkout principale non e' su ${Main}: mi fermo." -ForegroundColor Red; return }
if (@(RunGit status --porcelain --untracked-files=no | Where-Object { $_ }).Count) { Write-Host "`n$Main ha modifiche tracciate non committate: sistemale prima (vedi sopra)." -ForegroundColor Red; return }

$done = @()
Write-Host "`n=== Merge" -ForegroundColor Cyan
foreach ($r in $rows | Where-Object { $_.Ahead -ne 0 }) {
    if ($r.Ahead -lt 0) { Write-Host "  SALTO $($r.Branch): conteggio commit non leggibile" -ForegroundColor Yellow; continue }
    if ($r.Dirty.Count) { Write-Host "  SALTO $($r.Branch): worktree con file non committati" -ForegroundColor Yellow; continue }
    $msg = "Merge $($r.Branch) in $Main (locale): riordino worktree $(Get-Date -Format 'dd/MM')"
    # conflictStyle=merge: solo marcatori a 2 vie, anche se l'utente usa diff3/zdiff3
    $err = & git.exe -C $Repo -c merge.conflictStyle=merge merge --no-ff -q $r.Branch -m $msg 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Host "  OK $($r.Branch)" -ForegroundColor Green; $r.Ahead = 0; continue }
    $conf = @(RunGit diff --name-only --diff-filter=U | Where-Object { $_ })
    if ($conf.Count -eq 1 -and $conf[0] -eq '.gitignore') {
        $gi = Join-Path $Repo '.gitignore'
        $raw = [IO.File]::ReadAllText($gi)
        $nl = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
        $lines = $raw -split "`r?`n" | Where-Object { $_ -notmatch '^(<<<<<<< |=======$|>>>>>>> )' }
        [IO.File]::WriteAllText($gi, (($lines -join $nl).TrimEnd() + $nl), (New-Object Text.UTF8Encoding $false))
        RunGit add .gitignore | Out-Null
        RunGit commit -q --no-edit | Out-Null
        if ($gitOk) { Write-Host "  OK $($r.Branch) (.gitignore unito)" -ForegroundColor Green; $r.Ahead = 0; continue }
    }
    if (Test-Path (Join-Path $Repo '.git\MERGE_HEAD')) { RunGit merge --abort | Out-Null }
    if ($conf.Count) { Write-Host "  CONFLITTO $($r.Branch): $($conf -join ', ') -> merge annullato, da fare a mano" -ForegroundColor Red }
    else { Write-Host "  MERGE FALLITO $($r.Branch): $(($err | Out-String).Trim())" -ForegroundColor Red }
}

Write-Host "`n=== Rimozione worktree" -ForegroundColor Cyan
foreach ($r in $rows | Where-Object { $_.Worktree }) {
    $leaf = Split-Path $r.Worktree -Leaf
    if ($r.Ahead -ne 0 -or $r.Dirty.Count) { Write-Host "  TENGO $leaf (non mergiato o sporco)" -ForegroundColor Yellow; continue }
    # ricontrollo subito prima: una sessione aperta potrebbe aver scritto dopo il primo giro
    $now = @(WtDirty $r.Worktree)
    if ($now.Count) { Write-Host "  TENGO $leaf (file nuovi/ignorati comparsi: $($now.Count))" -ForegroundColor Yellow; $now | Select-Object -First 5 | ForEach-Object { "      $_" }; continue }
    RunGit worktree remove --force $r.Worktree | Out-Null
    if (-not $gitOk -and (Test-Path $r.Worktree)) {
        $left = FileCount $r.Worktree
        Write-Host "  $leaf sganciato, cartella bloccata ($left file rimasti) - probabilmente cwd di una sessione aperta: cancellala dopo averla chiusa" -ForegroundColor Yellow
    } else { Write-Host "  rimosso $leaf" -ForegroundColor Green }
    $done += $leaf
}
RunGit worktree prune | Out-Null
foreach ($o in $orphans) {
    $leaf = Split-Path $o.Path -Leaf
    if ($o.Files -ne 0) { Write-Host "  TENGO orfana $leaf ($($o.Files) file, -1 = non leggibile)" -ForegroundColor Yellow; continue }
    try { Remove-Item $o.Path -Recurse -Force -ErrorAction Stop; Write-Host "  rimossa orfana $leaf" -ForegroundColor Green }
    catch { Write-Host "  orfana $leaf bloccata (sessione aperta?)" -ForegroundColor Yellow }
    $done += $leaf
}

Write-Host "`n=== Sessioni da avvisare ('si puo' cancellare')" -ForegroundColor Cyan
foreach ($leaf in $done) { if ($sessMap[$leaf].Count) { "  $leaf -> $($sessMap[$leaf] -join '; ')" } }
Write-Host "`nNota: i rami restano (sono gia' in $Main); i file non tracciati vanno decisi a mano." -ForegroundColor Cyan
