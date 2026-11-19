$ErrorActionPreference = "Stop"

$cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $env:USERPROFILE ".cargo" }
$cargoBin = Join-Path $cargoHome "bin"
$downloadRoot = Join-Path $env:RUNNER_TEMP "terminote-cli-tools"
New-Item -ItemType Directory -Force -Path $cargoBin, $downloadRoot | Out-Null
$env:PATH = "$cargoBin;$env:PATH"

$tools = @(
    @{
        Name = "Dioxus CLI"
        Url = "https://github.com/DioxusLabs/dioxus/releases/download/v0.7.10/dx-x86_64-pc-windows-msvc.zip"
        Sha256 = "45eb4f87b7f86fdba8508ee7e0ef1f9e13cf8f2ffcc6a2d5858d0e8ea7dd1531"
        Executable = "dx.exe"
    },
    @{
        Name = "Tauri CLI"
        Url = "https://github.com/tauri-apps/tauri/releases/download/tauri-cli-v2.12.6/cargo-tauri-x86_64-pc-windows-msvc.zip"
        Sha256 = "39636fa68bc00f13dd610fb57688f292e93742978cc35395f2f1be7c540b88a1"
        Executable = "cargo-tauri.exe"
    }
)

foreach ($tool in $tools) {
    $archive = Join-Path $downloadRoot "$($tool.Executable).zip"
    $extract = Join-Path $downloadRoot ([IO.Path]::GetFileNameWithoutExtension($tool.Executable))
    Invoke-WebRequest -Uri $tool.Url -OutFile $archive

    $actualHash = (Get-FileHash -Path $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $tool.Sha256) {
        throw "$($tool.Name) archive checksum mismatch: expected $($tool.Sha256), got $actualHash"
    }

    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
    Expand-Archive -Path $archive -DestinationPath $extract -Force
    $binary = Get-ChildItem -Path $extract -Filter $tool.Executable -File -Recurse | Select-Object -First 1
    if (-not $binary) { throw "$($tool.Name) archive did not contain $($tool.Executable)" }
    Copy-Item $binary.FullName (Join-Path $cargoBin $tool.Executable) -Force
}

Add-Content -Path $env:GITHUB_PATH -Value $cargoBin
& (Join-Path $cargoBin "dx.exe") --version
cargo tauri --version
