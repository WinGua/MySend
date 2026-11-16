param([Parameter(Mandatory=$true)][string]$Executable)
$ErrorActionPreference = 'Stop'
$reportDir = Join-Path $PWD 'startup-smoke'
New-Item -ItemType Directory -Force $reportDir | Out-Null
$reportPath = Join-Path $reportDir 'startup.json'
$binary = (Resolve-Path $Executable).Path
$app = Start-Process $binary -WorkingDirectory (Split-Path $binary) -ArgumentList @("--startup-report=$reportPath") -PassThru
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    $ready = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        $app.Refresh()
        if ($app.HasExited) { throw "MySend exited before startup: $($app.ExitCode)" }
        if (Test-Path $reportPath) {
            $state = $null
            try { $state = Get-Content $reportPath -Raw | ConvertFrom-Json } catch {}
            if ($state.state -eq 'error') { throw "MySend startup failed: $($state.stage) / $($state.errorType)" }
            if ($state.state -eq 'ready' -and $state.firstFrame) { $ready = $true; break }
        }
        Start-Sleep -Milliseconds 200
    }
    if (!$ready) { throw 'MySend did not render its first application frame and initialize services within 45 seconds' }
    Get-Content $reportPath
    Write-Output 'PASS: Windows release first frame and encrypted services are ready'
} finally {
    if (!$app.HasExited) { Stop-Process -Id $app.Id }
}
