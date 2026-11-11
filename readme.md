Change the variables in the powershell, and run it.

- $workspaceId = 'f05ea07b-6c22-48cb-9fa0-e4e73cb78b7d'
- $notebookId = '4a743494-5a9a-4e75-b705-7ed0a5db2fca'

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