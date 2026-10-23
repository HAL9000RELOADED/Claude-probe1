# Finestra per worktree-audit.ps1: Controlla (sola lettura) / Applica (merge + pulizia, con conferma).
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$Engine = Join-Path $PSScriptRoot 'worktree-audit.ps1'

$form = New-Object Windows.Forms.Form
$form.Text = 'Worktree audit'
$form.Size = New-Object Drawing.Size(1000, 700)
$form.StartPosition = 'CenterScreen'

$lblRepo = New-Object Windows.Forms.Label -Property @{ Text = 'Repo'; Location = '10,14'; AutoSize = $true }
$txtRepo = New-Object Windows.Forms.TextBox -Property @{ Text = "$env:USERPROFILE\claude\AV"; Location = '50,10'; Width = 560; Anchor = 'Top,Left,Right' }
$btnBrowse = New-Object Windows.Forms.Button -Property @{ Text = '...'; Location = '615,9'; Width = 30; Anchor = 'Top,Right' }
$lblMain = New-Object Windows.Forms.Label -Property @{ Text = 'Ramo'; Location = '655,14'; AutoSize = $true; Anchor = 'Top,Right' }
$txtMain = New-Object Windows.Forms.TextBox -Property @{ Text = 'main'; Location = '695,10'; Width = 70; Anchor = 'Top,Right' }
$btnCheck = New-Object Windows.Forms.Button -Property @{ Text = 'Controlla'; Location = '775,8'; Width = 95; Anchor = 'Top,Right' }
$btnApply = New-Object Windows.Forms.Button -Property @{ Text = 'Applica...'; Location = '875,8'; Width = 95; Anchor = 'Top,Right' }
$out = New-Object Windows.Forms.RichTextBox -Property @{
    Location = '10,42'; Size = New-Object Drawing.Size(962, 580); Anchor = 'Top,Bottom,Left,Right'
    ReadOnly = $true; Font = New-Object Drawing.Font('Consolas', 9.5); BackColor = [Drawing.Color]::FromArgb(30, 30, 30)
    ForeColor = [Drawing.Color]::Gainsboro; WordWrap = $false
}
$status = New-Object Windows.Forms.Label -Property @{ Text = 'Pronto. "Controlla" non modifica nulla.'; Location = '10,630'; AutoSize = $true; Anchor = 'Bottom,Left' }
$form.Controls.AddRange(@($lblRepo, $txtRepo, $btnBrowse, $lblMain, $txtMain, $btnCheck, $btnApply, $out, $status))

function ColorOf($line) {
    if ($line -match '^===') { return [Drawing.Color]::DeepSkyBlue }
    if ($line -match 'CONFLITTO|FALLITO|mi fermo|sistemale prima') { return [Drawing.Color]::Tomato }
    if ($line -match 'DA MERGIARE|SALTO|TENGO|NON pulito|NON vuota|non committati|bloccat|^\s+(\?\?|!!| M|M |D |A )') { return [Drawing.Color]::Gold }
    if ($line -match '^\s+OK |rimoss|main pulito') { return [Drawing.Color]::LightGreen }
    [Drawing.Color]::Gainsboro
}

function Run([switch]$Apply) {
    $repo = $txtRepo.Text.Trim()
    if (-not (Test-Path (Join-Path $repo '.git'))) { [Windows.Forms.MessageBox]::Show("Non e' un repo git:`n$repo", 'Worktree audit') | Out-Null; return }
    $btnCheck.Enabled = $btnApply.Enabled = $false
    $form.Cursor = 'WaitCursor'
    $status.Text = if ($Apply) { 'Applico...' } else { 'Controllo...' }
    $form.Refresh()
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Engine`"", '-Repo', "`"$repo`"", '-Main', $txtMain.Text.Trim())
    if ($Apply) { $argList += '-Apply' }
    $psi = New-Object Diagnostics.ProcessStartInfo -Property @{
        FileName = 'powershell.exe'; Arguments = ($argList -join ' '); UseShellExecute = $false
        RedirectStandardOutput = $true; RedirectStandardError = $true; CreateNoWindow = $true
    }
    $p = [Diagnostics.Process]::Start($psi)
    $text = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $out.Clear()
    foreach ($line in $text -split "`r?`n") {
        $out.SelectionStart = $out.TextLength
        $out.SelectionColor = ColorOf $line
        $out.AppendText("$line`n")
    }
    $out.SelectionStart = 0; $out.ScrollToCaret()
    $status.Text = "$(if ($Apply) { 'Applicato' } else { 'Controllato' }) alle $(Get-Date -Format 'HH:mm:ss') - $repo"
    $form.Cursor = 'Default'
    $btnCheck.Enabled = $btnApply.Enabled = $true
}

$btnBrowse.Add_Click({
    $d = New-Object Windows.Forms.FolderBrowserDialog -Property @{ SelectedPath = $txtRepo.Text }
    if ($d.ShowDialog() -eq 'OK') { $txtRepo.Text = $d.SelectedPath }
})
$btnCheck.Add_Click({ Run })
$btnApply.Add_Click({
    $msg = "Applico su $($txtRepo.Text):`n`n- merge in $($txtMain.Text) dei rami con worktree pulito`n- rimozione dei worktree gia' mergiati e senza file`n- cancellazione delle cartelle orfane vuote`n`nI file non committati e i rami non vengono toccati. Procedo?"
    if ([Windows.Forms.MessageBox]::Show($msg, 'Conferma', 'YesNo', 'Warning') -eq 'Yes') { Run -Apply }
})
$form.Add_Shown({ Run })
[void]$form.ShowDialog()
