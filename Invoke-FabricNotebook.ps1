#requires -Version 5.1
<#
.SYNOPSIS
Runs Notebook_1 using the current Azure CLI login and waits for completion.
.EXAMPLE
.\Invoke-FabricNotebook.ps1
.EXAMPLE
.\Invoke-FabricNotebook.ps1 -Month "2025-02-01" -top_n 20 -Scenario "Jeffrey2"
.NOTES
Requires Azure CLI, an existing az login, and permission to execute the notebook.
In Fabric, use the cell's ... menu > Toggle parameter cell and save the notebook.
The cell must contain uncommented assignments for Month, top_n, and Scenario.
A "# Parameters cell" comment alone does not designate a parameter cell.
Values override defaults only for the job run, not the saved notebook or an
existing interactive session. Queries must reference the parameter variables;
hardcoded SQL literals are not replaced.
Reference: https://learn.microsoft.com/fabric/data-engineering/notebook-public-api
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Month = '2025-01-01',

    [int]$top_n = 10,

    [ValidateNotNullOrEmpty()]
    [string]$Scenario = 'Jeffrey3',

    [ValidateRange(1, 1440)]
    [int]$TimeoutMinutes = 30,

    [ValidateRange(1, 300)]
    [int]$PollIntervalSeconds = 15
)

$ErrorActionPreference = 'Stop'
$workspaceId = 'f05ea07b-6c22-48cb-9fa0-e4e73cb78b7d'
$notebookId = '4a743494-5a9a-4e75-b705-7ed0a5db2fca'
$apiRoot = 'https://api.fabric.microsoft.com'
$itemUrl = "$apiRoot/v1/workspaces/$workspaceId/items/$notebookId"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Install it and run az login before running this script.'
}

function Invoke-FabricRequest {
    param(
        [string]$Uri,
        [string]$Method = 'GET',
        [string]$Body
    )

    # Azure CLI caches and refreshes the token; never persist it in this script.
    $token = & az account get-access-token --resource $apiRoot --query accessToken --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw 'Could not obtain a Fabric access token. Run az login for the tenant containing this workspace.'
    }

    $request = @{
        Uri = $Uri
        Method = $Method
        Headers = @{
            Authorization = "Bearer $token"
            'x-ms-fabric-skill' = 'spark-cli'
        }
        UseBasicParsing = $true
        TimeoutSec = 60
        ErrorAction = 'Stop'
    }
    if ($Method -eq 'POST') {
        $request.ContentType = 'application/json'
        $request.Body = $Body
    }

    Invoke-WebRequest @request
}

$body = @{
    executionData = @{
        parameters = @{
            Month = @{ value = $Month; type = 'string' }
            top_n = @{ value = $top_n; type = 'int' }
            Scenario = @{ value = $Scenario; type = 'string' }
        }
    }
} | ConvertTo-Json -Depth 5

# Submit exactly once: retrying a POST can create duplicate notebook runs.
$response = Invoke-FabricRequest -Uri "$itemUrl/jobs/instances?jobType=RunNotebook" -Method POST -Body $body
$jobUrl = [string]($response.Headers['Location'] | Select-Object -First 1)
if ($response.StatusCode -ne 202 -or [string]::IsNullOrWhiteSpace($jobUrl)) {
    throw "Fabric did not return HTTP 202 and a job Location. Check notebook run history before submitting again."
}

$jobUri = [uri]::new([uri]$apiRoot, $jobUrl)
if ($jobUri.Scheme -ne 'https' -or $jobUri.Host -ne 'api.fabric.microsoft.com') {
    throw "Fabric returned an unexpected job Location; refusing to send credentials to it."
}
$jobId = $jobUri.AbsolutePath.TrimEnd('/').Split('/')[-1]
Write-Host "Submitted notebook job: $jobId"
Write-Host "Status URL: $($jobUri.AbsoluteUri)"

$timer = [System.Diagnostics.Stopwatch]::StartNew()
while ($timer.Elapsed.TotalMinutes -lt $TimeoutMinutes) {
    $statusResponse = Invoke-FabricRequest -Uri $jobUri.AbsoluteUri
    $job = $statusResponse.Content | ConvertFrom-Json
    Write-Host "Notebook status: $($job.status)"

    switch ($job.status) {
        'Completed' { return $job }
        'Failed' {
            throw "Notebook job $jobId failed: $($job.failureReason | ConvertTo-Json -Depth 10 -Compress)"
        }
        'Cancelled' { throw "Notebook job $jobId was cancelled." }
        { $_ -in 'NotStarted', 'InProgress', 'Running', 'Deduped' } { }
        default { throw "Unexpected notebook status '$($job.status)' for job $jobId. Check $jobUri." }
    }

    $remainingSeconds = ($TimeoutMinutes * 60) - $timer.Elapsed.TotalSeconds
    if ($remainingSeconds -gt 0) {
        Start-Sleep -Seconds ([math]::Min($PollIntervalSeconds, $remainingSeconds))
    }
}

throw "Timed out waiting for job $jobId after $TimeoutMinutes minutes. The remote job was not cancelled. Check $jobUri before submitting again."
