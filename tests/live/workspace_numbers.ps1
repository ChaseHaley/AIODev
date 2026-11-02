[CmdletBinding()]
param(
    [string] $Name = 'workspace-names',
    [string] $Repository = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string] $DesktopPoint = '-30000,-30000'
)
# Numbering was replaced by phrase naming; keep callers on the current naming journey.
& "$PSScriptRoot/workspace_names.ps1" -Name $Name
