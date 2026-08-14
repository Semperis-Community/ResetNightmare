<#
.SYNOPSIS
Installs required PowerShell modules for CI and local validation workflows.

.DESCRIPTION
Parses a comma-separated list of module names, trusts PSGallery for the
current session context, and installs each requested module for the current
user scope.

.PARAMETER Modules
Comma-separated module names to install. Empty entries are ignored.

.EXAMPLE
./install.ps1

Installs the default module set: PSScriptAnalyzer and Pester.

.EXAMPLE
./install.ps1 -Modules "PSScriptAnalyzer,Pester,platyPS"

Installs a custom module list.

.NOTES
Used by the setup-powershell-tools action helper script.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Modules = "PSScriptAnalyzer,Pester"
)

$moduleList = $Modules -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }

Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
foreach ($module in $moduleList)
{
    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}
