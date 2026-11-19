$ErrorActionPreference = "Stop"
$version = "0.8.4"
$installerPath = Join-Path $env:RUNNER_TEMP "TermiNote-Setup-x64.exe"
$dataPath = Join-Path $env:RUNNER_TEMP "TermiNote-smoke-data"
$installDir = Join-Path $env:LOCALAPPDATA "Programs\TermiNote"
$exePath = Join-Path $installDir "TermiNote.exe"
$uninstallerPath = Join-Path $installDir "unins000.exe"
$process = $null
$installed = $false

try {
    if (Test-Path $installDir) {
        throw "The expected install folder already exists on this runner: $installDir"
    }

    New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
    $url = "https://github.com/SeanShaffer88/TermiNote/releases/download/v$version/TermiNote-Setup-x64.exe"
    Invoke-WebRequest -Uri $url -OutFile $installerPath
    if ((Get-Item $installerPath).Length -lt 1MB) {
        throw "The downloaded installer is unexpectedly small."
    }

    $setup = Start-Process -FilePath $installerPath -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-") -Wait -PassThru
    if ($setup.ExitCode -ne 0) {
        throw "The installer exited with code $($setup.ExitCode)."
    }
    if (-not (Test-Path $exePath)) {
        throw "TermiNote.exe was not installed at the expected path."
    }
    $installed = $true

    $env:TERMINOTE_DATA = $dataPath
    $process = Start-Process -FilePath $exePath -PassThru
    Start-Sleep -Seconds 10
    $process.Refresh()
    if ($process.HasExited) {
        throw "TermiNote exited during the 10-second startup check with code $($process.ExitCode)."
    }
    Write-Host "PASS: TermiNote v$version installed and remained running for 10 seconds."
} finally {
    if ($null -ne $process) {
        $process.Refresh()
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
    }

    if (Test-Path $uninstallerPath) {
        $uninstall = Start-Process -FilePath $uninstallerPath -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART") -Wait -PassThru
        if ($uninstall.ExitCode -ne 0) {
            throw "The uninstaller exited with code $($uninstall.ExitCode)."
        }
    } elseif ($installed -and (Test-Path $installDir)) {
        Remove-Item -Path $installDir -Recurse -Force
    }

    Remove-Item -Path $dataPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
}

