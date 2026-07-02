<#
.SYNOPSIS
    Generates simulated SQL workload across all 10 SQL servers.
    Run this from the ArcBox Client VM to create realistic activity
    for Arc monitoring and assessment demos.
#>

param (
    [int]$DurationMinutes = 30,
    [int]$IntervalSeconds = 5
)

$namingPrefix = $env:namingPrefix
if (-not $namingPrefix) { $namingPrefix = 'ArcBox' }

$nestedWindowsUsername = 'Administrator'
$nestedWindowsPassword = 'JS123!!'
$secWindowsPassword = ConvertTo-SecureString $nestedWindowsPassword -AsPlainText -Force
$winCreds = New-Object System.Management.Automation.PSCredential ($nestedWindowsUsername, $secWindowsPassword)

# Workload definitions for each SQL server
$workloads = @(
    @{
        VM = "$namingPrefix-SQL01"
        Queries = @(
            "USE FinanceERP; SELECT TOP 100 * FROM dbo.GeneralLedger ORDER BY NEWID();"
            "USE FinanceERP; EXEC dbo.sp_GetTrialBalance @AsOfDate = '$(Get-Date -Format 'yyyy-MM-dd')';"
            "USE FinanceERP; SELECT ca.AccountType, COUNT(*) cnt, SUM(gl.DebitAmount) TotalDebit FROM dbo.GeneralLedger gl JOIN dbo.ChartOfAccounts ca ON gl.AccountID = ca.AccountID GROUP BY ca.AccountType;"
        )
    }
    @{
        VM = "$namingPrefix-SQL02"
        Queries = @(
            "USE ContososCRM; SELECT TOP 50 c.*, o.OpportunityName, o.Amount FROM dbo.Contacts c JOIN dbo.Opportunities o ON c.ContactID = o.ContactID ORDER BY o.Amount DESC;"
            "USE ContososCRM; SELECT Stage, COUNT(*) as Count, SUM(Amount) as Pipeline FROM dbo.Opportunities GROUP BY Stage;"
            "USE ContososCRM; SELECT TOP 20 * FROM dbo.Contacts WHERE City = 'Seattle' ORDER BY CreatedDate DESC;"
        )
    }
    @{
        VM = "$namingPrefix-SQL03"
        Queries = @(
            "USE HRPayroll; SELECT TOP 50 e.FirstName, e.LastName, e.JobTitle, d.DepartmentName FROM dbo.Employees e JOIN dbo.Departments d ON e.DepartmentID = d.DepartmentID;"
            "USE HRPayroll; SELECT DepartmentID, AVG(Salary) AvgSalary, COUNT(*) EmpCount FROM dbo.Employees GROUP BY DepartmentID;"
            "USE HRPayroll; SELECT TOP 20 * FROM dbo.PayrollRecords ORDER BY ProcessedDate DESC;"
        )
    }
    @{
        VM = "$namingPrefix-SQL04"
        Queries = @(
            "USE InventoryWMS; SELECT p.ProductName, il.QuantityOnHand, w.WarehouseName FROM dbo.InventoryLevels il JOIN dbo.Products p ON il.ProductID = p.ProductID JOIN dbo.Warehouses w ON il.WarehouseID = w.WarehouseID WHERE il.QuantityOnHand < il.ReorderPoint;"
            "USE InventoryWMS; SELECT w.WarehouseName, COUNT(*) Items, SUM(il.QuantityOnHand) TotalStock FROM dbo.InventoryLevels il JOIN dbo.Warehouses w ON il.WarehouseID = w.WarehouseID GROUP BY w.WarehouseName;"
        )
    }
    @{
        VM = "$namingPrefix-SQL05"
        Queries = @(
            "USE ECommerceStore; SELECT TOP 50 o.OrderNumber, c.Email, o.TotalAmount, o.Status FROM dbo.Orders o JOIN dbo.Customers c ON o.CustomerID = c.CustomerID ORDER BY o.OrderDate DESC;"
            "USE ECommerceStore; SELECT Category, COUNT(*) ProductCount, AVG(Price) AvgPrice FROM dbo.Products GROUP BY Category;"
            "USE ECommerceStore; SELECT Status, COUNT(*) OrderCount, SUM(SubTotal) Revenue FROM dbo.Orders GROUP BY Status;"
        )
    }
    @{
        VM = "$namingPrefix-SQL06"
        Queries = @(
            "USE AnalyticsDB; SELECT TOP 100 DateKey, SUM(TotalAmount) DailyRevenue, SUM(Quantity) Units FROM dbo.FactSales GROUP BY DateKey ORDER BY DateKey DESC;"
            "USE AnalyticsDB; SELECT Country, SUM(PageViews) TotalViews, AVG(Duration) AvgDuration FROM dbo.FactWebTraffic GROUP BY Country;"
        )
    }
    @{
        VM = "$namingPrefix-SQL07"
        Queries = @(
            "USE DocumentMgmt; SELECT TOP 50 d.Title, d.FileName, c.CategoryName, u.DisplayName FROM dbo.Documents d JOIN dbo.Categories c ON d.CategoryID = c.CategoryID JOIN dbo.Users u ON d.CreatedByUserID = u.UserID ORDER BY d.CreatedDate DESC;"
            "USE DocumentMgmt; SELECT Action, COUNT(*) ActionCount FROM dbo.AuditLog WHERE Timestamp > DATEADD(DAY, -7, GETDATE()) GROUP BY Action;"
        )
    }
    @{
        VM = "$namingPrefix-SQL08"
        Queries = @(
            "USE LegacyLOB; EXEC dbo.sp_GetCustomerOrders @CustomerID = 1;"
            "USE LegacyLOB; SELECT TOP 100 o.OrderID, c.CompanyName, o.OrderDate, o.Freight FROM dbo.Orders o JOIN dbo.Customers c ON o.CustomerID = c.CustomerID ORDER BY o.OrderDate DESC;"
            "USE LegacyLOB; SELECT ShipCountry, COUNT(*) Orders, SUM(Freight) TotalFreight FROM dbo.Orders GROUP BY ShipCountry ORDER BY Orders DESC;"
        )
    }
    @{
        VM = "$namingPrefix-SQL09"
        Queries = @(
            "USE AppDev_v2; SELECT TOP 50 u.Username, p.Title, p.Status FROM dbo.Users u JOIN dbo.Posts p ON u.UserID = p.AuthorID ORDER BY p.CreatedAt DESC;"
            "USE StagingDB; SELECT SourceSystem, COUNT(*) Total, SUM(CASE WHEN ProcessedFlag = 0 THEN 1 ELSE 0 END) Pending FROM dbo.ETL_SalesStaging GROUP BY SourceSystem;"
            "USE IntegrationTestDB; SELECT TestSuite, Status, COUNT(*) cnt FROM dbo.TestResults GROUP BY TestSuite, Status ORDER BY TestSuite;"
        )
    }
    @{
        VM = "$namingPrefix-SQL10"
        Queries = @(
            "USE ComplianceAudit; SELECT EventType, Severity, COUNT(*) EventCount FROM dbo.AuditEvents WHERE Timestamp > DATEADD(HOUR, -24, GETDATE()) GROUP BY EventType, Severity ORDER BY EventCount DESC;"
            "USE ComplianceAudit; SELECT f.FrameworkName, cc.Status, COUNT(*) ControlCount FROM dbo.ComplianceControls cc JOIN dbo.RegulatoryFrameworks f ON cc.FrameworkID = f.FrameworkID GROUP BY f.FrameworkName, cc.Status;"
            "USE ComplianceAudit; SELECT TOP 10 * FROM dbo.PolicyViolations WHERE Status = 'Open' ORDER BY DetectedDate DESC;"
        )
    }
)

Write-Host "Starting workload generation across $($workloads.Count) SQL servers"
Write-Host "Duration: $DurationMinutes minutes | Interval: $IntervalSeconds seconds"
Write-Host "Press Ctrl+C to stop early."
Write-Host ""

$endTime = (Get-Date).AddMinutes($DurationMinutes)
$iteration = 0

while ((Get-Date) -lt $endTime) {
    $iteration++
    $timestamp = Get-Date -Format 'HH:mm:ss'

    foreach ($workload in $workloads) {
        $query = $workload.Queries | Get-Random

        Start-Job -ScriptBlock {
            param($vmName, $query, $creds)
            try {
                Invoke-Command -VMName $vmName -ScriptBlock {
                    Invoke-Sqlcmd -Query $using:query -TrustServerCertificate -QueryTimeout 30 | Out-Null
                } -Credential $creds -ErrorAction SilentlyContinue
            } catch { }
        } -ArgumentList $workload.VM, $query, $winCreds | Out-Null
    }

    # Clean up completed jobs periodically
    if ($iteration % 10 -eq 0) {
        Get-Job -State Completed | Remove-Job -Force
        $running = (Get-Job -State Running).Count
        Write-Host "[$timestamp] Iteration $iteration | Running jobs: $running"
    }

    Start-Sleep -Seconds $IntervalSeconds
}

# Cleanup
Get-Job | Wait-Job -Timeout 30 | Remove-Job -Force
Write-Host ""
Write-Host "Workload generation complete. Total iterations: $iteration"
