# Extended ArcBox SQL Lab

An expanded version of the [Azure Arc Jumpstart ArcBox](https://github.com/microsoft/azure_arc/tree/main/azure_jumpstart_arcbox) that deploys **10 SQL Servers** and **5 Application Servers** as Hyper-V nested VMs for demonstrating Azure Arc-enabled SQL Server, Azure Migrate, and hybrid management capabilities at scale.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  ArcBox Client VM (Hyper-V Host - Azure VM)                         │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Internal NAT Switch (10.10.1.0/24)                          │   │
│  │                                                              │   │
│  │  SQL Servers (Differencing Disks from ArcBox-SQL.vhdx)       │   │
│  │  ┌─────────┐┌─────────┐┌─────────┐┌─────────┐┌─────────┐   │   │
│  │  │ SQL01   ││ SQL02   ││ SQL03   ││ SQL04   ││ SQL05   │   │   │
│  │  │Finance  ││CRM      ││HR/Pay   ││Inventory││E-Comm   │   │   │
│  │  │ERP      ││         ││roll     ││WMS      ││Store    │   │   │
│  │  └─────────┘└─────────┘└─────────┘└─────────┘└─────────┘   │   │
│  │  ┌─────────┐┌─────────┐┌─────────┐┌─────────┐┌─────────┐   │   │
│  │  │ SQL06   ││ SQL07   ││ SQL08   ││ SQL09   ││ SQL10   │   │   │
│  │  │Analytics││Doc Mgmt ││Legacy   ││DevTest  ││Compli-  │   │   │
│  │  │/BI      ││         ││LOB      ││Staging  ││ance     │   │   │
│  │  └─────────┘└─────────┘└─────────┘└─────────┘└─────────┘   │   │
│  │                                                              │   │
│  │  App Servers (Differencing Disks from ArcBox-Win2K22.vhdx)   │   │
│  │  ┌─────────┐┌─────────┐┌─────────┐┌─────────┐┌─────────┐   │   │
│  │  │ APP01   ││ APP02   ││ APP03   ││ APP04   ││ APP05   │   │   │
│  │  │ERP Web  ││CRM      ││HR       ││E-Comm   ││BI       │   │   │
│  │  │→SQL01   ││Portal   ││Portal   ││Web      ││Reports  │   │   │
│  │  │         ││→SQL02   ││→SQL03   ││→SQL05   ││→SQL06   │   │   │
│  │  └─────────┘└─────────┘└─────────┘└─────────┘└─────────┘   │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  All VMs → Azure Arc → SQL Server Extension → Azure Migrate        │
└─────────────────────────────────────────────────────────────────────┘
```

## SQL Server Inventory

| VM | Role | Database | Key Features Demonstrated |
|---|---|---|---|
| SQL01 | ERP/Finance | FinanceERP | Stored procedures, complex schemas, financial reporting |
| SQL02 | CRM | ContososCRM | Change tracking, large contact/opportunity datasets |
| SQL03 | HR/Payroll | HRPayroll | Dynamic data masking, row-level security patterns |
| SQL04 | Inventory/WMS | InventoryWMS | Temporal tables, spatial data (GEOGRAPHY), XML columns |
| SQL05 | E-Commerce | ECommerceStore | JSON support, computed columns, indexed views |
| SQL06 | Analytics/BI | AnalyticsDB | Columnstore indexes, large fact tables (150K+ rows) |
| SQL07 | Document Mgmt | DocumentMgmt | FILESTREAM, versioning, audit trails |
| SQL08 | Legacy LOB | LegacyLOB | **Migration blockers**: deprecated syntax, MONEY types, dynamic SQL injection, Agent Jobs |
| SQL09 | DevTest/Staging | AppDev_v1, v2, StagingDB, IntegrationTestDB | Multiple databases, schema drift between versions |
| SQL10 | Compliance/Audit | ComplianceAudit | Temporal tables, risk register, 50K+ audit events |

## Application Servers

| VM | Application | Connects To | Technology |
|---|---|---|---|
| APP01 | ERP Web Frontend | SQL01 (FinanceERP) | IIS + ASP.NET |
| APP02 | CRM Portal | SQL02 (ContososCRM) | IIS + ASP.NET |
| APP03 | HR Self-Service Portal | SQL03 (HRPayroll) | IIS + ASP.NET |
| APP04 | E-Commerce Storefront | SQL05 (ECommerceStore) | IIS + ASP.NET |
| APP05 | BI/Reporting Dashboard | SQL06 (AnalyticsDB) | IIS + ASP.NET |

## Prerequisites

1. **Deploy the base ArcBox ITPro** following the [official guide](https://azurearcjumpstart.com/azure_jumpstart_arcbox/ITPro)
2. Wait for the base deployment to complete (ArcServersLogonScript finishes)
3. RDP into the ArcBox Client VM

## Deployment

### Step 1: Copy files to the Client VM

Copy the `extended-lab` folder to `C:\ArcBox\ExtendedLab\` on the Client VM.

### Step 2: Copy SQL setup scripts

```powershell
Copy-Item -Path "C:\ArcBox\ExtendedLab\sql-setup\*" -Destination "C:\ArcBox\ExtendedLab\" -Force
```

### Step 3: Copy DSC configurations

```powershell
Copy-Item -Path "C:\ArcBox\ExtendedLab\dsc\*" -Destination "C:\ArcBox\DSC\" -Force
```

### Step 4: Run the deployment

```powershell
# Full deployment (SQL VMs + App Servers + Arc onboarding)
.\scripts\Deploy-ExtendedSQLLab.ps1

# Deploy without Arc onboarding (faster, for local testing)
.\scripts\Deploy-ExtendedSQLLab.ps1 -SkipArcOnboarding

# Deploy only SQL servers (no app servers)
.\scripts\Deploy-ExtendedSQLLab.ps1 -SkipAppDeployment
```

### Step 5: Validate

```powershell
.\scripts\Validate-ExtendedSQLLab.ps1 -Detailed
```

### Step 6: Generate workload (optional)

```powershell
# Generate realistic SQL traffic for 30 minutes
.\scripts\Generate-SQLWorkload.ps1 -DurationMinutes 30 -IntervalSeconds 5
```

## Demo Scenarios

### 1. Arc-enabled SQL Server Discovery & Onboarding
- Show 10 SQL Server instances discovered and onboarded through Azure Arc
- Demonstrate SQL Server extension deployment across the estate
- View unified inventory in Azure Portal

### 2. Azure Migrate Assessment
- Run migration assessments across all 10 servers
- SQL08 (Legacy LOB) will surface **migration blockers** (deprecated syntax, MONEY types, SQL Agent jobs)
- Compare migration readiness: Azure SQL DB vs. SQL Managed Instance vs. SQL on Azure VM

### 3. SQL Best Practices Assessment (BPA)
- Run BPA across all servers simultaneously
- Compare findings across different workload types
- Demonstrate remediation at scale

### 4. Microsoft Defender for SQL
- Threat detection across the estate
- SQL08 uses dynamic SQL vulnerable to injection (intentional for demo)
- Vulnerability assessment findings

### 5. Azure Policy & Governance
- Apply SQL-specific Azure Policies across all Arc-enabled SQL servers
- Demonstrate compliance reporting at scale
- License management (Paid/PAYG) across the estate

### 6. Monitoring & Performance
- Use the workload generator to create realistic traffic
- Azure Monitor metrics across all instances
- Log Analytics queries for cross-server analysis

### 7. Automated Backups
- Enable automated backups via Arc on all SQL servers
- Demonstrate policy-driven backup configuration
- Recovery point management

### 8. Least Privilege Access
- Enable and demonstrate least-privilege mode across the estate
- Show security posture improvements

## Resource Requirements

The extended lab requires the ArcBox Client VM to have sufficient resources:

| Resource | Minimum | Recommended |
|---|---|---|
| Client VM Size | Standard_D16s_v5 | Standard_D32s_v5 |
| Data Disk | 256 GB Premium SSD | 512 GB Premium SSD |
| RAM (host) | 64 GB | 128 GB |

**Storage efficiency**: Differencing disks mean each SQL VM only stores its delta from the parent VHD (typically 2-5 GB each vs 30+ GB for full copies).

## File Structure

```
extended-lab/
├── README.md                          # This file
├── dsc/
│   ├── sql_servers.dsc.yml           # DSC config for 10 SQL VMs
│   └── app_servers.dsc.yml           # DSC config for 5 App VMs
├── scripts/
│   ├── Deploy-ExtendedSQLLab.ps1     # Main deployment orchestrator
│   ├── Generate-SQLWorkload.ps1      # Workload simulator
│   └── Validate-ExtendedSQLLab.ps1   # Health check/validation
└── sql-setup/
    ├── 01-FinanceERP.sql             # SQL01 database setup
    ├── 02-CRM.sql                    # SQL02 database setup
    ├── 03-HRPayroll.sql              # SQL03 database setup
    ├── 04-InventoryWMS.sql           # SQL04 database setup
    ├── 05-ECommerce.sql              # SQL05 database setup
    ├── 06-Analytics.sql              # SQL06 database setup
    ├── 07-DocumentMgmt.sql           # SQL07 database setup
    ├── 08-LegacyLOB.sql              # SQL08 database setup (migration blockers)
    ├── 09-DevTest.sql                # SQL09 database setup (multi-DB)
    └── 10-ComplianceAudit.sql        # SQL10 database setup
```

## Troubleshooting

| Issue | Solution |
|---|---|
| VMs fail to start | Check available memory on host. Reduce `StartupMemory` in DSC configs. |
| SQL connectivity fails | Verify firewall rules: `Get-NetFirewallRule -DisplayName "*SQL*"` inside VM |
| Arc onboarding timeout | Re-run onboarding: `.\Deploy-ExtendedSQLLab.ps1 -SkipAppDeployment` |
| Differencing disk errors | Ensure parent VHD is not modified after child disks are created |
| DHCP exhaustion | Verify DHCP scope: `Get-DhcpServerv4Scope` — should end at .250 |

## Cleanup

To remove all extended lab VMs (preserves the base ArcBox deployment):

```powershell
# Stop and remove VMs
1..10 | ForEach-Object { $name = "$env:namingPrefix-SQL$($_.ToString('00'))"; Stop-VM $name -Force -ErrorAction SilentlyContinue; Remove-VM $name -Force -ErrorAction SilentlyContinue }
1..5 | ForEach-Object { $name = "$env:namingPrefix-APP$($_.ToString('00'))"; Stop-VM $name -Force -ErrorAction SilentlyContinue; Remove-VM $name -Force -ErrorAction SilentlyContinue }

# Remove differencing disks
Remove-Item "F:\Virtual Machines\*SQL0*.vhdx" -Force
Remove-Item "F:\Virtual Machines\*APP0*.vhdx" -Force
```
