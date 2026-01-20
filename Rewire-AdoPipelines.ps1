<#
.SYNOPSIS
    Azure DevOps to GitHub Pipeline Rewiring Tool

.DESCRIPTION
    This script provides functionality to test and migrate Azure DevOps pipelines 
    to use GitHub repositories instead of Azure DevOps repositories.
    
    Modes:
    - Test: Rewire pipeline to GitHub, run a build, then restore original configuration
    - Migrate: Permanently rewire pipeline to GitHub (with dry-run capability)

.PARAMETER Mode
    The operation mode: 'Test' or 'Migrate'

.PARAMETER AdoOrg
    Azure DevOps organization name

.PARAMETER AdoPat
    Azure DevOps Personal Access Token

.PARAMETER AdoTeamProject
    Azure DevOps Team Project name

.PARAMETER GhOrg
    GitHub organization name

.PARAMETER GhPat
    GitHub Personal Access Token

.PARAMETER TargetApiUrl
    GitHub API URL (for GitHub Enterprise)

.PARAMETER ServiceConnectionId
    Azure DevOps service connection ID for GitHub

.PARAMETER GhRepo
    Target GitHub repository name

.PARAMETER PipelineIds
    Array of specific pipeline IDs to process

.PARAMETER PipelineFilter
    Wildcard filter for pipeline names (e.g., "*Validate*")

.PARAMETER DryRun
    When specified with Migrate mode, shows what would be changed without making changes

.PARAMETER MaxConcurrentTests
    Maximum number of concurrent pipeline tests (default: 1)

.PARAMETER WaitTimeoutMinutes
    Maximum time to wait for a build to complete in minutes (default: 30)

.PARAMETER Verbose
    Enable verbose output

.EXAMPLE
    .\rewire-pipelines.ps1 -Mode Test -PipelineFilter "*Validate JSON*" -GhRepo "ServerManagedCare"

.EXAMPLE
    .\rewire-pipelines.ps1 -Mode Migrate -PipelineIds @(123, 456) -GhRepo "MyRepo" -DryRun

.EXAMPLE
    .\rewire-pipelines.ps1 -Mode Test -PipelineIds @(789) -GhRepo "ServerManagedCare" -Verbose
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Test', 'Migrate')]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [string]$AdoOrg = $env:ADO_ORG,

    [Parameter(Mandatory = $false)]
    [string]$AdoPat = $env:ADO_PAT,

    [Parameter(Mandatory = $false)]
    [string]$AdoTeamProject = $env:ADO_TEAM_PROJECT,

    [Parameter(Mandatory = $false)]
    [string]$GhOrg = $env:GH_ORG,

    [Parameter(Mandatory = $false)]
    [string]$GhPat = $env:GH_PAT,

    [Parameter(Mandatory = $false)]
    [string]$TargetApiUrl = $env:TARGET_API_URL,

    [Parameter(Mandatory = $false)]
    [string]$ServiceConnectionId = $env:ADO_SVC_CON_ID,

    [Parameter(Mandatory = $true)]
    [string]$GhRepo,

    [Parameter(Mandatory = $false)]
    [int[]]$PipelineIds,

    [Parameter(Mandatory = $false)]
    [string]$PipelineFilter,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [int]$MaxConcurrentTests = 1,

    [Parameter(Mandatory = $false)]
    [int]$WaitTimeoutMinutes = 30
)

#region Validation
if (-not $PipelineIds -and -not $PipelineFilter) {
    throw "You must specify either -PipelineIds or -PipelineFilter"
}

if (-not $AdoOrg) { throw "AdoOrg is required. Set via parameter or `$env:ADO_ORG" }
if (-not $AdoPat) { throw "AdoPat is required. Set via parameter or `$env:ADO_PAT" }
if (-not $AdoTeamProject) { throw "AdoTeamProject is required. Set via parameter or `$env:ADO_TEAM_PROJECT" }
if (-not $GhOrg) { throw "GhOrg is required. Set via parameter or `$env:GH_ORG" }
if (-not $ServiceConnectionId) { throw "ServiceConnectionId is required. Set via parameter or `$env:ADO_SVC_CON_ID" }
#endregion

#region Helper Functions

function Get-AdoAuthHeader {
    param([string]$Pat)
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
    return @{ Authorization = "Basic $base64Auth" }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Verbose')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info' { 'White' }
        'Warning' { 'Yellow' }
        'Error' { 'Red' }
        'Success' { 'Green' }
        'Verbose' { 'Cyan' }
    }
    
    if ($Level -eq 'Verbose' -and -not $VerbosePreference) {
        return
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Get-AdoApiUrl {
    param([string]$Endpoint)
    return "https://dev.azure.com/$AdoOrg/$([uri]::EscapeDataString($AdoTeamProject))/_apis/$Endpoint"
}

function Invoke-AdoApi {
    param(
        [string]$Endpoint,
        [string]$Method = 'GET',
        [object]$Body,
        [string]$ApiVersion = '7.1'
    )
    
    $url = Get-AdoApiUrl -Endpoint $Endpoint
    if ($url -notmatch '\?') {
        $url += "?api-version=$ApiVersion"
    } else {
        $url += "&api-version=$ApiVersion"
    }
    
    $headers = Get-AdoAuthHeader -Pat $AdoPat
    $headers['Content-Type'] = 'application/json'
    
    $params = @{
        Uri = $url
        Method = $Method
        Headers = $headers
    }
    
    if ($Body) {
        $params['Body'] = ($Body | ConvertTo-Json -Depth 20)
    }
    
    Write-Log "API Call: $Method $url" -Level Verbose
    
    try {
        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        Write-Log "API Error: $($_.Exception.Message)" -Level Error
        Write-Log "Response: $($_.ErrorDetails.Message)" -Level Error
        throw
    }
}

function Get-AllPipelines {
    Write-Log "Fetching all pipelines from $AdoTeamProject..." -Level Info
    
    $pipelines = @()
    $continuationToken = $null
    
    do {
        $endpoint = "pipelines"
        if ($continuationToken) {
            $endpoint += "?continuationToken=$continuationToken"
        }
        
        $response = Invoke-AdoApi -Endpoint $endpoint
        $pipelines += $response.value
        $continuationToken = $response.continuationToken
    } while ($continuationToken)
    
    Write-Log "Found $($pipelines.Count) pipelines" -Level Info
    return $pipelines
}

function Get-PipelineDetails {
    param([int]$PipelineId)
    
    Write-Log "Fetching details for pipeline $PipelineId..." -Level Verbose
    return Invoke-AdoApi -Endpoint "pipelines/$PipelineId"
}

function Get-BuildDefinition {
    param([int]$DefinitionId)
    
    Write-Log "Fetching build definition $DefinitionId..." -Level Verbose
    return Invoke-AdoApi -Endpoint "build/definitions/$DefinitionId"
}

function Update-BuildDefinition {
    param(
        [int]$DefinitionId,
        [object]$Definition
    )
    
    Write-Log "Updating build definition $DefinitionId..." -Level Verbose
    Write-Log "Definition Body: $(($Definition | ConvertTo-Json -Depth 5))" -Level Verbose
    return Invoke-AdoApi -Endpoint "build/definitions/$DefinitionId" -Method 'PUT' -Body $Definition
}

function Get-ServiceEndpoint {
    param([string]$EndpointId)
    
    Write-Log "Fetching service endpoint $EndpointId..." -Level Verbose
    $url = "https://dev.azure.com/$AdoOrg/$([uri]::EscapeDataString($AdoTeamProject))/_apis/serviceendpoint/endpoints/$EndpointId"
    $url += "?api-version=7.1"
    
    $headers = Get-AdoAuthHeader -Pat $AdoPat
    return Invoke-RestMethod -Uri $url -Headers $headers -Method GET
}

function Start-PipelineBuild {
    param([int]$PipelineId)
    
    Write-Log "Starting build for pipeline $PipelineId..." -Level Info
    
    $body = @{
        definition = @{ id = $PipelineId }
    }
    
    return Invoke-AdoApi -Endpoint "build/builds" -Method 'POST' -Body $body
}

function Get-BuildStatus {
    param([int]$BuildId)
    
    return Invoke-AdoApi -Endpoint "build/builds/$BuildId"
}

function Wait-ForBuild {
    param(
        [int]$BuildId,
        [int]$TimeoutMinutes = 30
    )
    
    $startTime = Get-Date
    $timeout = New-TimeSpan -Minutes $TimeoutMinutes
    
    Write-Log "Waiting for build $BuildId to complete (timeout: $TimeoutMinutes minutes)..." -Level Info
    
    while ((Get-Date) - $startTime -lt $timeout) {
        $build = Get-BuildStatus -BuildId $BuildId
        
        Write-Log "Build $BuildId status: $($build.status) - Result: $($build.result)" -Level Verbose
        
        if ($build.status -eq 'completed') {
            return $build
        }
        
        Start-Sleep -Seconds 10
    }
    
    throw "Build $BuildId timed out after $TimeoutMinutes minutes"
}

function Get-GitHubRepoUrl {
    param([string]$RepoName)
    
    # Extract the base URL from the API URL
    if ($TargetApiUrl -match 'api\.(.+)') {
        $baseUrl = "https://$($Matches[1])"
    } else {
        $baseUrl = "https://github.com"
    }
    
    return "$baseUrl/$GhOrg/$RepoName.git"
}

function ConvertTo-Hashtable {
    param(
        [Parameter(ValueFromPipeline)]
        [object]$InputObject
    )
    
    if ($null -eq $InputObject) { return $null }
    
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $collection = @(
            foreach ($object in $InputObject) {
                ConvertTo-Hashtable -InputObject $object
            }
        )
        return $collection
    }
    elseif ($InputObject -is [PSCustomObject]) {
        $hash = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $hash[$property.Name] = ConvertTo-Hashtable -InputObject $property.Value
        }
        return $hash
    }
    else {
        return $InputObject
    }
}

function Convert-DefinitionToGitHub {
    param(
        [object]$Definition,
        [string]$RepoName,
        [string]$ServiceConnectionId
    )
    
    # Get service endpoint details
    $endpoint = Get-ServiceEndpoint -EndpointId $ServiceConnectionId
    
    # Store original repository configuration as a deep copy converted to hashtables
    # This ensures proper serialization when restoring
    $originalRepoJson = $Definition.repository | ConvertTo-Json -Depth 20
    $originalRepo = ConvertTo-Hashtable -InputObject ($originalRepoJson | ConvertFrom-Json)
    
    Write-Log "Stored original repository config: $originalRepoJson" -Level Verbose
    
    # Calculate GitHub repo URL
    $ghRepoUrl = Get-GitHubRepoUrl -RepoName $RepoName
    
    # Determine if this is GitHub Enterprise based on TargetApiUrl
    $isGitHubEnterprise = $false
    $apiUrl = "https://api.github.com"
    
    if ($TargetApiUrl) {
        # If TargetApiUrl is provided and not the standard GitHub API, it's GitHub Enterprise
        if ($TargetApiUrl -ne "https://api.github.com") {
            $isGitHubEnterprise = $true
            $apiUrl = $TargetApiUrl
        }
    }
    
    $repoType = if ($isGitHubEnterprise) { "GitHubEnterprise" } else { "GitHub" }
    
    Write-Log "Rewiring to $repoType repo: $ghRepoUrl" -Level Verbose
    Write-Log "API URL: $apiUrl" -Level Verbose
    
    # Build properties based on repository type
    $repoProperties = @{
        connectedServiceId = $ServiceConnectionId
        apiUrl = $apiUrl
        branchesUrl = "$apiUrl/repos/$GhOrg/$RepoName/branches"
        cloneUrl = $ghRepoUrl
        fullName = "$GhOrg/$RepoName"
        refsUrl = "$apiUrl/repos/$GhOrg/$RepoName/git/refs"
    }
    
    # Add GitHub Enterprise specific properties
    if ($isGitHubEnterprise) {
        $repoProperties['isEnterpriseServer'] = "true"
    }
    
    # Update repository configuration
    $Definition.repository = @{
        type = $repoType
        name = "$GhOrg/$RepoName"
        url = $ghRepoUrl
        defaultBranch = $Definition.repository.defaultBranch ?? "refs/heads/main"
        clean = $Definition.repository.clean ?? "true"
        checkoutSubmodules = $Definition.repository.checkoutSubmodules ?? $false
        properties = $repoProperties
    }
    
    return @{
        UpdatedDefinition = $Definition
        OriginalRepository = $originalRepo
    }
}

function Restore-DefinitionRepository {
    param(
        [object]$Definition,
        [object]$OriginalRepository
    )
    
    Write-Log "Restoring repository to type: $($OriginalRepository.type), name: $($OriginalRepository.name)" -Level Verbose
    Write-Log "Original repository config: $($OriginalRepository | ConvertTo-Json -Depth 10)" -Level Verbose
    
    $Definition.repository = $OriginalRepository
    return $Definition
}

function Get-FilteredPipelines {
    param(
        [array]$AllPipelines,
        [int[]]$PipelineIds,
        [string]$PipelineFilter
    )
    
    $filtered = @()
    
    if ($PipelineIds) {
        $filtered = $AllPipelines | Where-Object { $_.id -in $PipelineIds }
        Write-Log "Filtered to $($filtered.Count) pipelines by ID" -Level Info
    }
    elseif ($PipelineFilter) {
        $filtered = $AllPipelines | Where-Object { $_.name -like $PipelineFilter }
        Write-Log "Filtered to $($filtered.Count) pipelines matching '$PipelineFilter'" -Level Info
    }
    
    return $filtered
}

#endregion

#region Main Logic

function Test-Pipeline {
    param(
        [object]$Pipeline,
        [string]$RepoName
    )
    
    $pipelineId = $Pipeline.id
    $pipelineName = $Pipeline.name
    
    Write-Log "========================================" -Level Info
    Write-Log "Testing Pipeline: $pipelineName (ID: $pipelineId)" -Level Info
    Write-Log "========================================" -Level Info
    
    try {
        # Step 1: Get current build definition
        Write-Log "Step 1: Fetching current build definition..." -Level Info
        $definition = Get-BuildDefinition -DefinitionId $pipelineId
        $originalRevision = $definition.revision
        
        Write-Log "Current repository type: $($definition.repository.type)" -Level Verbose
        Write-Log "Current repository name: $($definition.repository.name)" -Level Verbose
        
        # Step 2: Convert to GitHub
        Write-Log "Step 2: Rewiring pipeline to GitHub..." -Level Info
        $conversionResult = Convert-DefinitionToGitHub -Definition $definition -RepoName $RepoName -ServiceConnectionId $ServiceConnectionId
        $updatedDefinition = $conversionResult.UpdatedDefinition
        $originalRepository = $conversionResult.OriginalRepository
        
        # Step 3: Update the definition
        Write-Log "Step 3: Applying GitHub configuration..." -Level Info
        $savedDefinition = Update-BuildDefinition -DefinitionId $pipelineId -Definition $updatedDefinition
        Write-Log "Pipeline updated to revision $($savedDefinition.revision)" -Level Success
        
        # Step 4: Queue a build
        Write-Log "Step 4: Queuing test build..." -Level Info
        $build = Start-PipelineBuild -PipelineId $pipelineId
        $buildId = $build.id
        Write-Log "Build queued: ID $buildId" -Level Success
        Write-Log "Build URL: $($build._links.web.href)" -Level Info
        
        # Step 5: Wait for build completion
        Write-Log "Step 5: Waiting for build to complete..." -Level Info
        $completedBuild = Wait-ForBuild -BuildId $buildId -TimeoutMinutes $WaitTimeoutMinutes
        
        $buildResult = $completedBuild.result
        Write-Log "Build completed with result: $buildResult" -Level $(if ($buildResult -eq 'succeeded') { 'Success' } else { 'Warning' })
        
        # Step 6: Restore original configuration
        Write-Log "Step 6: Restoring original repository configuration..." -Level Info
        Write-Log "Original repository type to restore: $($originalRepository.type)" -Level Verbose
        $currentDefinition = Get-BuildDefinition -DefinitionId $pipelineId
        Write-Log "Current definition revision before restore: $($currentDefinition.revision)" -Level Verbose
        $restoredDefinition = Restore-DefinitionRepository -Definition $currentDefinition -OriginalRepository $originalRepository
        
        try {
            $finalDefinition = Update-BuildDefinition -DefinitionId $pipelineId -Definition $restoredDefinition
            Write-Log "Original configuration restored (revision $($finalDefinition.revision))" -Level Success
            
            # Verify restoration
            $verifyDefinition = Get-BuildDefinition -DefinitionId $pipelineId
            if ($verifyDefinition.repository.type -eq $originalRepository.type) {
                Write-Log "Verification: Repository type is now '$($verifyDefinition.repository.type)'" -Level Success
            } else {
                Write-Log "Verification FAILED: Repository type is '$($verifyDefinition.repository.type)' but expected '$($originalRepository.type)'" -Level Error
            }
        }
        catch {
            Write-Log "Failed to restore during Step 6: $($_.Exception.Message)" -Level Error
            Write-Log "Error details: $($_.ErrorDetails.Message)" -Level Error
            throw
        }
        
        return @{
            PipelineId = $pipelineId
            PipelineName = $pipelineName
            BuildId = $buildId
            BuildResult = $buildResult
            Success = $true
            Error = $null
        }
    }
    catch {
        Write-Log "Error testing pipeline $pipelineName : $($_.Exception.Message)" -Level Error
        
        # Attempt to restore original configuration
        try {
            Write-Log "Attempting to restore original configuration after error..." -Level Warning
            $currentDefinition = Get-BuildDefinition -DefinitionId $pipelineId
            if ($originalRepository) {
                $restoredDefinition = Restore-DefinitionRepository -Definition $currentDefinition -OriginalRepository $originalRepository
                Update-BuildDefinition -DefinitionId $pipelineId -Definition $restoredDefinition | Out-Null
                Write-Log "Original configuration restored after error" -Level Success
            }
        }
        catch {
            Write-Log "Failed to restore original configuration: $($_.Exception.Message)" -Level Error
        }
        
        return @{
            PipelineId = $pipelineId
            PipelineName = $pipelineName
            BuildId = $null
            BuildResult = 'error'
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Migrate-Pipeline {
    param(
        [object]$Pipeline,
        [string]$RepoName,
        [switch]$DryRun
    )
    
    $pipelineId = $Pipeline.id
    $pipelineName = $Pipeline.name
    
    Write-Log "========================================" -Level Info
    Write-Log "$(if ($DryRun) { '[DRY RUN] ' })Migrating Pipeline: $pipelineName (ID: $pipelineId)" -Level Info
    Write-Log "========================================" -Level Info
    
    try {
        # Step 1: Get current build definition
        Write-Log "Step 1: Fetching current build definition..." -Level Info
        $definition = Get-BuildDefinition -DefinitionId $pipelineId
        
        Write-Log "Current repository type: $($definition.repository.type)" -Level Info
        Write-Log "Current repository name: $($definition.repository.name)" -Level Info
        
        if ($definition.repository.type -eq 'GitHub') {
            Write-Log "Pipeline is already configured for GitHub - skipping" -Level Warning
            return @{
                PipelineId = $pipelineId
                PipelineName = $pipelineName
                Success = $true
                Skipped = $true
                Message = "Already configured for GitHub"
            }
        }
        
        # Step 2: Convert to GitHub
        Write-Log "Step 2: Preparing GitHub configuration..." -Level Info
        $conversionResult = Convert-DefinitionToGitHub -Definition $definition -RepoName $RepoName -ServiceConnectionId $ServiceConnectionId
        $updatedDefinition = $conversionResult.UpdatedDefinition
        
        Write-Log "Target GitHub repo: $GhOrg/$RepoName" -Level Info
        
        if ($DryRun) {
            Write-Log "[DRY RUN] Would update pipeline to use GitHub repository" -Level Warning
            Write-Log "[DRY RUN] New repository configuration:" -Level Verbose
            Write-Log ($updatedDefinition.repository | ConvertTo-Json -Depth 5) -Level Verbose
            
            return @{
                PipelineId = $pipelineId
                PipelineName = $pipelineName
                Success = $true
                DryRun = $true
                Message = "Would migrate to $GhOrg/$RepoName"
            }
        }
        
        # Step 3: Update the definition (actual migration)
        Write-Log "Step 3: Applying GitHub configuration..." -Level Info
        $savedDefinition = Update-BuildDefinition -DefinitionId $pipelineId -Definition $updatedDefinition
        Write-Log "Pipeline migrated successfully (revision $($savedDefinition.revision))" -Level Success
        
        return @{
            PipelineId = $pipelineId
            PipelineName = $pipelineName
            Success = $true
            DryRun = $false
            Message = "Migrated to $GhOrg/$RepoName"
        }
    }
    catch {
        Write-Log "Error migrating pipeline $pipelineName : $($_.Exception.Message)" -Level Error
        
        return @{
            PipelineId = $pipelineId
            PipelineName = $pipelineName
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

#endregion

#region Main Execution

Write-Log "============================================" -Level Info
Write-Log "Azure DevOps to GitHub Pipeline Rewiring Tool" -Level Info
Write-Log "============================================" -Level Info
Write-Log "Mode: $Mode $(if ($DryRun) { '(Dry Run)' })" -Level Info
Write-Log "ADO Organization: $AdoOrg" -Level Info
Write-Log "ADO Team Project: $AdoTeamProject" -Level Info
Write-Log "GitHub Organization: $GhOrg" -Level Info
Write-Log "Target GitHub Repo: $GhRepo" -Level Info
Write-Log "Service Connection: $ServiceConnectionId" -Level Info
Write-Log "============================================" -Level Info

# Get all pipelines
$allPipelines = Get-AllPipelines

# Filter pipelines based on parameters
$targetPipelines = Get-FilteredPipelines -AllPipelines $allPipelines -PipelineIds $PipelineIds -PipelineFilter $PipelineFilter

if ($targetPipelines.Count -eq 0) {
    Write-Log "No pipelines found matching the specified criteria" -Level Warning
    exit 0
}

Write-Log "Target pipelines:" -Level Info
foreach ($p in $targetPipelines) {
    Write-Log "  - $($p.name) (ID: $($p.id))" -Level Info
}

# Process pipelines
$results = @()

foreach ($pipeline in $targetPipelines) {
    if ($Mode -eq 'Test') {
        $result = Test-Pipeline -Pipeline $pipeline -RepoName $GhRepo
    }
    else {
        $result = Migrate-Pipeline -Pipeline $pipeline -RepoName $GhRepo -DryRun:$DryRun
    }
    
    $results += $result
}

# Summary
Write-Log "" -Level Info
Write-Log "============================================" -Level Info
Write-Log "SUMMARY" -Level Info
Write-Log "============================================" -Level Info

$successful = ($results | Where-Object { $_.Success }).Count
$failed = ($results | Where-Object { -not $_.Success }).Count

Write-Log "Total Pipelines Processed: $($results.Count)" -Level Info
Write-Log "Successful: $successful" -Level Success
Write-Log "Failed: $failed" -Level $(if ($failed -gt 0) { 'Error' } else { 'Info' })

if ($Mode -eq 'Test') {
    Write-Log "" -Level Info
    Write-Log "Build Results:" -Level Info
    foreach ($r in $results) {
        $status = if ($r.Success) { "✓" } else { "✗" }
        $buildInfo = if ($r.BuildId) { "Build #$($r.BuildId): $($r.BuildResult)" } else { "No build" }
        Write-Log "  $status $($r.PipelineName): $buildInfo" -Level $(if ($r.Success) { 'Success' } else { 'Error' })
    }
}
else {
    Write-Log "" -Level Info
    Write-Log "Migration Results:" -Level Info
    foreach ($r in $results) {
        $status = if ($r.Success) { "✓" } else { "✗" }
        $message = if ($r.Message) { $r.Message } else { $r.Error }
        Write-Log "  $status $($r.PipelineName): $message" -Level $(if ($r.Success) { 'Success' } else { 'Error' })
    }
}

# Return results for programmatic use
$results

#endregion
