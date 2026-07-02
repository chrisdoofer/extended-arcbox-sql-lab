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
$nestedWindowsUsername = 'Administrator'
$nestedWindowsPassword = 'JS123!!'
$secWindowsPassword = ConvertTo-SecureString $nestedWindowsPassword -AsPlainText -Force
$winCreds = New-Object System.Management.Automation.PSCredential ($nestedWindowsUsername, $secWindowsPassword)

# SQL Server VM definitions
$sqlServers = @(
    @{ Name = "$namingPrefix-SQL01"; Role = "ERP/Finance"; DB = "FinanceERP"; Port = 1433; IP = "10.10.1.101" }
    @{ Name = "$namingPrefix-SQL02"; Role = "CRM"; DB = "ContososCRM"; Port = 1433; IP = "10.10.1.102" }
    @{ Name = "$namingPrefix-SQL03"; Role = "HR/Payroll"; DB = "HRPayroll"; Port = 1433; IP = "10.10.1.103" }
    @{ Name = "$namingPrefix-SQL04"; Role = "Inventory/WMS"; DB = "InventoryWMS"; Port = 1433; IP = "10.10.1.104" }
    @{ Name = "$namingPrefix-SQL05"; Role = "E-Commerce"; DB = "ECommerceStore"; Port = 1433; IP = "10.10.1.105" }
    @{ Name = "$namingPrefix-SQL06"; Role = "Analytics"; DB = "AnalyticsDB"; Port = 1433; IP = "10.10.1.106" }
    @{ Name = "$namingPrefix-SQL07"; Role = "Document Mgmt"; DB = "DocumentMgmt"; Port = 1433; IP = "10.10.1.107" }
    @{ Name = "$namingPrefix-SQL08"; Role = "Legacy LOB"; DB = "LegacyLOB"; Port = 1433; IP = "10.10.1.108" }
    @{ Name = "$namingPrefix-SQL09"; Role = "DevTest"; DB = "AppDev_v2"; Port = 1433; IP = "10.10.1.109" }
    @{ Name = "$namingPrefix-SQL10"; Role = "Compliance"; DB = "ComplianceAudit"; Port = 1433; IP = "10.10.1.110" }
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

# Start logging
$logFilePath = "$Env:ArcBoxLogsDir\ExtendedSQLLab.log"
Start-Transcript -Path $logFilePath -Force -ErrorAction SilentlyContinue

Write-Header "Extended ArcBox SQL Lab Deployment"
Write-Host "Deploying $SqlServerCount SQL Servers and $AppServerCount Application Servers"
Write-Host "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

#region Create Extended Lab Directory
if (-not (Test-Path $ExtendedLabDir)) {
    New-Item -Path $ExtendedLabDir -ItemType Directory -Force | Out-Null
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

# Identify parent SQL VHD
$parentSqlVhd = Get-ChildItem "$Env:ArcBoxVMDir" -Filter "*SQL*.vhdx" | Where-Object { $_.Name -match "$namingPrefix-SQL\.vhdx" } | Select-Object -First 1

if (-not $parentSqlVhd) {
    Write-Error "Parent SQL VHD not found. Ensure the base ArcBox deployment has completed."
    Stop-Transcript
    exit 1
}

Write-Host "Parent SQL VHD: $($parentSqlVhd.FullName)"

foreach ($sql in $sqlServers | Select-Object -First $SqlServerCount) {
    $diffDiskPath = "$Env:ArcBoxVMDir\$($sql.Name).vhdx"
    if (-not (Test-Path $diffDiskPath)) {
        Write-Host "Creating differencing disk for $($sql.Name)..."
        New-VHD -Path $diffDiskPath -ParentPath $parentSqlVhd.FullName -Differencing | Out-Null
        Write-Host "  Created: $diffDiskPath"
    } else {
        Write-Host "  Disk already exists: $diffDiskPath"
    }
}
#endregion

#region Create Differencing Disks for App Servers
Write-Header "Creating Differencing Disks for Application Server VMs"

$parentWinVhd = Get-ChildItem "$Env:ArcBoxVMDir" -Filter "*Win2K22*.vhdx" | Select-Object -First 1

if (-not $parentWinVhd) {
    # Fall back to using SQL VHD as parent (Windows Server with IIS can be added)
    Write-Warning "Win2K22 parent VHD not found. Using SQL VHD as parent for app servers."
    $parentWinVhd = $parentSqlVhd
}

Write-Host "Parent App Server VHD: $($parentWinVhd.FullName)"

foreach ($app in $appServers | Select-Object -First $AppServerCount) {
    $diffDiskPath = "$Env:ArcBoxVMDir\$($app.Name).vhdx"
    if (-not (Test-Path $diffDiskPath)) {
        Write-Host "Creating differencing disk for $($app.Name)..."
        New-VHD -Path $diffDiskPath -ParentPath $parentWinVhd.FullName -Differencing | Out-Null
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
                -Path "$Env:ArcBoxVMDir"

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
                -Path "$Env:ArcBoxVMDir"

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

# With 15 VMs starting simultaneously, we need to wait for each VM to be ready
# for PowerShell Direct (integration services + OS fully booted)
function Wait-ForVMReady {
    param (
        [string]$VMName,
        [PSCredential]$Credential,
        [int]$TimeoutSeconds = 600
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $result = Invoke-Command -VMName $VMName -ScriptBlock { hostname } -Credential $Credential -ErrorAction Stop
            if ($result) {
                return $true
            }
        } catch {
            # "The credential is invalid" is misleading - it often means the VM isn't ready yet
        }
        Start-Sleep -Seconds 10
    }
    return $false
}

Write-Host "Waiting for VMs to become responsive (this may take 3-5 minutes with 15 VMs)..."
Write-Host "Note: 'The credential is invalid' during boot is normal - it means the VM isn't ready for PowerShell Direct yet."
Write-Host ""

$readyCount = 0
$allVMNames = ($sqlServers | Select-Object -First $SqlServerCount | ForEach-Object { $_.Name }) + ($appServers | Select-Object -First $AppServerCount | ForEach-Object { $_.Name })

foreach ($vmName in $allVMNames) {
    Write-Host "  Waiting for $vmName..." -NoNewline
    $ready = Wait-ForVMReady -VMName $vmName -Credential $winCreds -TimeoutSeconds 600
    if ($ready) {
        $readyCount++
        Write-Host " READY" -ForegroundColor Green
    } else {
        Write-Host " TIMEOUT (will retry later)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "VMs ready: $readyCount / $($allVMNames.Count)"

if ($readyCount -eq 0) {
    Write-Error @"
No VMs became responsive. Possible causes:
1. The differencing disks may have a different Administrator password than expected.
   Expected: Administrator / JS123!!
   Verify by opening Hyper-V Manager and trying to connect to a VM console.
2. VMs may have failed to boot. Check Hyper-V Manager for VM states.
3. Integration Services may not be enabled. Check VM settings.
"@
    Stop-Transcript
    exit 1
}

# Restart network adapters on all ready VMs
Write-Host "Restarting network adapters..."
foreach ($vmName in $allVMNames) {
    try {
        Invoke-Command -VMName $vmName -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $winCreds -ErrorAction SilentlyContinue
    } catch { }
}

Start-Sleep -Seconds 30
#endregion

#region Rename SQL Server VMs
Write-Header "Configuring SQL Server VM Hostnames"

foreach ($sql in $sqlServers | Select-Object -First $SqlServerCount) {
    $vmName = $sql.Name
    try {
        $hostname = Invoke-Command -VMName $vmName -ScriptBlock { hostname } -Credential $winCreds -ErrorAction Stop
        if ($hostname -ne $vmName) {
            Write-Host "Renaming $hostname to $vmName..."
            Invoke-Command -VMName $vmName -ScriptBlock { Rename-Computer -NewName $using:vmName -Restart } -Credential $winCreds
        } else {
            Write-Host "  $vmName already has correct hostname."
        }
    } catch {
        Write-Warning "Could not rename $vmName : $_"
    }
}

# Wait for reboots to complete
Write-Host "Waiting for reboots (90 seconds)..."
Start-Sleep -Seconds 90

# Re-verify VMs are back after rename reboot
foreach ($sql in $sqlServers | Select-Object -First $SqlServerCount) {
    Wait-ForVMReady -VMName $sql.Name -Credential $winCreds -TimeoutSeconds 120 | Out-Null
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

        # Create data directory
        Invoke-Command -VMName $vmName -ScriptBlock {
            if (-not (Test-Path 'C:\SQLData')) { New-Item -Path 'C:\SQLData' -ItemType Directory -Force | Out-Null }
        } -Credential $winCreds -ErrorAction Stop

        # Enable TCP/IP and open firewall
        Invoke-Command -VMName $vmName -ScriptBlock {
            # Open SQL port
            New-NetFirewallRule -DisplayName 'Allow SQL Server TCP 1433' -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow -ErrorAction SilentlyContinue

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
        } -Credential $winCreds -ErrorAction Stop

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
            } -Credential $winCreds -ErrorAction Stop
        }

        Write-Host "  $vmName configured successfully."
    } catch {
        Write-Warning "Error configuring ${vmName}: $_"
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

            # Rename if needed
            $hostname = Invoke-Command -VMName $vmName -ScriptBlock { hostname } -Credential $winCreds -ErrorAction Stop
            if ($hostname -ne $vmName) {
                Invoke-Command -VMName $vmName -ScriptBlock { Rename-Computer -NewName $using:vmName -Restart } -Credential $winCreds
                Start-Sleep -Seconds 45
            }

            # Install IIS and .NET
            Invoke-Command -VMName $vmName -ScriptBlock {
                Install-WindowsFeature -Name Web-Server, Web-Asp-Net45, Web-Net-Ext45, NET-Framework-45-Features -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null
                Write-Host "IIS and .NET installed on $env:COMPUTERNAME"
            } -Credential $winCreds -ErrorAction Stop

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

            Copy-VMFile $vmName -SourcePath $appConfigPath -DestinationPath "C:\inetpub\wwwroot\web.config" -CreateFullPath -FileSource Host -Force

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

            Write-Host "  $vmName app deployment complete."
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
            Copy-VMFile $vmName -SourcePath "$Env:ArcBoxDir\agentScript\installArcAgent.ps1" -DestinationPath "C:\ArcBox\installArcAgent.ps1" -CreateFullPath -FileSource Host -Force

            # Use the same comma-separated parameter pattern as the base ArcBox script
            Invoke-Command -VMName $vmName -ScriptBlock { powershell -File C:\ArcBox\installArcAgent.ps1 -accessToken $using:accessToken, -tenantId $using:tenantId, -subscriptionId $using:subscriptionId, -resourceGroup $using:resourceGroup, -azureLocation $using:azureLocation } -Credential $winCreds -ErrorAction Stop

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
            Copy-VMFile $vmName -SourcePath "$Env:ArcBoxDir\agentScript\installArcAgent.ps1" -DestinationPath "C:\ArcBox\installArcAgent.ps1" -CreateFullPath -FileSource Host -Force

            Invoke-Command -VMName $vmName -ScriptBlock { powershell -File C:\ArcBox\installArcAgent.ps1 -accessToken $using:accessToken, -tenantId $using:tenantId, -subscriptionId $using:subscriptionId, -resourceGroup $using:resourceGroup, -azureLocation $using:azureLocation } -Credential $winCreds -ErrorAction Stop

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

Stop-Transcript
