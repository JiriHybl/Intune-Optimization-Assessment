<#
.SYNOPSIS
    Prepares read-only access for an Intune Optimization Assessment.

.DESCRIPTION
    Prompts for the assessment account and assigns:
      - Microsoft Entra Global Reader
      - Microsoft Entra Security Reader
      - Azure Log Analytics Reader on one or more selected workspaces
      - Administrator consent request for the standardized delegated Microsoft Graph Intune reporting scopes

    The script DOES NOT configure diagnostic settings, retention,
    Tenant Governance application permissions, or Intune policies.

.NOTES
    Run using an account authorized to assign the required Microsoft Entra
    directory roles and Azure RBAC roles at the selected workspace scopes.
#>

$ErrorActionPreference = 'Stop'

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
}

function Ensure-Module {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Host "Installing module: $Name" -ForegroundColor Yellow
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber
    }

    Import-Module $Name -ErrorAction Stop
}

Write-Section 'Intune Optimization Assessment - Access Preparation'

$AssessmentUPN = Read-Host 'Enter the UPN of the account that will run the assessment'
if ([string]::IsNullOrWhiteSpace($AssessmentUPN)) {
    throw 'Assessment account UPN cannot be empty.'
}

Write-Section 'Load required PowerShell modules'

@(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Identity.Governance',
    'Az.Accounts',
    'Az.Resources',
    'Az.OperationalInsights'
) | ForEach-Object { Ensure-Module -Name $_ }

Write-Section 'Microsoft Entra role assignments'

$RequiredGraphScopes = @(
    'User.Read.All',
    'RoleManagement.ReadWrite.Directory',
    'DeviceManagementConfiguration.ReadWrite.All',
    'DeviceManagementApps.ReadWrite.All',
    'DeviceManagementManagedDevices.ReadWrite.All'
)

Write-Host 'The Microsoft Graph sign-in will request the following Intune reporting scopes:' -ForegroundColor Yellow
Write-Host '  DeviceManagementConfiguration.ReadWrite.All'
Write-Host '  DeviceManagementApps.ReadWrite.All'
Write-Host '  DeviceManagementManagedDevices.ReadWrite.All'
Write-Host ''
Write-Host 'Review the consent prompt and grant administrator consent for the organization.' -ForegroundColor Yellow

Connect-MgGraph -Scopes $RequiredGraphScopes -NoWelcome

$GraphContext = Get-MgContext
$MissingGraphScopes = @(
    'DeviceManagementConfiguration.ReadWrite.All',
    'DeviceManagementApps.ReadWrite.All',
    'DeviceManagementManagedDevices.ReadWrite.All'
) | Where-Object { $_ -notin $GraphContext.Scopes }

if ($MissingGraphScopes.Count -gt 0) {
    Write-Warning ('The current Graph session is missing required Intune reporting scopes: ' + ($MissingGraphScopes -join ', '))
}
else {
    Write-Host '[OK] Current Graph session includes all standardized Intune reporting scopes.' -ForegroundColor Green
}

$User = Get-MgUser -UserId $AssessmentUPN
if (-not $User) {
    throw "User '$AssessmentUPN' was not found."
}

Write-Host "Assessment account: $($User.DisplayName) <$($User.UserPrincipalName)>" -ForegroundColor Green
Write-Host "Object ID: $($User.Id)"

$RolesToAssign = @('Global Reader', 'Security Reader')
$RoleDefinitions = Get-MgRoleManagementDirectoryRoleDefinition -All

foreach ($RoleName in $RolesToAssign) {
    $Role = $RoleDefinitions | Where-Object DisplayName -eq $RoleName | Select-Object -First 1

    if (-not $Role) {
        Write-Warning "Microsoft Entra role '$RoleName' was not found."
        continue
    }

    $Existing = Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$($User.Id)' and roleDefinitionId eq '$($Role.Id)'"

    if ($Existing) {
        Write-Host "[OK] $RoleName is already assigned." -ForegroundColor Green
        continue
    }

    $Body = @{
        '@odata.type'    = '#microsoft.graph.unifiedRoleAssignment'
        RoleDefinitionId = $Role.Id
        PrincipalId      = $User.Id
        DirectoryScopeId = '/'
    }

    New-MgRoleManagementDirectoryRoleAssignment -BodyParameter $Body | Out-Null
    Write-Host "[ADDED] $RoleName" -ForegroundColor Green
}

Write-Section 'Azure and Log Analytics workspace access'

Connect-AzAccount | Out-Null

$Subscriptions = @(Get-AzSubscription | Sort-Object Name)
if ($Subscriptions.Count -eq 0) {
    throw 'No accessible Azure subscriptions were found.'
}

Write-Host 'Accessible subscriptions:'
for ($i = 0; $i -lt $Subscriptions.Count; $i++) {
    Write-Host "[$($i + 1)] $($Subscriptions[$i].Name)  ($($Subscriptions[$i].Id))"
}

$SubscriptionInput = Read-Host 'Enter subscription numbers to inspect, separated by commas (for example: 1,2)'
$SubscriptionIndexes = $SubscriptionInput -split ',' | ForEach-Object {
    $Value = $_.Trim()
    if ($Value -notmatch '^\d+$') { throw "Invalid subscription selection '$Value'." }
    [int]$Value - 1
} | Select-Object -Unique

$WorkspaceInventory = @()

foreach ($Index in $SubscriptionIndexes) {
    if ($Index -lt 0 -or $Index -ge $Subscriptions.Count) {
        throw "Subscription selection '$($Index + 1)' is out of range."
    }

    $Subscription = $Subscriptions[$Index]
    Set-AzContext -SubscriptionId $Subscription.Id | Out-Null

    $Workspaces = @(Get-AzOperationalInsightsWorkspace | Sort-Object ResourceGroupName, Name)

    foreach ($Workspace in $Workspaces) {
        $WorkspaceInventory += [pscustomobject]@{
            SubscriptionName = $Subscription.Name
            SubscriptionId   = $Subscription.Id
            ResourceGroup    = $Workspace.ResourceGroupName
            WorkspaceName    = $Workspace.Name
            Location         = $Workspace.Location
            ResourceId       = $Workspace.ResourceId
        }
    }
}

if ($WorkspaceInventory.Count -eq 0) {
    Write-Warning 'No Log Analytics workspaces were visible in the selected subscriptions.'
}
else {
    Write-Host ''
    Write-Host 'Available Log Analytics workspaces:' -ForegroundColor Cyan

    for ($i = 0; $i -lt $WorkspaceInventory.Count; $i++) {
        $W = $WorkspaceInventory[$i]
        Write-Host "[$($i + 1)] $($W.WorkspaceName)"
        Write-Host "    Subscription:   $($W.SubscriptionName)"
        Write-Host "    Resource Group: $($W.ResourceGroup)"
        Write-Host "    Location:       $($W.Location)"
    }

    Write-Host ''
    Write-Host 'Select every workspace containing telemetry required for the assessment.' -ForegroundColor Yellow
    Write-Host 'Entra and Intune logging may be in different workspaces.' -ForegroundColor Yellow

    $WorkspaceInput = Read-Host 'Enter workspace numbers separated by commas (for example: 1,3)'
    $WorkspaceIndexes = $WorkspaceInput -split ',' | ForEach-Object {
        $Value = $_.Trim()
        if ($Value -notmatch '^\d+$') { throw "Invalid workspace selection '$Value'." }
        [int]$Value - 1
    } | Select-Object -Unique

    foreach ($Index in $WorkspaceIndexes) {
        if ($Index -lt 0 -or $Index -ge $WorkspaceInventory.Count) {
            throw "Workspace selection '$($Index + 1)' is out of range."
        }

        $Workspace = $WorkspaceInventory[$Index]
        Set-AzContext -SubscriptionId $Workspace.SubscriptionId | Out-Null

        $ExistingAssignment = Get-AzRoleAssignment `
            -ObjectId $User.Id `
            -RoleDefinitionName 'Log Analytics Reader' `
            -Scope $Workspace.ResourceId `
            -ErrorAction SilentlyContinue

        if ($ExistingAssignment) {
            Write-Host "[OK] Log Analytics Reader: $($Workspace.WorkspaceName)" -ForegroundColor Green
        }
        else {
            New-AzRoleAssignment `
                -ObjectId $User.Id `
                -RoleDefinitionName 'Log Analytics Reader' `
                -Scope $Workspace.ResourceId | Out-Null

            Write-Host "[ADDED] Log Analytics Reader: $($Workspace.WorkspaceName)" -ForegroundColor Green
        }
    }
}

Write-Section 'Configuration completed - manual readiness checks remain'

Write-Host 'Assessment identity:'
Write-Host '  [CHECK] Global Reader'
Write-Host '  [CHECK] Security Reader'
Write-Host '  [CHECK] Log Analytics Reader on all selected workspaces'
Write-Host '  [CHECK] Microsoft Graph delegated consent: DeviceManagementConfiguration.ReadWrite.All'
Write-Host '  [CHECK] Microsoft Graph delegated consent: DeviceManagementApps.ReadWrite.All'
Write-Host '  [CHECK] Microsoft Graph delegated consent: DeviceManagementManagedDevices.ReadWrite.All'
Write-Host ''
Write-Host 'Microsoft Graph Intune reporting:'
Write-Host '  [CHECK] Administrator consent was requested for all three standardized delegated scopes.'
Write-Host '  [MANUAL] Sign in as the assessment account and verify Get-MgContext shows all three scopes.'
Write-Host '  [MANUAL] Run a controlled test Intune report export before the engagement.'
Write-Host ''
Write-Host 'Microsoft Entra telemetry:'
Write-Host '  [MANUAL] Verify Entra diagnostic settings are enabled before the engagement.'
Write-Host '  [MANUAL] Verify SigninLogs are present in the Entra logging workspace.'
Write-Host '  [MANUAL] Verify AuditLogs are present in the Entra logging workspace.'
Write-Host ''
Write-Host 'Microsoft Intune telemetry:'
Write-Host '  [MANUAL] Verify Intune diagnostic logging is enabled before the engagement.'
Write-Host '  [MANUAL] Verify Audit, Operational, Device Compliance, and IntuneDevices data as applicable.'
Write-Host ''
Write-Host 'Tenant Governance:'
Write-Host '  [MANUAL] Verify Tenant Governance licensing/availability.'
Write-Host '  [MANUAL] Open Tenant Governance > Configuration management permissions.'
Write-Host '  [MANUAL] Grant required Tenant Configuration Management application permissions for selected Intune resources.'
Write-Host '  [MANUAL] Create a test snapshot and verify the required resources complete successfully.'
Write-Host ''
Write-Host 'Optional Defender scope:'
Write-Host '  [MANUAL] Verify required Defender read access and device inventory visibility.'
Write-Host ''
Write-Host 'IMPORTANT: Do not wait until the assessment starts to enable missing diagnostic logging.' -ForegroundColor Yellow
Write-Host 'Verify actual data is present in the relevant Log Analytics workspace(s).' -ForegroundColor Yellow
