<#
.SYNOPSIS
    Extended ArcBox SQL Lab - Deployment Script
    Deploys 10 SQL Server VMs and 5 Application Server VMs as Hyper-V nested VMs
    using differencing disks from the base ArcBox SQL VHD.

.DESCRIPTION
    This script extends the standard ArcBox ITPro deployment by:
    1. Creating 10 SQL Server VMs via differencing disks from the parent SQL VHD
    2. Creating 5 Application Server VMs via differencing disks from the Win2K22 VHD
    3. Configuring unique SQL Server instances and databases on each VM
    4. Deploying demo applications on app servers connected to their SQL backends
    5. Onboarding all VMs to Azure Arc
    6. Installing SQL Server Arc extensions for assessment and migration

.NOTES
    Run this script AFTER the base ArcBox ITPro deployment completes.
    It uses the same VHD images already downloaded by ArcServersLogonScript.ps1
#>

param (
    [switch]$SkipArcOnboarding,
    [switch]$SkipAppDeployment,
    [int]$SqlServerCount = 10,
    [int]$AppServerCount = 5
)

$ErrorActionPreference = $env:ErrorActionPreference
if (-not $ErrorActionPreference) { $ErrorActionPreference = 'Continue' }

# Prevent interactive credential prompts - all Invoke-Command calls should use pre-built creds
$PSDefaultParameterValues['Invoke-Command:ErrorAction'] = 'Stop'

#region Configuration
$Env:ArcBoxDir = 'C:\ArcBox'
$Env:ArcBoxLogsDir = "$Env:ArcBoxDir\Logs"
$Env:ArcBoxVMDir = 'F:\Virtual Machines'
$Env:ArcBoxDscDir = "$Env:ArcBoxDir\DSC"
$ExtendedLabDir = "$Env:ArcBoxDir\ExtendedLab"

$namingPrefix = $env:namingPrefix
if (-not $namingPrefix) { $namingPrefix = 'ArcBox' }

$tenantId = $env:tenantId
$subscriptionId = $env:subscriptionId
$azureLocation = $env:azureLocation
$resourceGroup = $env:resourceGroup
$resourceTags = $env:resourceTags

# VM Credentials
# The script must be idempotent - VMs could be in any of these states:
#   1. Fresh boot (parent hostname): ArcBox-SQL\Administrator
#   2. Renamed (local): ArcBox-SQL01\Administrator
#   3. Domain-joined: doofer\Administrator
$nestedWindowsPassword = 'JS123!!'
$secWindowsPassword = ConvertTo-SecureString $nestedWindowsPassword -AsPlainText -Force

# Domain credential (works after domain join)
$domainName = 'doofer.co.uk'
$domainNetbios = 'doofer'
$domainCred = New-Object System.Management.Automation.PSCredential ("$domainNetbios\Administrator", $secWindowsPassword)

# Initial credential uses parent VHD hostname (same for all VMs before rename)
$sqlParentHostname = "$namingPrefix-SQL"
$initialCred = New-Object System.Management.Automation.PSCredential ("$sqlParentHostname\Administrator", $secWindowsPassword)

# After rename, credential uses the VM's new hostname
function Get-VMCredential {
    param([string]$VMName)
    return New-Object System.Management.Automation.PSCredential ("$VMName\Administrator", $secWindowsPassword)
}

# Try all credential types in order: domain, renamed local, parent hostnames
# This makes the script idempotent regardless of VM state
function Get-WorkingCredential {
    param([string]$VMName)
    
    $appParentCred = New-Object System.Management.Automation.PSCredential ("$namingPrefix-Win2K22\Administrator", $secWindowsPassword)
    
    $credsToTry = @(
        $domainCred                          # domain-joined state
        (Get-VMCredential -VMName $VMName)   # renamed local state
        $initialCred                          # fresh boot (SQL parent hostname)
        $appParentCred                       # fresh boot (Win2K22 parent hostname)
    )
    
    foreach ($cred in $credsToTry) {
        try {
            Invoke-Command -VMName $VMName -ScriptBlock { $true } -Credential $cred -ErrorAction Stop | Out-Null
            return $cred
        } catch {
            continue
        }
    }
    
    # None worked - return domain cred as best guess (will fail with clear error)
    Write-Warning "  No credential worked for $VMName (tried domain, local, SQL parent, Win2K22 parent)"
    return $domainCred
}

# SQL Server VM definitions
$sqlServers = @(
    @{ Name = "$namingPrefix-SQL01"; Role = "ERP/Finance"; DB = "FinanceERP"; Port = 1433; IP = "10.10.1.101" }
    @{ Name = "$namingPrefix-SQL02"; Role = "CRM"; DB = "ContososCRM"; Port = 1433; IP = "10.10.1.102" }
    @{ Name = "$namingPrefix-SQL03"; Role = "HR/Payroll"; DB = "HRPayroll"; Port = 1433; IP = "10.10.1.103" }
    @{ Name = "$namingPrefix-SQL04"; Role = "Inventory/WMS"; DB = "InventoryWMS"; Port = 1433; IP = "10.10.1.104" }
    @{ Name = "$namingPrefix-SQL05"; Role = "E-Commerce"; DB = "ECommerceStore"; Port = 1433; IP = "10.10.1.105" }
    @{ Name = "$namingPrefix-SQL06"; Role = "Analytics"; DB = "AnalyticsDB"; Port = 1433; IP = "10.10.1.116" }
    @{ Name = "$namingPrefix-SQL07"; Role = "Document Mgmt"; DB = "DocumentMgmt"; Port = 1433; IP = "10.10.1.117" }
    @{ Name = "$namingPrefix-SQL08"; Role = "Legacy LOB"; DB = "LegacyLOB"; Port = 1433; IP = "10.10.1.118" }
    @{ Name = "$namingPrefix-SQL09"; Role = "DevTest"; DB = "AppDev_v2"; Port = 1433; IP = "10.10.1.119" }
    @{ Name = "$namingPrefix-SQL10"; Role = "Compliance"; DB = "ComplianceAudit"; Port = 1433; IP = "10.10.1.120" }
)

# App Server VM definitions
$appServers = @(
    @{ Name = "$namingPrefix-APP01"; Role = "ERP Web App"; ConnectsTo = "$namingPrefix-SQL01"; AppType = "WebAPI" }
    @{ Name = "$namingPrefix-APP02"; Role = "CRM Portal"; ConnectsTo = "$namingPrefix-SQL02"; AppType = "WebApp" }
    @{ Name = "$namingPrefix-APP03"; Role = "HR Portal"; ConnectsTo = "$namingPrefix-SQL03"; AppType = "WebApp" }
    @{ Name = "$namingPrefix-APP04"; Role = "E-Commerce"; ConnectsTo = "$namingPrefix-SQL05"; AppType = "WebAPI" }
    @{ Name = "$namingPrefix-APP05"; Role = "BI Reports"; ConnectsTo = "$namingPrefix-SQL06"; AppType = "WebApp" }
)
#endregion

#region Helper Functions
function Write-Header {
    param ([string]$Message)
    Write-Host ""
    Write-Host "=" * 60
    Write-Host " $Message"
    Write-Host "=" * 60
    Write-Host ""
}

function Copy-VMFileWithRetry {
    param (
        [string]$VMName,
        [string]$SourcePath,
        [string]$DestinationPath,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 10
    )
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            Copy-VMFile $VMName -SourcePath $SourcePath -DestinationPath $DestinationPath -CreateFullPath -FileSource Host -Force -ErrorAction Stop
            return
        } catch {
            if ($i -eq $MaxAttempts) { throw }
            Write-Host "    Copy-VMFile attempt $i failed for $VMName, retrying in ${DelaySeconds}s..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Wait-ForVM {
    param ([string]$VMName, [int]$TimeoutSeconds = 300)
    $elapsed = 0
    while ((Get-VM -Name $VMName -ErrorAction SilentlyContinue).State -ne 'Running' -and $elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    # Wait for network
    Start-Sleep -Seconds 30
}

#endregion

# Start logging (stop any existing transcript first)
$logFilePath = "$Env:ArcBoxLogsDir\ExtendedSQLLab.log"
try { Stop-Transcript -ErrorAction SilentlyContinue } catch { }
Start-Transcript -Path $logFilePath -Force -ErrorAction SilentlyContinue

Write-Header "Extended ArcBox SQL Lab Deployment"
Write-Host "Deploying $SqlServerCount SQL Servers and $AppServerCount Application Servers"
Write-Host "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

#region Create Extended Lab Directory
if (-not (Test-Path $ExtendedLabDir)) {
    New-Item -Path $ExtendedLabDir -ItemType Directory -Force | Out-Null
}
#endregion

#region Convert original ArcBox-SQL to use differencing disk
Write-Header "Preparing Parent VHD"

# PROBLEM: The original ArcBox-SQL VM uses the parent VHD directly (read-write).
# Differencing disks require the parent to be read-only. These are INCOMPATIBLE.
# Even when VMs are stopped, Hyper-V won't allow read-write access to a VHD that
# has differencing children pointing to it.
#
# SOLUTION: Convert the original ArcBox-SQL to also use a differencing disk.
# This way ALL VMs (original + new ones) reference the parent as read-only.

$originalSqlVM = Get-VM -Name "$namingPrefix-SQL" -ErrorAction SilentlyContinue
if ($originalSqlVM) {
    $originalVhd = (Get-VMHardDiskDrive -VMName "$namingPrefix-SQL" | Select-Object -First 1).Path
    
    # Check if it's already using a differencing disk
    $vhdInfo = Get-VHD -Path $originalVhd -ErrorAction SilentlyContinue
    if ($vhdInfo -and $vhdInfo.VhdType -ne 'Differencing') {
        Write-Host "Converting original $namingPrefix-SQL to use a differencing disk..."
        
        # Stop the VM if running
        if ($originalSqlVM.State -eq 'Running') {
            Stop-VM -Name "$namingPrefix-SQL" -Force -TurnOff
            Start-Sleep -Seconds 5
        }
        
        # The original VHD becomes our parent. Create a differencing disk for the original VM.
        $originalDiffPath = "$Env:ArcBoxVMDir\$namingPrefix-SQL-diff.vhdx"
        if (-not (Test-Path $originalDiffPath)) {
            New-VHD -Path $originalDiffPath -ParentPath $originalVhd -Differencing | Out-Null
        }
        
        # Swap the original VM's disk to the differencing disk
        $diskDrive = Get-VMHardDiskDrive -VMName "$namingPrefix-SQL" | Select-Object -First 1
        Set-VMHardDiskDrive -VMName "$namingPrefix-SQL" -ControllerType $diskDrive.ControllerType -ControllerNumber $diskDrive.ControllerNumber -ControllerLocation $diskDrive.ControllerLocation -Path $originalDiffPath
        
        Write-Host "  Original VM now uses differencing disk: $originalDiffPath"
        Write-Host "  Parent VHD is now read-only (shared by all differencing disks)"
        
        # Start the original VM back up
        Start-VM -Name "$namingPrefix-SQL"
        Write-Host "  Original $namingPrefix-SQL VM restarted successfully."
    } else {
        Write-Host "Original $namingPrefix-SQL already uses a differencing disk (or is already converted)."
        # Ensure it's running
        if ($originalSqlVM.State -ne 'Running') {
            Start-VM -Name "$namingPrefix-SQL" -ErrorAction SilentlyContinue
        }
    }
    
    # Use the actual parent VHD path for our new differencing disks
    if ($vhdInfo -and $vhdInfo.VhdType -eq 'Differencing') {
        $parentSqlVhdPath = $vhdInfo.ParentPath
    } else {
        $parentSqlVhdPath = $originalVhd
    }
} else {
    Write-Host "No original $namingPrefix-SQL VM found (fresh deployment)."
    $parentSqlVhdPath = $null
}

# Same fix for ArcBox-Win2K22: convert to differencing disk so parent VHD is shared read-only
$originalWinVM = Get-VM -Name "$namingPrefix-Win2K22" -ErrorAction SilentlyContinue
if ($originalWinVM) {
    $originalWinVhd = (Get-VMHardDiskDrive -VMName "$namingPrefix-Win2K22" | Select-Object -First 1).Path
    
    $winVhdInfo = Get-VHD -Path $originalWinVhd -ErrorAction SilentlyContinue
    if ($winVhdInfo -and $winVhdInfo.VhdType -ne 'Differencing') {
        Write-Host "Converting original $namingPrefix-Win2K22 to use a differencing disk..."
        
        if ($originalWinVM.State -eq 'Running') {
            Stop-VM -Name "$namingPrefix-Win2K22" -Force -TurnOff
            Start-Sleep -Seconds 5
        }
        
        $originalWinDiffPath = "$Env:ArcBoxVMDir\$namingPrefix-Win2K22-diff.vhdx"
        if (-not (Test-Path $originalWinDiffPath)) {
            New-VHD -Path $originalWinDiffPath -ParentPath $originalWinVhd -Differencing | Out-Null
        }
        
        $winDiskDrive = Get-VMHardDiskDrive -VMName "$namingPrefix-Win2K22" | Select-Object -First 1
        Set-VMHardDiskDrive -VMName "$namingPrefix-Win2K22" -ControllerType $winDiskDrive.ControllerType -ControllerNumber $winDiskDrive.ControllerNumber -ControllerLocation $winDiskDrive.ControllerLocation -Path $originalWinDiffPath
        
        Write-Host "  Original Win2K22 VM now uses differencing disk: $originalWinDiffPath"
        
        Start-VM -Name "$namingPrefix-Win2K22"
        Write-Host "  Original $namingPrefix-Win2K22 VM restarted successfully."
        $parentWinVhdPath = $originalWinVhd
    } else {
        Write-Host "Original $namingPrefix-Win2K22 already uses a differencing disk (or is already converted)."
        if ($originalWinVM.State -ne 'Running') {
            Start-VM -Name "$namingPrefix-Win2K22" -ErrorAction SilentlyContinue
        }
        if ($winVhdInfo -and $winVhdInfo.VhdType -eq 'Differencing') {
            $parentWinVhdPath = $winVhdInfo.ParentPath
        } else {
            $parentWinVhdPath = $originalWinVhd
        }
    }
} else {
    $parentWinVhdPath = $null
}
#endregion

#region Extend DHCP Scope for additional VMs
Write-Header "Extending DHCP Scope"
$dhcpScope = Get-DhcpServerv4Scope
if ($dhcpScope.EndRange -ne '10.10.1.250') {
    Set-DhcpServerv4Scope -ScopeId $dhcpScope.ScopeId -EndRange 10.10.1.250
    Write-Host "Extended DHCP range to 10.10.1.250 for additional VMs"
}
#endregion

#region Create Differencing Disks for SQL Servers
Write-Header "Creating Differencing Disks for SQL Server VMs"

# Use the parent path we determined above, or find it
if (-not $parentSqlVhdPath) {
    $parentSqlVhd = Get-ChildItem "$Env:ArcBoxVMDir" -Filter "*SQL*.vhdx" | Where-Object { $_.Name -match "$namingPrefix-SQL\.vhdx" } | Select-Object -First 1
    if (-not $parentSqlVhd) {
        Write-Error "Parent SQL VHD not found. Ensure the base ArcBox deployment has completed."
        Stop-Transcript
        exit 1
    }
    $parentSqlVhdPath = $parentSqlVhd.FullName
}

Write-Host "Parent SQL VHD: $parentSqlVhdPath"

foreach ($sql in $sqlServers | Select-Object -First $SqlServerCount) {
    $diffDiskPath = "$Env:ArcBoxVMDir\$($sql.Name).vhdx"
    if (-not (Test-Path $diffDiskPath)) {
        Write-Host "Creating differencing disk for $($sql.Name)..."
        New-VHD -Path $diffDiskPath -ParentPath $parentSqlVhdPath -Differencing | Out-Null
        Write-Host "  Created: $diffDiskPath"
    } else {
        Write-Host "  Disk already exists: $diffDiskPath"
    }
}
#endregion

#region Create Differencing Disks for App Servers
Write-Header "Creating Differencing Disks for Application Server VMs"

# Use the parent path we determined above, or find it
if (-not $parentWinVhdPath) {
    $parentWinVhd = Get-ChildItem "$Env:ArcBoxVMDir" -Filter "*Win2K22*.vhdx" | Where-Object { $_.Name -match "$namingPrefix-Win2K22\.vhdx" } | Select-Object -First 1
    if (-not $parentWinVhd) {
        Write-Warning "Win2K22 parent VHD not found. Using SQL VHD as parent for app servers."
        $parentWinVhdPath = $parentSqlVhdPath
    } else {
        $parentWinVhdPath = $parentWinVhd.FullName
    }
}

Write-Host "Parent App Server VHD: $parentWinVhdPath"

foreach ($app in $appServers | Select-Object -First $AppServerCount) {
    $diffDiskPath = "$Env:ArcBoxVMDir\$($app.Name).vhdx"
    if (-not (Test-Path $diffDiskPath)) {
        Write-Host "Creating differencing disk for $($app.Name)..."
        New-VHD -Path $diffDiskPath -ParentPath $parentWinVhdPath -Differencing | Out-Null
        Write-Host "  Created: $diffDiskPath"
    } else {
        Write-Host "  Disk already exists: $diffDiskPath"
    }
}
#endregion

#region Deploy SQL Server VMs via DSC
Write-Header "Deploying SQL Server VMs"

$sqlDscFile = "$Env:ArcBoxDscDir\sql_servers.dsc.yml"
if (Test-Path $sqlDscFile) {
    (Get-Content -Path $sqlDscFile) -replace 'namingPrefixStage', $namingPrefix | Set-Content -Path $sqlDscFile
    winget configure --file $sqlDscFile --accept-configuration-agreements --disable-interactivity
} else {
    # Manual VM creation if DSC file not available
    foreach ($sql in $sqlServers | Select-Object -First $SqlServerCount) {
        $vmName = $sql.Name
        $vhdPath = "$Env:ArcBoxVMDir\$vmName.vhdx"

        if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
            Write-Host "Creating VM: $vmName"
            New-VM -Name $vmName `
                -MemoryStartupBytes 4GB `
                -Generation 2 `
                -VHDPath $vhdPath `
                -SwitchName 'InternalNATSwitch' `
                -Path "$Env:ArcBoxVMDir" | Out-Null

            Set-VM -Name $vmName -ProcessorCount 2 -AutomaticStopAction ShutDown -AutomaticStartAction Start
            Set-VMFirmware -VMName $vmName -EnableSecureBoot On
            Enable-VMIntegrationService -VMName $vmName -Name 'Guest Service Interface'
            Start-VM -Name $vmName
        } else {
            Write-Host "VM already exists: $vmName"
            if ((Get-VM -Name $vmName).State -ne 'Running') {
                Start-VM -Name $vmName
            }
        }
    }
}
#endregion

#region Deploy App Server VMs
Write-Header "Deploying Application Server VMs"

$appDscFile = "$Env:ArcBoxDscDir\app_servers.dsc.yml"
if (Test-Path $appDscFile) {
    (Get-Content -Path $appDscFile) -replace 'namingPrefixStage', $namingPrefix | Set-Content -Path $appDscFile
    winget configure --file $appDscFile --accept-configuration-agreements --disable-interactivity
} else {
    foreach ($app in $appServers | Select-Object -First $AppServerCount) {
        $vmName = $app.Name
        $vhdPath = "$Env:ArcBoxVMDir\$vmName.vhdx"

        if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
            Write-Host "Creating VM: $vmName"
            New-VM -Name $vmName `
                -MemoryStartupBytes 2GB `
                -Generation 2 `
                -VHDPath $vhdPath `
                -SwitchName 'InternalNATSwitch' `
                -Path "$Env:ArcBoxVMDir" | Out-Null

            Set-VM -Name $vmName -ProcessorCount 2 -AutomaticStopAction ShutDown -AutomaticStartAction Start
            Set-VMFirmware -VMName $vmName -EnableSecureBoot On
            Enable-VMIntegrationService -VMName $vmName -Name 'Guest Service Interface'
            Start-VM -Name $vmName
        } else {
            Write-Host "VM already exists: $vmName"
            if ((Get-VM -Name $vmName).State -ne 'Running') {
                Start-VM -Name $vmName
            }
        }
    }
}
#endregion

#region Wait for VMs to boot
Write-Header "Waiting for VMs to fully boot"

# All VMs boot with the parent's hostname (ArcBox-SQL). We connect using the parent
# hostname as the credential domain, then rename each VM to its unique name.
# PowerShell Direct's -VMName targets by Hyper-V name, so it works even when
# all guests have the same internal hostname.

function Wait-ForVMReady {
    param (
        [string]$VMName,
        [PSCredential]$Credential,
        [int]$TimeoutSeconds = 600
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $attempt = 0
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $attempt++
        try {
            $result = Invoke-Command -VMName $VMName -ScriptBlock { hostname } -Credential $Credential -ErrorAction Stop
            if ($result) {
                Write-Host "    READY (hostname: $result, attempt $attempt)" -ForegroundColor Green
                return $true
            }
        } catch {
            if ($attempt -le 3 -or $attempt % 10 -eq 0) {
                $errMsg = $_.Exception.Message
                Write-Host "    Attempt ${attempt}: $errMsg" -ForegroundColor DarkYellow
            }
        }
        Start-Sleep -Seconds 10
    }
    Write-Host "    TIMEOUT after $attempt attempts" -ForegroundColor Red
    return $false
}

# Smart wait: tries all credential types so it works regardless of VM state
function Wait-ForVMReadyAuto {
    param (
        [string]$VMName,
        [int]$TimeoutSeconds = 600
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $attempt = 0
    
    $credsToTry = @(
        $domainCred
        (Get-VMCredential -VMName $VMName)
        $initialCred
        (New-Object PSCredential("$namingPrefix-Win2K22\Administrator", $secWindowsPassword))
    )
    
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $attempt++
        foreach ($cred in $credsToTry) {
            try {
                $result = Invoke-Command -VMName $VMName -ScriptBlock { hostname } -Credential $cred -ErrorAction Stop
                if ($result) {
                    Write-Host "    READY (hostname: $result, cred: $($cred.UserName))" -ForegroundColor Green
                    return $true
                }
            } catch { }
        }
        if ($attempt -le 3 -or $attempt % 10 -eq 0) {
            Write-Host "    Attempt ${attempt}: no credential worked yet..." -ForegroundColor DarkYellow
        }
        Start-Sleep -Seconds 10
    }
    Write-Host "    TIMEOUT after $attempt attempts (tried all credential types)" -ForegroundColor Red
    return $false
}

Write-Host "Waiting for VMs to become responsive (this may take 3-5 minutes with 15 VMs)..."
Write-Host "Trying credentials: domain ($domainNetbios\Administrator), local (<VM>\Administrator), parent ($sqlParentHostname\Administrator)"
Write-Host ""

$readyVMs = @()
$failedVMs = @()

# Wait for all VMs using auto-credential detection
foreach ($sql in $sqlServers | Select-Object -First $SqlServerCount) {
    $vmName = $sql.Name
    Write-Host "  Waiting for ${vmName}..."
    $ready = Wait-ForVMReadyAuto -VMName $vmName -TimeoutSeconds 600
    if ($ready) { $readyVMs += $vmName } else { $failedVMs += $vmName }
}

foreach ($app in $appServers | Select-Object -First $AppServerCount) {
    $vmName = $app.Name
    Write-Host "  Waiting for ${vmName}..."
    $ready = Wait-ForVMReadyAuto -VMName $vmName -TimeoutSeconds 600
    if ($ready) { $readyVMs += $vmName } else { $failedVMs += $vmName }
}

Write-Host ""
Write-Host "VMs ready: $($readyVMs.Count) / $($SqlServerCount + $AppServerCount)"
if ($failedVMs.Count -gt 0) {
    Write-Warning "Failed VMs: $($failedVMs -join ', ')"
}

if ($readyVMs.Count -eq 0) {
    Write-Error "No VMs became responsive. Check Hyper-V Manager for VM states and verify credential manually."
    Stop-Transcript
    exit 1
}
#endregion

#region Rename VMs to unique hostnames
Write-Header "Renaming VMs to unique hostnames"

# Each VM currently has hostname 'ArcBox-SQL' (from parent). Rename to match Hyper-V name.
$renameNeeded = @()

foreach ($vmName in $readyVMs) {
    try {
        # Use auto-credential detection (works for fresh, renamed, or domain-joined VMs)
        $cred = Get-WorkingCredential -VMName $vmName
        if (-not $cred) {
            Write-Warning "  Skipping $vmName - no working credential found"
            continue
        }
        
        $currentHostname = Invoke-Command -VMName $vmName -ScriptBlock { hostname } -Credential $cred -ErrorAction Stop
        if ($currentHostname -ne $vmName) {
            Write-Host "  Renaming $vmName (currently: $currentHostname)..."
            Invoke-Command -VMName $vmName -ScriptBlock {
                # If domain-joined, force unjoin first (DC not reachable on isolated network)
                $cs = Get-WmiObject Win32_ComputerSystem
                if ($cs.PartOfDomain) {
                    # Flag 0 = don't try to disable machine account on DC
                    $cs.UnjoinDomainOrWorkgroup($null, $null, 0) | Out-Null
                }
                Rename-Computer -NewName $using:vmName -Force -Restart
            } -Credential $cred -ErrorAction Stop
            $renameNeeded += $vmName
        } else {
            Write-Host "  $vmName already has correct hostname." -ForegroundColor Green
        }
    } catch {
        $errMsg = $_.Exception.Message
        Write-Warning "  Could not rename ${vmName}: $errMsg"
    }
}

if ($renameNeeded.Count -gt 0) {
    Write-Host ""
    Write-Host "Waiting for $($renameNeeded.Count) VMs to reboot after rename (90 seconds)..."
    Start-Sleep -Seconds 90
    
    # Verify VMs are back with new hostnames
    Write-Host "Verifying VMs are back online with new hostnames..."
    foreach ($vmName in $renameNeeded) {
        $cred = Get-VMCredential -VMName $vmName
        $ready = Wait-ForVMReady -VMName $vmName -Credential $cred -TimeoutSeconds 120
        if (-not $ready) {
            Write-Warning "  $vmName did not come back after rename. May need manual intervention."
        }
    }
}

# Restart network adapters on all ready VMs to ensure DHCP works
Write-Host "Restarting network adapters..."
foreach ($vmName in $readyVMs) {
    $cred = Get-WorkingCredential -VMName $vmName
    try {
        Invoke-Command -VMName $vmName -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $cred -ErrorAction SilentlyContinue | Out-Null
    } catch { }
}

Start-Sleep -Seconds 30
#endregion

#region Join VMs to domain
Write-Header "Joining VMs to $domainName domain"

# DC IP for DNS configuration
$dcIP = '10.10.1.106'

# First, configure DNS on all VMs to point to the DC
Write-Host "Configuring DNS on VMs to point to domain controller ($dcIP)..."
foreach ($vmName in $readyVMs) {
    $cred = Get-WorkingCredential -VMName $vmName
    try {
        Invoke-Command -VMName $vmName -ScriptBlock {
            $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
            if ($adapter) {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $using:dcIP
            }
        } -Credential $cred -ErrorAction Stop
    } catch {
        $errMsg = $_.Exception.Message
        Write-Warning "  Could not set DNS on ${vmName}: $errMsg"
    }
}

Start-Sleep -Seconds 10

# Verify DC is reachable from a VM (with retry)
$dcReachable = $false
$testVM = $readyVMs | Select-Object -First 1
if ($testVM) {
    $testCred = Get-WorkingCredential -VMName $testVM
    for ($dnsAttempt = 1; $dnsAttempt -le 3; $dnsAttempt++) {
        try {
            $dnsTest = Invoke-Command -VMName $testVM -ScriptBlock {
                # Clear DNS cache and retry
                Clear-DnsClientCache
                Resolve-DnsName $using:domainName -ErrorAction Stop
            } -Credential $testCred -ErrorAction Stop
            if ($dnsTest) {
                Write-Host "Domain $domainName is resolvable from VMs." -ForegroundColor Green
                $dcReachable = $true
                break
            }
        } catch {
            $errMsg = $_.Exception.Message
            if ($dnsAttempt -lt 3) {
                Write-Host "  DNS attempt $dnsAttempt failed, retrying in 10s... ($errMsg)" -ForegroundColor Yellow
                Start-Sleep -Seconds 10
            } else {
                Write-Warning "DNS resolution failed from ${testVM}: $errMsg"
            }
        }
    }
}

if ($dcReachable) {
    $joinedVMs = @()
    # Build credential components to pass as strings (PSCredential can't serialize via $using: in PS Direct)
    $domainUser = "$domainNetbios\Administrator"
    $domainPass = $nestedWindowsPassword

    foreach ($vmName in $readyVMs) {
        $localCred = Get-WorkingCredential -VMName $vmName
        try {
            # Check if already domain-joined
            $domainStatus = Invoke-Command -VMName $vmName -ScriptBlock {
                (Get-WmiObject Win32_ComputerSystem).PartOfDomain
            } -Credential $localCred -ErrorAction Stop

            if ($domainStatus) {
                Write-Host "  $vmName is already domain-joined." -ForegroundColor Green
                continue
            }

            Write-Host "  Joining $vmName to $domainName..."
            Invoke-Command -VMName $vmName -ScriptBlock {
                $secPass = ConvertTo-SecureString $using:domainPass -AsPlainText -Force
                $cred = New-Object PSCredential($using:domainUser, $secPass)
                Add-Computer -DomainName $using:domainName -Credential $cred -Force -Restart
            } -Credential $localCred -ErrorAction Stop
            $joinedVMs += $vmName
        } catch {
            $errMsg = $_.Exception.Message
            Write-Warning "  Failed to join ${vmName}: $errMsg"
        }
    }

    if ($joinedVMs.Count -gt 0) {
        Write-Host ""
        Write-Host "Waiting for $($joinedVMs.Count) VMs to reboot after domain join (90 seconds)..."
        Start-Sleep -Seconds 90

        # Verify VMs are back online
        Write-Host "Verifying VMs are back online after domain join..."
        foreach ($vmName in $joinedVMs) {
            $cred = Get-WorkingCredential -VMName $vmName
            $ready = Wait-ForVMReady -VMName $vmName -Credential $cred -TimeoutSeconds 120
            if ($ready) {
                Write-Host "  $vmName rejoined domain and online." -ForegroundColor Green
            } else {
                Write-Warning "  $vmName did not come back after domain join."
            }
        }
    }

    Write-Host "Domain join complete."
} else {
    Write-Warning "Domain controller not reachable from VMs. Skipping domain join."
    Write-Warning "Ensure DC at $dcIP is running and DNS zone for $domainName exists."
}
#endregion

#region Configure SQL Server Instances
Write-Header "Configuring SQL Server Instances and Databases"

# Create SQL data directory on each VM
foreach ($sql in $sqlServers | Select-Object -First $SqlServerCount) {
    $vmName = $sql.Name
    $sqlSetupScript = "$ExtendedLabDir\$($sql.DB).sql"

    try {
        Write-Host "Configuring $vmName - $($sql.Role)..."

        $cred = Get-WorkingCredential -VMName $vmName

        # Create data directory
        Invoke-Command -VMName $vmName -ScriptBlock {
            if (-not (Test-Path 'C:\SQLData')) { New-Item -Path 'C:\SQLData' -ItemType Directory -Force | Out-Null }
        } -Credential $cred -ErrorAction Stop

        # Enable TCP/IP and open firewall
        Invoke-Command -VMName $vmName -ScriptBlock {
            # Open SQL port
            New-NetFirewallRule -DisplayName 'Allow SQL Server TCP 1433' -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow -ErrorAction SilentlyContinue | Out-Null

            # Enable TCP/IP protocol
            $sqlInstance = "MSSQLSERVER"
            try {
                $managedComputer = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer
                $serverProtocols = $managedComputer.ServerInstances[$sqlInstance].ServerProtocols
                $tcpProtocol = $serverProtocols | Where-Object { $_.Name -eq "TCP" }
                if ($tcpProtocol -and -not $tcpProtocol.IsEnabled) {
                    $tcpProtocol.IsEnabled = $true
                    $tcpProtocol.Alter()
                    Restart-Service -Name $sqlInstance -Force
                }
            } catch {
                Write-Warning "TCP/IP configuration: $_"
            }
        } -Credential $cred -ErrorAction Stop

        # Copy and execute database setup script
        if (Test-Path $sqlSetupScript) {
            Copy-VMFile $vmName -SourcePath $sqlSetupScript -DestinationPath "C:\ArcBox\dbsetup.sql" -CreateFullPath -FileSource Host -Force
            Invoke-Command -VMName $vmName -ScriptBlock {
                try {
                    Invoke-Sqlcmd -InputFile "C:\ArcBox\dbsetup.sql" -TrustServerCertificate -QueryTimeout 300
                    Write-Host "Database setup complete on $env:COMPUTERNAME"
                } catch {
                    Write-Warning "Database setup error: $_"
                }
            } -Credential $cred -ErrorAction Stop
        }

        # Grant domain admin sysadmin permissions on SQL Server
        $domainAdmin = "$domainNetbios\Administrator"
        Invoke-Command -VMName $vmName -ScriptBlock {
            try {
                $login = Invoke-Sqlcmd -Query "SELECT name FROM sys.server_principals WHERE name = '$using:domainAdmin'" -TrustServerCertificate
                if (-not $login) {
                    Invoke-Sqlcmd -Query "CREATE LOGIN [$using:domainAdmin] FROM WINDOWS; ALTER SERVER ROLE sysadmin ADD MEMBER [$using:domainAdmin];" -TrustServerCertificate
                } else {
                    Invoke-Sqlcmd -Query "ALTER SERVER ROLE sysadmin ADD MEMBER [$using:domainAdmin];" -TrustServerCertificate -ErrorAction SilentlyContinue
                }
                Write-Host "  Granted sysadmin to $using:domainAdmin on $env:COMPUTERNAME"
            } catch {
                Write-Warning "  Could not grant sysadmin on ${env:COMPUTERNAME}: $_"
            }
        } -Credential $cred -ErrorAction Stop

        Write-Host "  $vmName configured successfully."
    } catch {
        Write-Warning "Error configuring ${vmName}: $_"
    }
}

# Grant APP server machine accounts access to their target SQL databases
Write-Host ""
Write-Host "Granting APP server machine accounts access to SQL databases..."
foreach ($app in $appServers | Select-Object -First $AppServerCount) {
    $appName = $app.Name
    $sqlTarget = $app.ConnectsTo
    $machineAccount = "${domainNetbios}\${appName}$"
    $targetDB = ($sqlServers | Where-Object { $_.Name -eq $sqlTarget }).DB

    try {
        $sqlCred = Get-WorkingCredential -VMName $sqlTarget
        Invoke-Command -VMName $sqlTarget -ScriptBlock {
            $account = $using:machineAccount
            $db = $using:targetDB
            try {
                # Create server login if not exists
                $loginQuery = "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$account') CREATE LOGIN [$account] FROM WINDOWS WITH DEFAULT_DATABASE = [$db];"
                Invoke-Sqlcmd -Query $loginQuery -TrustServerCertificate -ErrorAction Stop

                # Create database user if not exists
                $userQuery = "USE [$db]; IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$account') CREATE USER [$account] FOR LOGIN [$account];"
                Invoke-Sqlcmd -Query $userQuery -TrustServerCertificate -ErrorAction Stop

                # Grant roles
                Invoke-Sqlcmd -Query "USE [$db]; ALTER ROLE db_datareader ADD MEMBER [$account];" -TrustServerCertificate -ErrorAction Stop
                Invoke-Sqlcmd -Query "USE [$db]; ALTER ROLE db_datawriter ADD MEMBER [$account];" -TrustServerCertificate -ErrorAction Stop

                Write-Host "  Granted $account access to $db on $env:COMPUTERNAME"
            } catch {
                Write-Warning "  Could not grant machine account $account on ${env:COMPUTERNAME}: $_"
            }
        } -Credential $sqlCred -ErrorAction Stop
    } catch {
        Write-Warning "  Failed to configure machine account for ${appName} on ${sqlTarget}: $_"
    }
}
#endregion

#region Configure Application Servers
if (-not $SkipAppDeployment) {
    Write-Header "Deploying Demo Applications on App Servers"

    foreach ($app in $appServers | Select-Object -First $AppServerCount) {
        $vmName = $app.Name
        $sqlTarget = $app.ConnectsTo

        try {
            Write-Host "Configuring $vmName - $($app.Role) (connects to $sqlTarget)..."

            $cred = Get-WorkingCredential -VMName $vmName

            # Verify hostname (should already be correct from rename step)
            $hostname = Invoke-Command -VMName $vmName -ScriptBlock { hostname } -Credential $cred -ErrorAction Stop
            if ($hostname -ne $vmName) {
                Write-Host "    Note: hostname is '$hostname', expected '$vmName'. Renaming..."
                Invoke-Command -VMName $vmName -ScriptBlock { Rename-Computer -NewName $using:vmName -Force -Restart } -Credential $cred
                Start-Sleep -Seconds 45
                $cred = Get-WorkingCredential -VMName $vmName
            }

            # Install IIS and .NET
            Invoke-Command -VMName $vmName -ScriptBlock {
                Install-WindowsFeature -Name Web-Server, Web-Asp-Net45, Web-Net-Ext45, NET-Framework-45-Features -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null
                Write-Host "IIS and .NET installed on $env:COMPUTERNAME"
            } -Credential $cred -ErrorAction Stop

            # Deploy connection test app
            $appConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <connectionStrings>
    <add name="DefaultConnection"
         connectionString="Server=$sqlTarget;Database=$($sqlServers | Where-Object { $_.Name -eq $sqlTarget } | Select-Object -ExpandProperty DB);Trusted_Connection=True;TrustServerCertificate=True;"
         providerName="System.Data.SqlClient" />
  </connectionStrings>
  <appSettings>
    <add key="AppName" value="$($app.Role)" />
    <add key="Environment" value="Demo" />
    <add key="SQLServer" value="$sqlTarget" />
  </appSettings>
</configuration>
"@
            $appConfigPath = "$ExtendedLabDir\$vmName-web.config"
            $appConfig | Set-Content -Path $appConfigPath -Force

            Copy-VMFile $vmName -SourcePath $appConfigPath -DestinationPath "C:\inetpub\wwwroot\web.config" -CreateFullPath -FileSource Host -Force -ErrorAction SilentlyContinue

            # Deploy a simple health-check / connectivity test page
            $healthPage = @"
<%@ Page Language="C#" %>
<%@ Import Namespace="System.Data.SqlClient" %>
<!DOCTYPE html>
<html>
<head><title>$($app.Role) - Health Check</title></head>
<body>
<h1>$($app.Role)</h1>
<h2>Application Server: $vmName</h2>
<h3>SQL Backend: $sqlTarget</h3>
<hr/>
<%
try {
    string connStr = System.Configuration.ConfigurationManager.ConnectionStrings["DefaultConnection"].ConnectionString;
    using (SqlConnection conn = new SqlConnection(connStr)) {
        conn.Open();
        Response.Write("<p style='color:green;font-weight:bold;'>&#x2705; Database connection SUCCESSFUL</p>");
        Response.Write("<p>Server Version: " + conn.ServerVersion + "</p>");
        Response.Write("<p>Database: " + conn.Database + "</p>");

        SqlCommand cmd = new SqlCommand("SELECT DB_NAME() AS CurrentDB, @@SERVERNAME AS ServerName, @@VERSION AS Version", conn);
        SqlDataReader reader = cmd.ExecuteReader();
        if (reader.Read()) {
            Response.Write("<p>Connected to: " + reader["ServerName"].ToString() + "</p>");
        }
        reader.Close();
    }
} catch (Exception ex) {
    Response.Write("<p style='color:red;font-weight:bold;'>&#x274C; Database connection FAILED</p>");
    Response.Write("<p>Error: " + ex.Message + "</p>");
}
%>
<hr/>
<p><small>Generated: <%= DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") %> | Server: <%= Environment.MachineName %></small></p>
</body>
</html>
"@
            $healthPagePath = "$ExtendedLabDir\$vmName-default.aspx"
            $healthPage | Set-Content -Path $healthPagePath -Force
            Copy-VMFile $vmName -SourcePath $healthPagePath -DestinationPath "C:\inetpub\wwwroot\default.aspx" -CreateFullPath -FileSource Host -Force

            # Deploy a PERSISTENT background workload that maintains active SQL connections
            # This creates visible netstat connections (TCP 1433) from app server to SQL server
            $targetDB = $sqlServers | Where-Object { $_.Name -eq $sqlTarget } | Select-Object -ExpandProperty DB
            $bgWorkload = @"
# Background SQL Workload - $($app.Role)
# Maintains persistent connections to $sqlTarget for demo visibility
`$ErrorActionPreference = 'SilentlyContinue'
`$sqlServer = '$sqlTarget'
`$database = '$targetDB'
`$connString = "Server=`$sqlServer;Database=`$database;Trusted_Connection=True;TrustServerCertificate=True;"

while (`$true) {
    try {
        # Open a connection and run periodic queries (simulates app activity)
        `$conn = New-Object System.Data.SqlClient.SqlConnection(`$connString)
        `$conn.Open()
        
        # Keep connection alive with periodic queries for 60 seconds
        for (`$i = 0; `$i -lt 12; `$i++) {
            `$cmd = `$conn.CreateCommand()
            `$cmd.CommandText = "SELECT COUNT(*) FROM sys.tables; WAITFOR DELAY '00:00:05';"
            `$cmd.ExecuteScalar() | Out-Null
        }
        
        `$conn.Close()
    } catch {
        Start-Sleep -Seconds 10
    }
    Start-Sleep -Seconds 2
}
"@
            $bgWorkloadPath = "$ExtendedLabDir\$vmName-workload.ps1"
            $bgWorkload | Set-Content -Path $bgWorkloadPath -Force
            Copy-VMFile $vmName -SourcePath $bgWorkloadPath -DestinationPath "C:\ArcBox\app-workload.ps1" -CreateFullPath -FileSource Host -Force

            # Register and start the background workload as a scheduled task (runs continuously)
            Invoke-Command -VMName $vmName -ScriptBlock {
                # Open firewall for SQL outbound (usually open, but ensure)
                New-NetFirewallRule -DisplayName 'Allow SQL Outbound 1433' -Direction Outbound -Protocol TCP -RemotePort 1433 -Action Allow -ErrorAction SilentlyContinue | Out-Null

                # Create a scheduled task that runs the workload script at startup and continuously
                $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ArcBox\app-workload.ps1'
                $trigger = New-ScheduledTaskTrigger -AtStartup
                $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 999 -ExecutionTimeLimit ([TimeSpan]::Zero)
                Register-ScheduledTask -TaskName 'AppSQLWorkload' -Action $action -Trigger $trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null

                # Start it immediately
                Start-ScheduledTask -TaskName 'AppSQLWorkload'
                Write-Host "Background SQL workload started on $env:COMPUTERNAME"
            } -Credential $cred -ErrorAction Stop

            Write-Host "  $vmName app deployment complete (persistent SQL connections active)."
        } catch {
            Write-Warning "Error configuring app server ${vmName}: $_"
        }
    }
}
#endregion

#region Azure Arc Onboarding
if (-not $SkipArcOnboarding) {
    Write-Header "Onboarding VMs to Azure Arc"

    # --- Pre-flight: Verify Azure authentication ---
    # This script MUST run on the ArcBox Client VM which has a managed identity.
    # If running manually, ensure you've authenticated first:
    #   az login --identity   (on Client VM with managed identity)
    #   az login              (interactive, if no managed identity)
    #   Connect-AzAccount     (for Az PowerShell)

    Write-Host "Authenticating to Azure..."

    # Try managed identity first, fall back to checking existing context
    $azContext = $null
    try {
        $loginResult = az login --identity 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Managed identity login failed. Checking for existing Azure CLI session..."
            $accountShow = az account show 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Error @"
Azure authentication failed. This script requires Azure credentials.
If running on the ArcBox Client VM: ensure the VM has a system-assigned managed identity with Contributor role.
If running interactively: run 'az login' and 'Connect-AzAccount' before executing this script.
"@
                Stop-Transcript
                exit 1
            }
        }
        az account set -s $subscriptionId
        Write-Host "  Azure CLI authenticated successfully."
    } catch {
        Write-Error "Azure CLI authentication failed: $_"
        Stop-Transcript
        exit 1
    }

    try {
        $azContext = Get-AzContext
        if (-not $azContext) {
            Connect-AzAccount -Identity -Tenant $tenantId -Subscription $subscriptionId -ErrorAction Stop
        } else {
            Set-AzContext -Subscription $subscriptionId -ErrorAction Stop | Out-Null
        }
        Write-Host "  Az PowerShell authenticated successfully."
    } catch {
        Write-Warning "Az PowerShell auth via managed identity failed. Trying existing context..."
        try {
            Connect-AzAccount -Tenant $tenantId -Subscription $subscriptionId -ErrorAction Stop
        } catch {
            Write-Error "Az PowerShell authentication failed. Run 'Connect-AzAccount' manually first."
            Stop-Transcript
            exit 1
        }
    }

    # Helper function to get a fresh access token (tokens expire after ~60 min)
    function Get-FreshAccessToken {
        $token = ConvertFrom-SecureString ((Get-AzAccessToken -AsSecureString).Token) -AsPlainText
        if (-not $token) {
            throw "Failed to acquire access token. Ensure Azure authentication is valid."
        }
        return $token
    }

    # Get initial token and verify it works
    try {
        $accessToken = Get-FreshAccessToken
        Write-Host "  Access token acquired successfully."
    } catch {
        Write-Error "Failed to get access token: $_. Run 'Connect-AzAccount' first."
        Stop-Transcript
        exit 1
    }

    # --- Verify RBAC: Managed identity needs 'Azure Connected Machine Onboarding' or 'Contributor' ---
    Write-Host "  Verifying RBAC permissions for Arc onboarding..."
    $clientVmIdentity = (Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/' -Method GET -Headers @{Metadata='true'} -ErrorAction SilentlyContinue)
    if (-not $clientVmIdentity) {
        Write-Warning "Could not query VM metadata for managed identity. Proceeding anyway (may fail if permissions are missing)."
    }

    $roleAssignments = az role assignment list --resource-group $resourceGroup --query "[?principalType=='ServicePrincipal']" -o json 2>$null | ConvertFrom-Json
    $requiredRoles = @('Contributor', 'Owner', 'Azure Connected Machine Onboarding', 'Azure Connected Machine Resource Administrator')
    $vmPrincipalId = (az vm show --resource-group $resourceGroup --name "$namingPrefix-Client" --query "identity.principalId" -o tsv 2>$null)

    if ($vmPrincipalId) {
        $vmRoles = $roleAssignments | Where-Object { $_.principalId -eq $vmPrincipalId } | Select-Object -ExpandProperty roleDefinitionName
        $hasPermission = $vmRoles | Where-Object { $_ -in $requiredRoles }
        if ($hasPermission) {
            Write-Host "  Client VM identity has sufficient role: $($hasPermission -join ', ')" -ForegroundColor Green
        } else {
            Write-Warning @"
  Client VM managed identity does NOT have Arc onboarding permissions!
  Current roles: $($vmRoles -join ', ')
  Required (one of): $($requiredRoles -join ', ')

  To fix, run from a privileged session:
    az role assignment create --assignee $vmPrincipalId --role 'Azure Connected Machine Onboarding' --resource-group $resourceGroup
    az role assignment create --assignee $vmPrincipalId --role 'Azure Connected Machine Resource Administrator' --resource-group $resourceGroup
"@
            $continueChoice = Read-Host "Continue anyway? (y/n)"
            if ($continueChoice -ne 'y') {
                Write-Host "Aborting. Fix permissions and re-run."
                Stop-Transcript
                exit 1
            }
        }
    } else {
        Write-Warning "  Could not determine Client VM principal ID. Ensure managed identity is assigned."
    }

    # Opt out of automatic SQL extension deployment (we'll do it manually)
    az tag create --resource-id "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup" --tags ArcSQLServerExtensionDeployment=Disabled 2>&1 | Out-Null

    # Onboard all SQL VMs (refresh token every 5 VMs to avoid expiry)
    # NOTE: Parameter passing uses comma-separated syntax to match ArcBox's working pattern
    $vmCounter = 0
    foreach ($sql in $sqlServers | Select-Object -First $SqlServerCount) {
        $vmName = $sql.Name
        $vmCounter++

        # Refresh token every 5 VMs to avoid expiry during long onboarding
        if ($vmCounter % 5 -eq 1) {
            Write-Host "  Refreshing access token..."
            $accessToken = Get-FreshAccessToken
        }

        Write-Host "Onboarding $vmName to Azure Arc... ($vmCounter of $SqlServerCount)"

        try {
            # Copy and run Arc agent install script
            Copy-VMFileWithRetry -VMName $vmName -SourcePath "$Env:ArcBoxDir\agentScript\installArcAgent.ps1" -DestinationPath "C:\ArcBox\installArcAgent.ps1"

            # Use the same comma-separated parameter pattern as the base ArcBox script
            Invoke-Command -VMName $vmName -ScriptBlock { powershell -File C:\ArcBox\installArcAgent.ps1 -accessToken $using:accessToken, -tenantId $using:tenantId, -subscriptionId $using:subscriptionId, -resourceGroup $using:resourceGroup, -azureLocation $using:azureLocation } -Credential (Get-WorkingCredential -VMName $vmName) -ErrorAction Stop

            Write-Host "  $vmName Arc onboarding initiated."
        } catch {
            Write-Warning "Arc onboarding failed for ${vmName}: $_"
        }
    }

    # Onboard App Servers (refresh token before starting app servers)
    Write-Host "  Refreshing access token for App Server onboarding..."
    $accessToken = Get-FreshAccessToken

    foreach ($app in $appServers | Select-Object -First $AppServerCount) {
        $vmName = $app.Name
        Write-Host "Onboarding $vmName to Azure Arc..."

        try {
            Copy-VMFileWithRetry -VMName $vmName -SourcePath "$Env:ArcBoxDir\agentScript\installArcAgent.ps1" -DestinationPath "C:\ArcBox\installArcAgent.ps1"

            Invoke-Command -VMName $vmName -ScriptBlock { powershell -File C:\ArcBox\installArcAgent.ps1 -accessToken $using:accessToken, -tenantId $using:tenantId, -subscriptionId $using:subscriptionId, -resourceGroup $using:resourceGroup, -azureLocation $using:azureLocation } -Credential (Get-WorkingCredential -VMName $vmName) -ErrorAction Stop

            Write-Host "  $vmName Arc onboarding initiated."
        } catch {
            Write-Warning "Arc onboarding failed for ${vmName}: $_"
        }
    }

    # Wait for Arc onboarding to complete
    Write-Host "Waiting for Arc onboarding to complete (120 seconds)..."
    Start-Sleep -Seconds 120

    # Install SQL Server extension on SQL VMs
    Write-Header "Installing SQL Server Arc Extension"

    foreach ($sql in $sqlServers | Select-Object -First $SqlServerCount) {
        $vmName = $sql.Name
        Write-Host "Installing SQL extension on $vmName..."

        $retryCount = 0
        do {
            $arcServer = Get-AzConnectedMachine -Name $vmName -ResourceGroupName $resourceGroup -ErrorAction SilentlyContinue
            if ($arcServer -and $arcServer.ProvisioningState -eq 'Succeeded') {
                az connectedmachine extension create `
                    --machine-name $vmName `
                    --name 'WindowsAgent.SqlServer' `
                    --resource-group $resourceGroup `
                    --type 'WindowsAgent.SqlServer' `
                    --publisher 'Microsoft.AzureData' `
                    --settings '{\"LicenseType\":\"Paid\", \"SqlManagement\": {\"IsEnabled\":true}}' `
                    --tags $resourceTags `
                    --location $azureLocation `
                    --only-show-errors --no-wait
                Write-Host "  SQL extension install initiated on $vmName"
                break
            } else {
                $retryCount++
                if ($retryCount -ge 5) {
                    Write-Warning "  Timeout waiting for Arc onboarding of $vmName"
                    break
                }
                Write-Host "  Waiting for Arc onboarding... (attempt $retryCount)"
                Start-Sleep -Seconds 30
            }
        } while ($retryCount -lt 5)
    }

    # Install Azure Monitor Agent on all VMs
    Write-Header "Installing Azure Monitor Agent"

    $allVMs = ($sqlServers | Select-Object -First $SqlServerCount) + ($appServers | Select-Object -First $AppServerCount)
    foreach ($vm in $allVMs) {
        $vmName = $vm.Name
        Write-Host "Installing AMA on $vmName..."
        az connectedmachine extension create `
            --machine-name $vmName `
            --name AzureMonitorWindowsAgent `
            --publisher Microsoft.Azure.Monitor `
            --type AzureMonitorWindowsAgent `
            --resource-group $resourceGroup `
            --location $azureLocation `
            --only-show-errors --no-wait
    }
}
#endregion

#region Run Migration Assessments
if (-not $SkipArcOnboarding) {
    Write-Header "Triggering SQL Migration Assessments"

    $token = (az account get-access-token --subscription $subscriptionId --query accessToken --output tsv)
    $headers = @{'Authorization' = "Bearer $token"; 'Content-Type' = 'application/json' }

    foreach ($sql in $sqlServers | Select-Object -First $SqlServerCount) {
        $vmName = $sql.Name
        Write-Host "Triggering migration assessment for $vmName..."

        try {
            $migrationApiURL = 'https://management.azure.com/batch?api-version=2020-06-01'
            $assessmentName = (New-Guid).Guid
            $payload = @"
{"requests":[{"httpMethod":"POST","name":"$assessmentName","requestHeaderDetails":{"commandName":"Microsoft_Azure_HybridData_Platform."},"url":"https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.AzureArcData/SqlServerInstances/$vmName/runMigrationAssessment?api-version=2024-05-01-preview"}]}
"@
            $response = Invoke-WebRequest -Method Post -Uri $migrationApiURL -Body $payload -Headers $headers -ErrorAction SilentlyContinue
            if ($response.StatusCode -in @(200, 202)) {
                Write-Host "  Assessment triggered for $vmName"
            }
        } catch {
            Write-Warning "  Assessment trigger failed for ${vmName}: $_"
        }
    }
}
#endregion

#region Tag Arc Resources by Application
if (-not $SkipArcOnboarding) {
    Write-Header "Tagging Arc Resources by Application"

    # Define application groupings with tags
    $appGroupings = @(
        @{ Application = "ERP-Finance"; Environment = "Production"; Servers = @("$namingPrefix-SQL01", "$namingPrefix-APP01") }
        @{ Application = "CRM"; Environment = "Production"; Servers = @("$namingPrefix-SQL02", "$namingPrefix-APP02") }
        @{ Application = "HR-Payroll"; Environment = "Production"; Servers = @("$namingPrefix-SQL03", "$namingPrefix-APP03") }
        @{ Application = "Inventory-WMS"; Environment = "Production"; Servers = @("$namingPrefix-SQL04") }
        @{ Application = "E-Commerce"; Environment = "Production"; Servers = @("$namingPrefix-SQL05", "$namingPrefix-APP04") }
        @{ Application = "Analytics"; Environment = "Production"; Servers = @("$namingPrefix-SQL06", "$namingPrefix-APP05") }
        @{ Application = "Document-Management"; Environment = "Production"; Servers = @("$namingPrefix-SQL07") }
        @{ Application = "Legacy-LOB"; Environment = "Production"; Servers = @("$namingPrefix-SQL08") }
        @{ Application = "DevTest"; Environment = "Development"; Servers = @("$namingPrefix-SQL09") }
        @{ Application = "Compliance-Audit"; Environment = "Production"; Servers = @("$namingPrefix-SQL10") }
    )

    foreach ($group in $appGroupings) {
        foreach ($serverName in $group.Servers) {
            $tier = if ($serverName -match 'SQL') { "Database" } else { "Application" }
            $tags = @{
                Application = $group.Application
                Environment = $group.Environment
                Tier        = $tier
            }

            try {
                $arcServer = Get-AzConnectedMachine -Name $serverName -ResourceGroupName $resourceGroup -ErrorAction SilentlyContinue
                if ($arcServer) {
                    Update-AzConnectedMachine -Name $serverName -ResourceGroupName $resourceGroup -Tag $tags -ErrorAction Stop | Out-Null
                    Write-Host "  Tagged $serverName -> Application: $($group.Application), Tier: $tier, Env: $($group.Environment)"
                } else {
                    Write-Warning "  $serverName not found in Arc (skipping tags)"
                }
            } catch {
                Write-Warning "  Could not tag ${serverName}: $_"
            }
        }
    }

    Write-Host "Tagging complete."
}
#endregion

#region Summary
Write-Header "Deployment Summary"

Write-Host "SQL Servers Deployed:"
foreach ($sql in $sqlServers | Select-Object -First $SqlServerCount) {
    $vmState = (Get-VM -Name $sql.Name -ErrorAction SilentlyContinue).State
    Write-Host "  $($sql.Name) | $($sql.Role) | DB: $($sql.DB) | State: $vmState"
}

Write-Host ""
Write-Host "Application Servers Deployed:"
foreach ($app in $appServers | Select-Object -First $AppServerCount) {
    $vmState = (Get-VM -Name $app.Name -ErrorAction SilentlyContinue).State
    Write-Host "  $($app.Name) | $($app.Role) | Connects to: $($app.ConnectsTo) | State: $vmState"
}

Write-Host ""
Write-Host "Total VMs: $($SqlServerCount + $AppServerCount)"
Write-Host "Deployment completed at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
#endregion

try { Stop-Transcript } catch { }
