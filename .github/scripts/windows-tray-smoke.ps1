$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class TraySmokeNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
    public static void Click(int x, int y, bool right) {
        if (!SetCursorPos(x, y)) throw new InvalidOperationException("Could not move the cursor to the tray control.");
        uint down = right ? 0x0008u : 0x0002u;
        uint up = right ? 0x0010u : 0x0004u;
        mouse_event(down, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(100);
        mouse_event(up, 0, 0, 0, UIntPtr.Zero);
    }
}
"@

function Find-ElementsByName {
    param(
        [string]$Name,
        [System.Windows.Automation.ControlType[]]$ControlTypes = @()
    )
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty, $Name)
    try {
        $found = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants, $condition)
    } catch {
        return @()
    }
    $matches = @()
    foreach ($element in $found) {
        try {
            if ($ControlTypes.Count -eq 0 -or $ControlTypes -contains $element.Current.ControlType) {
                $matches += $element
            }
        } catch { }
    }
    return $matches
}

function Click-Element {
    param($Element, [switch]$Right)
    $bounds = $Element.Current.BoundingRectangle
    if ($bounds.IsEmpty -or $bounds.Width -le 0 -or $bounds.Height -le 0) {
        throw "UI Automation did not provide clickable bounds for $($Element.Current.Name)."
    }
    $x = [int]($bounds.X + ($bounds.Width / 2))
    $y = [int]($bounds.Y + ($bounds.Height / 2))
    [TraySmokeNative]::Click($x, $y, $Right.IsPresent)
}

function Invoke-AccessibleElement {
    param($Element)
    try {
        $pattern = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $pattern.Invoke()
    } catch {
        $legacy = $Element.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern)
        $legacy.DoDefaultAction()
    }
}

function Open-HiddenTrayIcons {
    $icons = @(Find-ElementsByName -Name "TermiNote" -ControlTypes @(
        [System.Windows.Automation.ControlType]::Button,
        [System.Windows.Automation.ControlType]::ListItem,
        [System.Windows.Automation.ControlType]::MenuItem))
    if ($icons.Count -gt 0) {
        Write-Host "TermiNote is already visible in the tray overflow panel."
        return
    }
    $chevrons = @(Find-ElementsByName -Name "Show Hidden Icons" -ControlTypes @([System.Windows.Automation.ControlType]::Button))
    if ($chevrons.Count -eq 0) { throw "The taskbar did not expose its hidden-icons button." }
    Click-Element -Element $chevrons[0]
    $null = Wait-ForTrayIcon
    Write-Host "Opened the hidden tray icons panel."
}

function Wait-ForTrayIcon {
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $icons = @(Find-ElementsByName -Name "TermiNote" -ControlTypes @(
            [System.Windows.Automation.ControlType]::Button,
            [System.Windows.Automation.ControlType]::ListItem,
            [System.Windows.Automation.ControlType]::MenuItem))
        if ($icons.Count -gt 0) { return $icons[0] }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    $taskbar = [TraySmokeNative]::FindWindow("Shell_TrayWnd", $null)
    $overflow = [TraySmokeNative]::FindWindow("NotifyIconOverflowWindow", $null)
    $explorer = @(Get-Process explorer -ErrorAction SilentlyContinue | ForEach-Object { "pid=$($_.Id), session=$($_.SessionId)" })
    Write-Host "Tray diagnostics: Shell_TrayWnd=$taskbar; NotifyIconOverflowWindow=$overflow; Explorer=$($explorer -join '; ')"
    $named = @(Find-ElementsByName -Name "TermiNote")
    $descriptions = @($named | ForEach-Object { try { "$($_.Current.ControlType) [$($_.Current.ClassName)]" } catch { "stale UIA element" } })
    Write-Host "UI Automation TermiNote matches: $($descriptions -join '; ')"
    if ($taskbar -ne [IntPtr]::Zero) {
        try {
            $taskbarElement = [System.Windows.Automation.AutomationElement]::FromHandle($taskbar)
            $children = $taskbarElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            $controls = @()
            for ($i = 0; $i -lt $children.Count -and $i -lt 80; $i++) {
                try {
                    $child = $children.Item($i)
                    $name = $child.Current.Name
                    if (-not [string]::IsNullOrWhiteSpace($name)) { $controls += "$name/$($child.Current.ControlType)" }
                } catch { }
            }
            Write-Host "Taskbar UI Automation controls: $($controls -join '; ')"
        } catch { Write-Host "Taskbar UI Automation diagnostic failed: $($_.Exception.Message)" }
    }
    throw "TermiNote tray icon was not exposed by the hosted Windows taskbar UI."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$exePath = Join-Path (Join-Path (Join-Path (Join-Path $repoRoot "target") "x86_64-pc-windows-msvc") "release") "terminote.exe"
$dataPath = Join-Path $env:RUNNER_TEMP "TermiNote-tray-smoke-data"
$eventLogPath = Join-Path $dataPath "tray-events.log"
$process = $null

try {
    if (-not (Test-Path $exePath)) { throw "The Windows app executable was not produced: $exePath" }
    $targetDir = Split-Path $exePath
    $loader = Get-ChildItem (Join-Path $repoRoot "target/x86_64-pc-windows-msvc") -Filter "WebView2Loader.dll" -Recurse | Select-Object -First 1
    if ($null -eq $loader) { throw "WebView2Loader.dll was not found in the x64 build output." }
    $localLoader = Join-Path $targetDir "WebView2Loader.dll"
    if (-not (Test-Path $localLoader)) {
        Copy-Item -Path $loader.FullName -Destination $localLoader -Force
        Write-Host "Copied WebView2Loader.dll beside the test executable."
    }
    New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
    $env:TERMINOTE_DATA = $dataPath
    $env:TERMINOTE_TRAY_TEST_LOG = $eventLogPath
    $process = Start-Process -FilePath $exePath -WorkingDirectory (Split-Path $exePath) -PassThru
    $windowDeadline = (Get-Date).AddSeconds(30)
    do {
        $process.Refresh()
        $windowHandle = $process.MainWindowHandle
        if ($windowHandle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $windowDeadline)
    if ($windowHandle -eq [IntPtr]::Zero) { throw "TermiNote did not create a main window." }
    Write-Host "TermiNote started; testing the tray icon on the hosted desktop."

    [TraySmokeNative]::ShowWindow($windowHandle, 0) | Out-Null
    Start-Sleep -Milliseconds 500
    if ([TraySmokeNative]::IsWindowVisible($windowHandle)) { throw "Could not hide the main window before the tray restore check." }
    Open-HiddenTrayIcons
    $trayIcon = Wait-ForTrayIcon
    $bounds = $trayIcon.Current.BoundingRectangle
    Write-Host "Tray icon UIA: name=$($trayIcon.Current.Name); type=$($trayIcon.Current.ControlType); class=$($trayIcon.Current.ClassName); automationId=$($trayIcon.Current.AutomationId); bounds=$bounds"
    Click-Element -Element $trayIcon
    $restoreDeadline = (Get-Date).AddSeconds(3)
    do {
        if ([TraySmokeNative]::IsWindowVisible($windowHandle)) { break }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $restoreDeadline)
    $restorePassed = [TraySmokeNative]::IsWindowVisible($windowHandle)
    $restoreMethod = "mouse click"
    if (-not $restorePassed) {
        Write-Host "Mouse click did not restore; retrying through UI Automation InvokePattern."
        Open-HiddenTrayIcons
        $trayIcon = Wait-ForTrayIcon
        Invoke-AccessibleElement -Element $trayIcon
        $restoreDeadline = (Get-Date).AddSeconds(5)
        do {
            if ([TraySmokeNative]::IsWindowVisible($windowHandle)) { break }
            Start-Sleep -Milliseconds 200
        } while ((Get-Date) -lt $restoreDeadline)
        $restorePassed = [TraySmokeNative]::IsWindowVisible($windowHandle)
        $restoreMethod = "UI Automation InvokePattern"
    }
    if ($restorePassed) { Write-Host "PASS: tray activation restored the window via $restoreMethod." }
    else { Write-Host "FAIL: tray activation did not restore the window." }
    if (Test-Path $eventLogPath) { Write-Host "Tauri tray events after restore: $(Get-Content $eventLogPath -Raw)" } else { Write-Host "Tauri tray events after restore: (none)" }

    [TraySmokeNative]::ShowWindow($windowHandle, 0) | Out-Null
    Start-Sleep -Milliseconds 500
    Open-HiddenTrayIcons
    $trayIcon = Wait-ForTrayIcon
    Click-Element -Element $trayIcon -Right
    $quitDeadline = (Get-Date).AddSeconds(10)
    $quitItems = @()
    $nativeMenu = [IntPtr]::Zero
    do {
        $nativeMenu = [TraySmokeNative]::FindWindow("#32768", $null)
        $quitItems = @(Find-ElementsByName -Name "Quit" -ControlTypes @(
            [System.Windows.Automation.ControlType]::MenuItem,
            [System.Windows.Automation.ControlType]::Button))
        if ($quitItems.Count -gt 0) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $quitDeadline)
    if ($quitItems.Count -eq 0) { throw "The tray context menu did not expose its Quit item." }
    $nativeMenu = [TraySmokeNative]::FindWindow("#32768", $null)
    Write-Host "Native menu handle: $nativeMenu"
    $quitBounds = $quitItems[0].Current.BoundingRectangle
    Write-Host "Tray Quit menu item: type=$($quitItems[0].Current.ControlType); class=$($quitItems[0].Current.ClassName); bounds=$quitBounds"
    Invoke-AccessibleElement -Element $quitItems[0]
    if (-not $process.WaitForExit(10000)) {
        if (Test-Path $eventLogPath) { Write-Host "Tauri tray events after Quit timeout: $(Get-Content $eventLogPath -Raw)" }
        else { Write-Host "Tauri tray events after Quit timeout: (none)" }
        throw "Selecting Quit from the tray menu did not exit TermiNote."
    }
    Write-Host "PASS: selecting Quit from the tray menu exited TermiNote."
    if (-not $restorePassed) { throw "The tray Quit check passed, but a left-click did not restore the window." }
} finally {
    if ($null -ne $process) {
        $process.Refresh()
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
    }
    Remove-Item Env:TERMINOTE_TRAY_TEST_LOG -ErrorAction SilentlyContinue
    Remove-Item -Path $dataPath -Recurse -Force -ErrorAction SilentlyContinue
}
