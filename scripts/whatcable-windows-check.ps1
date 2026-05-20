#requires -Version 5.1
<#
.SYNOPSIS
Checks whether a Windows PC can expose enough UCSI data for WhatCable.

.DESCRIPTION
Finds the Windows UCSI USB Connector Manager device, checks or enables the
TestInterfaceEnabled registry flag under its Device Parameters key, restarts
the UCSI devnode when the flag changes, and runs read-only UCSI probes through
Microsoft's UcsiControl.exe when available.

This script intentionally avoids direct EC access. It only uses Windows' UCSI
driver test interface and standard PnP/registry APIs.
#>

[CmdletBinding()]
param(
    [switch]$Enable,
    [switch]$NoRestart,
    [string]$UcsiControlPath,
    [int]$MaxConnectors = 8,
    [string]$JsonOut,
    [switch]$CreateIssue,
    [string]$IssueRepo = "darrylmorley/whatcable-windows"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "== $Message =="
}

function Find-UcsiDevices {
    $devices = @()

    try {
        $devices = @(Get-PnpDevice -PresentOnly | Where-Object {
            ($_.FriendlyName -eq "UCSI USB Connector Manager") -or
            ($_.FriendlyName -like "*UCSI*Connector*Manager*") -or
            ($_.FriendlyName -like "*UCM-UCSI*") -or
            ($_.InstanceId -like "ACPI\USBC000*")
        })
    } catch {
        Write-Warning "Get-PnpDevice failed: $($_.Exception.Message)"
    }

    if ($devices.Count -eq 0) {
        try {
            $devices = @(Get-CimInstance Win32_PnPEntity | Where-Object {
                ($_.Name -eq "UCSI USB Connector Manager") -or
                ($_.Name -like "*UCSI*Connector*Manager*") -or
                ($_.Name -like "*UCM-UCSI*") -or
                ($_.PNPDeviceID -like "ACPI\USBC000*")
            } | ForEach-Object {
                [pscustomobject]@{
                    FriendlyName = $_.Name
                    InstanceId = $_.PNPDeviceID
                    Status = $_.Status
                    Class = $null
                }
            })
        } catch {
            Write-Warning "CIM device query failed: $($_.Exception.Message)"
        }
    }

    return @($devices)
}

function Get-DeviceParametersPath {
    param([string]$InstanceId)
    return "HKLM:\SYSTEM\CurrentControlSet\Enum\$InstanceId\Device Parameters"
}

function Get-TestInterfaceEnabled {
    param([string]$RegistryPath)

    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        return $false
    }

    $property = Get-ItemProperty -LiteralPath $RegistryPath -Name "TestInterfaceEnabled" -ErrorAction SilentlyContinue
    if ($null -eq $property) {
        return $false
    }

    return ([int]$property.TestInterfaceEnabled -eq 1)
}

function Enable-TestInterface {
    param([string]$RegistryPath)

    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        New-Item -Path $RegistryPath -Force | Out-Null
    }

    New-ItemProperty `
        -LiteralPath $RegistryPath `
        -Name "TestInterfaceEnabled" `
        -PropertyType DWord `
        -Value 1 `
        -Force | Out-Null
}

function Restart-UcsiDevice {
    param([string]$InstanceId)

    $pnputil = Join-Path $env:SystemRoot "System32\pnputil.exe"
    if (Test-Path -LiteralPath $pnputil) {
        $output = & $pnputil /restart-device $InstanceId 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            return @{
                ok = $true
                method = "pnputil /restart-device"
                output = $output.Trim()
            }
        }
    }

    Disable-PnpDevice -InstanceId $InstanceId -Confirm:$false | Out-Null
    Start-Sleep -Seconds 2
    Enable-PnpDevice -InstanceId $InstanceId -Confirm:$false | Out-Null

    return @{
        ok = $true
        method = "Disable-PnpDevice/Enable-PnpDevice"
        output = ""
    }
}

function Find-UcsiControl {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        if (Test-Path -LiteralPath $ExplicitPath) {
            return (Resolve-Path -LiteralPath $ExplicitPath).Path
        }
        throw "UcsiControlPath was provided but does not exist: $ExplicitPath"
    }

    $command = Get-Command "UcsiControl.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    $programFiles = [Environment]::GetEnvironmentVariable("ProgramFiles")
    $candidateRoots = @()
    foreach ($basePath in @($programFilesX86, $programFiles)) {
        if (-not $basePath) {
            continue
        }

        $candidateRoots += Join-Path $basePath "USBTest"
        $candidateRoots += Join-Path $basePath "Windows Kits\10\Tools"
    }

    $candidateRoots = @($candidateRoots | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique)

    foreach ($root in $candidateRoots) {
        $match = Get-ChildItem -LiteralPath $root -Recurse -Filter "UcsiControl.exe" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($match) {
            return $match.FullName
        }
    }

    return $null
}

function Find-GitHubCli {
    $command = Get-Command "gh.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $command = Get-Command "gh" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    return $null
}

function Get-SystemSummary {
    try {
        $computer = Get-CimInstance Win32_ComputerSystem
        $os = Get-CimInstance Win32_OperatingSystem

        return [pscustomobject]@{
            manufacturer = $computer.Manufacturer
            model = $computer.Model
            osCaption = $os.Caption
            osVersion = $os.Version
            osBuildNumber = $os.BuildNumber
        }
    } catch {
        return [pscustomobject]@{
            manufacturer = $null
            model = $null
            osCaption = $null
            osVersion = $null
            osBuildNumber = $null
        }
    }
}

function Limit-Text {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxLength = 2000
    )

    if (-not $Text) {
        return ""
    }

    if ($Text.Length -le $MaxLength) {
        return $Text
    }

    return $Text.Substring(0, $MaxLength) + "`n... truncated ..."
}

function Format-UcsiCommand {
    param([UInt64]$Command)
    return $Command.ToString("X")
}

function New-ConnectorCommand {
    param(
        [int]$Connector,
        [UInt64]$CommandCode
    )
    return [UInt64](($Connector -shl 16) -bor $CommandCode)
}

function New-GetPdMessageCommand {
    param(
        [int]$Connector,
        [int]$Recipient,
        [int]$Offset,
        [int]$Bytes,
        [int]$MessageType
    )

    $command = [UInt64]0x15
    $command = $command -bor [UInt64]($Connector -shl 16)
    $command = $command -bor ([UInt64]$Recipient -shl 23)
    $command = $command -bor ([UInt64]$Offset -shl 26)
    $command = $command -bor ([UInt64]$Bytes -shl 34)
    $command = $command -bor ([UInt64]$MessageType -shl 42)
    return $command
}

function Invoke-UcsiControl {
    param(
        [string]$ToolPath,
        [string]$Name,
        [int]$Argument,
        [UInt64]$Command
    )

    $commandHex = Format-UcsiCommand $Command
    $output = & $ToolPath Send $Argument $commandHex 2>&1 | Out-String
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }

    return [pscustomobject]@{
        name = $Name
        argument = $Argument
        command = $commandHex
        exitCode = $exitCode
        ok = ($exitCode -eq 0)
        output = $output.Trim()
    }
}

function Invoke-UcsiProbes {
    param(
        [string]$ToolPath,
        [int]$MaxConnectors
    )

    $probes = New-Object System.Collections.Generic.List[object]

    $probes.Add((Invoke-UcsiControl -ToolPath $ToolPath -Name "GET_CAPABILITY" -Argument 0 -Command 0x6))

    for ($connector = 1; $connector -le $MaxConnectors; $connector++) {
        $statusCommand = New-ConnectorCommand -Connector $connector -CommandCode 0x12
        $cableCommand = New-ConnectorCommand -Connector $connector -CommandCode 0x11
        $pdoBase = New-ConnectorCommand -Connector $connector -CommandCode 0x10
        $remotePdoBase = $pdoBase -bor [UInt64]0x00800000

        $probes.Add((Invoke-UcsiControl -ToolPath $ToolPath -Name "CONNECTOR_$connector GET_CONNECTOR_STATUS" -Argument 0 -Command $statusCommand))
        $probes.Add((Invoke-UcsiControl -ToolPath $ToolPath -Name "CONNECTOR_$connector GET_CABLE_PROPERTY" -Argument 0 -Command $cableCommand))
        $probes.Add((Invoke-UcsiControl -ToolPath $ToolPath -Name "CONNECTOR_$connector GET_PDOS_LOCAL_SOURCE" -Argument 7 -Command $pdoBase))
        $probes.Add((Invoke-UcsiControl -ToolPath $ToolPath -Name "CONNECTOR_$connector GET_PDOS_LOCAL_SINK" -Argument 3 -Command $pdoBase))
        $probes.Add((Invoke-UcsiControl -ToolPath $ToolPath -Name "CONNECTOR_$connector GET_PDOS_REMOTE_SOURCE" -Argument 7 -Command $remotePdoBase))
        $probes.Add((Invoke-UcsiControl -ToolPath $ToolPath -Name "CONNECTOR_$connector GET_PDOS_REMOTE_SINK" -Argument 3 -Command $remotePdoBase))

        foreach ($recipient in @(1, 2, 3)) {
            $identityCommand = New-GetPdMessageCommand `
                -Connector $connector `
                -Recipient $recipient `
                -Offset 0 `
                -Bytes 28 `
                -MessageType 4
            $probes.Add((Invoke-UcsiControl -ToolPath $ToolPath -Name "CONNECTOR_$connector GET_PD_MESSAGE_IDENTITY_RECIPIENT_$recipient" -Argument 0 -Command $identityCommand))
        }
    }

    return @($probes)
}

function Get-CompatibilityResult {
    param(
        [object[]]$Devices,
        [bool]$AllEnabled,
        [string]$UcsiControl,
        [object[]]$Probes
    )

    if ($Devices.Count -eq 0) {
        return "Unsupported"
    }

    if (-not $AllEnabled) {
        return "Partial"
    }

    if (-not $UcsiControl) {
        return "Partial"
    }

    $statusOk = @($Probes | Where-Object { $_.name -like "*GET_CONNECTOR_STATUS" -and $_.ok }).Count -gt 0
    $cableOk = @($Probes | Where-Object { $_.name -like "*GET_CABLE_PROPERTY" -and $_.ok }).Count -gt 0
    $identityOk = @($Probes | Where-Object { $_.name -like "*GET_PD_MESSAGE_IDENTITY*" -and $_.ok }).Count -gt 0

    if ($statusOk -and ($cableOk -or $identityOk)) {
        return "Compatible"
    }

    if ($statusOk) {
        return "Partial"
    }

    return "Unsupported"
}

function New-IssueProbeSummary {
    param([object[]]$Probes)

    if ($Probes.Count -eq 0) {
        return "_No UCSIControl probes were run._"
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("| Probe | Command | Exit | Result |")
    $lines.Add("| --- | --- | ---: | --- |")

    foreach ($probe in $Probes) {
        $state = if ($probe.ok) { "OK" } else { "FAIL" }
        $name = [string]$probe.name
        $command = "Send $($probe.argument) $($probe.command)"
        $lines.Add("| ``$name`` | ``$command`` | $($probe.exitCode) | $state |")
    }

    return ($lines -join "`n")
}

function New-IssueReport {
    param(
        [object]$Report,
        [int]$ProbeOutputLimit
    )

    return [pscustomobject]@{
        tool = $Report.tool
        schemaVersion = $Report.schemaVersion
        generatedAt = $Report.generatedAt
        compatibility = $Report.compatibility
        isAdministrator = $Report.isAdministrator
        maxConnectors = $Report.maxConnectors
        system = $Report.system
        ucsiControlPath = $Report.ucsiControlPath
        devices = $Report.devices
        restarts = $Report.restarts
        probes = @($Report.probes | ForEach-Object {
            $output = if ($ProbeOutputLimit -gt 0) {
                Limit-Text -Text $_.output -MaxLength $ProbeOutputLimit
            } else {
                ""
            }

            [pscustomobject]@{
                name = $_.name
                argument = $_.argument
                command = $_.command
                exitCode = $_.exitCode
                ok = $_.ok
                output = $output
            }
        })
    }
}

function New-IssueBodyText {
    param(
        [object]$Report,
        [string]$ProbeSummary,
        [string]$Json,
        [string]$OutputNote
    )

    return @"
## WhatCable Windows compatibility check

**Result:** $($Report.compatibility)

**Machine:** $($Report.system.manufacturer) $($Report.system.model)

**Windows:** $($Report.system.osCaption) $($Report.system.osVersion) build $($Report.system.osBuildNumber)

**Ran as administrator:** $($Report.isAdministrator)

**UCSIControl:** $($Report.ucsiControlPath)

### Probe summary

$probeSummary

### Diagnostic JSON

$OutputNote

If the script was run with -JsonOut, the local JSON file has the full report.

~~~json
$json
~~~
"@
}

function New-IssueBody {
    param([object]$Report)

    $probeSummary = New-IssueProbeSummary -Probes @($Report.probes)
    $bodyLimit = 60000
    $probeOutputLimits = @(2000, 500, 100, 0)

    foreach ($probeOutputLimit in $probeOutputLimits) {
        $issueReport = New-IssueReport -Report $Report -ProbeOutputLimit $probeOutputLimit
        $json = $issueReport | ConvertTo-Json -Depth 8 -Compress
        $outputNote = if ($probeOutputLimit -gt 0) {
            "Probe output is capped at $probeOutputLimit characters per probe in this issue body to keep it within GitHub's issue size limit."
        } else {
            "Probe output is omitted from this issue body to keep it within GitHub's issue size limit."
        }
        $body = New-IssueBodyText -Report $Report -ProbeSummary $probeSummary -Json $json -OutputNote $outputNote

        if ($body.Length -le $bodyLimit) {
            return $body
        }
    }

    $minimalReport = [pscustomobject]@{
        tool = $Report.tool
        schemaVersion = $Report.schemaVersion
        generatedAt = $Report.generatedAt
        compatibility = $Report.compatibility
        isAdministrator = $Report.isAdministrator
        maxConnectors = $Report.maxConnectors
        system = $Report.system
        ucsiControlPath = $Report.ucsiControlPath
        devices = $Report.devices
        restarts = $Report.restarts
        probeCount = @($Report.probes).Count
    }
    $minimalJson = $minimalReport | ConvertTo-Json -Depth 8 -Compress
    return New-IssueBodyText `
        -Report $Report `
        -ProbeSummary $probeSummary `
        -Json $minimalJson `
        -OutputNote "Probe detail is omitted from this issue body because the full report would exceed GitHub's issue size limit."
}

function New-GitHubIssue {
    param(
        [object]$Report,
        [string]$Repo
    )

    $gh = Find-GitHubCli
    if (-not $gh) {
        throw "GitHub CLI was not found. Install gh, authenticate with 'gh auth login', then re-run with -CreateIssue."
    }

    $machine = "$($Report.system.manufacturer) $($Report.system.model)".Trim()
    if (-not $machine) {
        $machine = "Unknown Windows PC"
    }

    $title = "Windows check: $($Report.compatibility) on $machine"
    $body = New-IssueBody -Report $Report
    $bodyFile = [System.IO.Path]::GetTempFileName()

    try {
        Set-Content -LiteralPath $bodyFile -Value $body -Encoding UTF8
        $output = & $gh issue create --repo $Repo --title $title --body-file $bodyFile 2>&1 | Out-String

        if ($LASTEXITCODE -ne 0) {
            throw "gh issue create failed: $($output.Trim())"
        }

        return $output.Trim()
    } finally {
        Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
    }
}

$isAdmin = Test-IsAdministrator
$system = Get-SystemSummary
$deviceReports = New-Object System.Collections.Generic.List[object]
$changedRegistry = $false
$restartReports = New-Object System.Collections.Generic.List[object]
$probes = @()
$ucsiControl = $null
$issueFailed = $false

Write-Host "WhatCable Windows compatibility checker"
Write-Host "Experimental. Run before buying WhatCable Windows Labs."

Write-Step "Finding UCSI device"
$devices = @(Find-UcsiDevices)

if ($devices.Count -eq 0) {
    Write-Host "No UCSI USB Connector Manager device was found."
} else {
    foreach ($device in $devices) {
        $name = if ($device.FriendlyName) { $device.FriendlyName } else { "(unnamed)" }
        Write-Host "Found: $name"
        Write-Host "InstanceId: $($device.InstanceId)"
    }
}

Write-Step "Checking TestInterfaceEnabled"
foreach ($device in $devices) {
    $registryPath = Get-DeviceParametersPath -InstanceId $device.InstanceId
    $enabledBefore = Get-TestInterfaceEnabled -RegistryPath $registryPath
    $enabledAfter = $enabledBefore
    $writeError = $null

    if (-not $enabledBefore -and $Enable) {
        if ($isAdmin) {
            try {
                Enable-TestInterface -RegistryPath $registryPath
                $enabledAfter = Get-TestInterfaceEnabled -RegistryPath $registryPath
                $changedRegistry = $true
                Write-Host "Enabled TestInterfaceEnabled at $registryPath"
            } catch {
                $writeError = $_.Exception.Message
                Write-Warning "Failed to set TestInterfaceEnabled: $writeError"
            }
        } else {
            Write-Warning "TestInterfaceEnabled is missing and this session is not elevated."
            Write-Host "Run PowerShell as Administrator and re-run with -Enable."
            Write-Host "Registry value: $registryPath\TestInterfaceEnabled = DWORD 1"
        }
    } elseif (-not $enabledBefore) {
        Write-Warning "TestInterfaceEnabled is missing. Re-run with -Enable as Administrator to set it."
        Write-Host "Registry value: $registryPath\TestInterfaceEnabled = DWORD 1"
    } else {
        Write-Host "Already enabled: $registryPath\TestInterfaceEnabled"
    }

    $deviceReports.Add([pscustomobject]@{
        friendlyName = $device.FriendlyName
        instanceId = $device.InstanceId
        status = $device.Status
        registryPath = $registryPath
        testInterfaceEnabledBefore = $enabledBefore
        testInterfaceEnabledAfter = $enabledAfter
        writeError = $writeError
    })
}

if ($changedRegistry -and -not $NoRestart) {
    Write-Step "Restarting UCSI device"
    foreach ($device in $devices) {
        try {
            $restart = Restart-UcsiDevice -InstanceId $device.InstanceId
            Write-Host "Restarted $($device.InstanceId) using $($restart.method)"
            $restartReports.Add([pscustomobject]@{
                instanceId = $device.InstanceId
                ok = $restart.ok
                method = $restart.method
                output = $restart.output
                error = $null
            })
        } catch {
            Write-Warning "Failed to restart $($device.InstanceId): $($_.Exception.Message)"
            $restartReports.Add([pscustomobject]@{
                instanceId = $device.InstanceId
                ok = $false
                method = $null
                output = ""
                error = $_.Exception.Message
            })
        }
    }
} elseif ($changedRegistry -and $NoRestart) {
    Write-Warning "Registry changed, but UCSI device restart was skipped because -NoRestart was set."
}

Write-Step "Finding UcsiControl.exe"
try {
    $ucsiControl = Find-UcsiControl -ExplicitPath $UcsiControlPath
} catch {
    Write-Warning -Message ($_.Exception.Message)
}

if ($ucsiControl) {
    Write-Host "Using $ucsiControl"
    Write-Step "Running UCSI probes"
    $probes = Invoke-UcsiProbes -ToolPath $ucsiControl -MaxConnectors $MaxConnectors

    foreach ($probe in $probes) {
        $state = if ($probe.ok) { "OK" } else { "FAIL" }
        Write-Host "[$state] $($probe.name): UcsiControl.exe Send $($probe.argument) $($probe.command)"
    }
} else {
    Write-Warning "UcsiControl.exe was not found. Install Microsoft USB Test Tool (MUTT), put UcsiControl.exe on PATH, or pass -UcsiControlPath."
}

$allEnabled = ($deviceReports.Count -gt 0) -and (@($deviceReports | Where-Object { -not $_.testInterfaceEnabledAfter }).Count -eq 0)
$result = Get-CompatibilityResult -Devices @($devices) -AllEnabled $allEnabled -UcsiControl $ucsiControl -Probes @($probes)

$report = [pscustomobject]@{
    tool = "whatcable-windows-check"
    schemaVersion = 1
    generatedAt = (Get-Date).ToString("o")
    isAdministrator = $isAdmin
    maxConnectors = $MaxConnectors
    compatibility = $result
    system = $system
    ucsiControlPath = $ucsiControl
    devices = @($deviceReports)
    restarts = @($restartReports)
    probes = @($probes)
}

Write-Step "Result"
switch ($result) {
    "Compatible" {
        Write-Host "Compatible: this PC exposed connector status plus cable identity or PD identity data."
    }
    "Partial" {
        Write-Host "Partial: UCSI exists, but the checker could not prove the full WhatCable data path."
    }
    default {
        Write-Host "Unsupported: this PC did not expose a usable UCSI path for WhatCable."
    }
}

if ($JsonOut) {
    $json = $report | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $JsonOut -Value $json -Encoding UTF8
    Write-Host "Wrote diagnostic JSON: $JsonOut"
}

if ($CreateIssue) {
    Write-Step "Creating GitHub issue"
    try {
        $issueUrl = New-GitHubIssue -Report $report -Repo $IssueRepo
        Write-Host "Created issue: $issueUrl"
    } catch {
        $issueFailed = $true
        Write-Warning -Message ($_.Exception.Message)
    }
}

if ($issueFailed) {
    exit 3
}

if ($result -eq "Compatible") {
    exit 0
}

if ($result -eq "Partial") {
    exit 2
}

exit 1
