$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-ExecutionPolicy Bypass -File C:\Scripts\update-tailscale-hosts.ps1"

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::MaxValue)

Register-ScheduledTask -Action $action -Trigger $trigger `
  -TaskName "UpdateTailscaleHosts" -Description "Keep Windows hosts in sync with Tailscale" `
  -User "SYSTEM" -RunLevel Highest
