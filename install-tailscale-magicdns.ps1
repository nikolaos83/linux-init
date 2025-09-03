# install-tailscale-magicdns.ps1
$ErrorActionPreference = "Stop"

$RepoUrl   = "https://raw.githubusercontent.com/nikolaos83/linux-init/main"
$ScriptDir = "C:\Users\uygar\OneDrive\CodeRepo\Scripts"
$Script    = Join-Path $ScriptDir "update-tailscale-hosts.ps1"

Write-Host "[*] Installing Tailscale MagicDNS updater..."

# Ensure script dir exists
if (-not (Test-Path $ScriptDir)) {
    New-Item -ItemType Directory -Path $ScriptDir | Out-Null
}

# Download latest updater script
$scriptUrl = "$RepoUrl/update-tailscale-hosts.ps1"
Invoke-WebRequest -Uri $scriptUrl -OutFile $Script -UseBasicParsing
Write-Host "[+] Downloaded update-tailscale-hosts.ps1"

# Define Scheduled Task
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -File `"$Script`""
# Repeat every 5 minutes for 10 years
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

# Register task as SYSTEM
Register-ScheduledTask -Action $action -Trigger $trigger `
    -TaskName "UpdateTailscaleHosts" `
    -Description "Keep Windows hosts in sync with Tailscale" `
    -User "SYSTEM" -RunLevel Highest -Force | Out-Null

Write-Host "[+] Scheduled task created (runs every 5 minutes)."

# Run once immediately
Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$Script`"" -Verb RunAs -Wait

Write-Host "[✓] Installation complete. /etc/hosts equivalent (Windows hosts file) is now synced."
