<#
.SYNOPSIS
    Validates the Extended SQL Lab deployment by checking VM states,
    SQL connectivity, and Arc onboarding status.

.DESCRIPTION
    Run this script after Deploy-ExtendedSQLLab.ps1 to verify all
    components are healthy and ready for demonstration.
#>

param (
    [switch]$Detailed
)

$namingPrefix = $env:namingPrefix
if (-not $namingPrefix) { $namingPrefix = 'ArcBox' }

$nestedWindowsUsername = 'Administrator'
$nestedWindowsPassword = 'JS123!!'
$secWindowsPassword = ConvertTo-SecureString $nestedWindowsPassword -AsPlainText -Force
$winCreds = New-Object System.Management.Automation.PSCredential ($nestedWindowsUsername, $secWindowsPassword)

$sqlVMs = 1..10 | ForEach-Object { "$namingPrefix-SQL$($_.ToString('00'))" }
$appVMs = 1..5 | ForEach-Object { "$namingPrefix-APP$($_.ToString('00'))" }

Write-Host "=" * 60
Write-Host " Extended ArcBox SQL Lab - Validation Report"
Write-Host " $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "=" * 60
Write-Host ""

#region VM State Check
Write-Host "--- Hyper-V VM Status ---" -ForegroundColor Cyan
$allVMs = $sqlVMs + $appVMs
$runningCount = 0
$totalCount = $allVMs.Count

foreach ($vmName in $allVMs) {
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($vm) {
        $status = $vm.State
        $color = if ($status -eq 'Running') { 'Green' } else { 'Red' }
        if ($status -eq 'Running') { $runningCount++ }
        Write-Host "  $vmName : $status" -ForegroundColor $color
    } else {
        Write-Host "  $vmName : NOT FOUND" -ForegroundColor Red
    }
}
Write-Host ""
Write-Host "  VMs Running: $runningCount / $totalCount" -ForegroundColor $(if ($runningCount -eq $totalCount) { 'Green' } else { 'Yellow' })
Write-Host ""
#endregion

#region SQL Connectivity Check
Write-Host "--- SQL Server Connectivity ---" -ForegroundColor Cyan
$sqlConnected = 0

foreach ($vmName in $sqlVMs) {
    try {
        $result = Invoke-Command -VMName $vmName -ScriptBlock {
            try {
                $r = Invoke-Sqlcmd -Query "SELECT @@SERVERNAME AS ServerName, @@VERSION AS Version" -TrustServerCertificate -QueryTimeout 10
                return @{ Success = $true; Server = $r.ServerName; Version = ($r.Version -split "`n")[0] }
            } catch {
                return @{ Success = $false; Error = $_.Exception.Message }
            }
        } -Credential $winCreds -ErrorAction Stop

        if ($result.Success) {
            $sqlConnected++
            Write-Host "  $vmName : CONNECTED - $($result.Server)" -ForegroundColor Green
            if ($Detailed) { Write-Host "    $($result.Version)" -ForegroundColor Gray }
        } else {
            Write-Host "  $vmName : SQL ERROR - $($result.Error)" -ForegroundColor Red
        }
    } catch {
        Write-Host "  $vmName : UNREACHABLE" -ForegroundColor Red
    }
}
Write-Host ""
Write-Host "  SQL Connected: $sqlConnected / $($sqlVMs.Count)" -ForegroundColor $(if ($sqlConnected -eq $sqlVMs.Count) { 'Green' } else { 'Yellow' })
Write-Host ""
#endregion

#region Database Check
Write-Host "--- Database Inventory ---" -ForegroundColor Cyan

foreach ($vmName in $sqlVMs) {
    try {
        $dbs = Invoke-Command -VMName $vmName -ScriptBlock {
            try {
                Invoke-Sqlcmd -Query "SELECT name, state_desc, compatibility_level FROM sys.databases WHERE database_id > 4" -TrustServerCertificate -QueryTimeout 10
            } catch { }
        } -Credential $winCreds -ErrorAction SilentlyContinue

        if ($dbs) {
            $dbNames = ($dbs | ForEach-Object { $_.name }) -join ', '
            Write-Host "  $vmName : $dbNames" -ForegroundColor Green
        } else {
            Write-Host "  $vmName : No user databases found" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  $vmName : Unable to query" -ForegroundColor Red
    }
}
Write-Host ""
#endregion

#region Arc Onboarding Check
Write-Host "--- Azure Arc Status ---" -ForegroundColor Cyan
$arcConnected = 0

try {
    $resourceGroup = $env:resourceGroup
    if ($resourceGroup) {
        foreach ($vmName in $allVMs) {
            $arcMachine = Get-AzConnectedMachine -Name $vmName -ResourceGroupName $resourceGroup -ErrorAction SilentlyContinue
            if ($arcMachine -and $arcMachine.Status -eq 'Connected') {
                $arcConnected++
                Write-Host "  $vmName : Arc Connected" -ForegroundColor Green

                # Check SQL extension
                $sqlExt = $arcMachine | Select-Object -ExpandProperty Resource -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'WindowsAgent.SqlServer' }
                if ($sqlExt) {
                    Write-Host "    SQL Extension: $($sqlExt.ProvisioningState)" -ForegroundColor Gray
                }
            } else {
                Write-Host "  $vmName : Not connected to Arc" -ForegroundColor Yellow
            }
        }
        Write-Host ""
        Write-Host "  Arc Connected: $arcConnected / $totalCount" -ForegroundColor $(if ($arcConnected -eq $totalCount) { 'Green' } else { 'Yellow' })
    } else {
        Write-Host "  Skipped - resourceGroup environment variable not set" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  Azure context not available. Run 'Connect-AzAccount' first." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region Summary
Write-Host "=" * 60
Write-Host " SUMMARY"
Write-Host "=" * 60
Write-Host "  VMs Running:     $runningCount / $totalCount"
Write-Host "  SQL Connected:   $sqlConnected / $($sqlVMs.Count)"
Write-Host "  Arc Onboarded:   $arcConnected / $totalCount"

$overallStatus = if ($runningCount -eq $totalCount -and $sqlConnected -eq $sqlVMs.Count) { "READY FOR DEMO" } else { "ISSUES DETECTED" }
$statusColor = if ($overallStatus -eq "READY FOR DEMO") { 'Green' } else { 'Yellow' }
Write-Host ""
Write-Host "  Status: $overallStatus" -ForegroundColor $statusColor
Write-Host "=" * 60
#endregion
