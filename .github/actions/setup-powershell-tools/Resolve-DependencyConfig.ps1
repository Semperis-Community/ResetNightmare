<#
.SYNOPSIS
Parses setup-powershell-tools dependency configuration.

.DESCRIPTION
Provides a reusable parser for dependency YAML used by the setup-powershell-tools action.
The parser normalizes repository definitions and resolves the PowerShell module install list.

.NOTES
Used by CI/release workflow setup to keep parsing behavior testable via Pester fixtures.
#>

<#
.SYNOPSIS
Resolves repository and module install configuration from a dependency YAML file.

.DESCRIPTION
Reads the dependency file when present, validates repository entries, skips placeholder hosts,
and builds a normalized list of modules to install. If the dependency file is missing or does
not define powershellModules, the function falls back to the module list passed by the action.

.PARAMETER DependencyFile
Optional path to the dependency YAML file.

.PARAMETER ModuleList
Fallback module names used when powershellModules is not defined in the dependency file.

.OUTPUTS
PSCustomObject with DependencyFileFound, Repositories, and ModulesToInstall properties.
#>
function Resolve-SetupPowerShellToolsDependencyConfig
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$DependencyFile,

        [Parameter(Mandatory = $true)]
        [string[]]$ModuleList
    )

    $dependencyConfig = $null
    $repositories = @()

    <#
    .SYNOPSIS
    Normalizes a scalar YAML token for fallback parsing.

    .DESCRIPTION
    Trims whitespace, strips trailing inline comments, and removes surrounding
    single/double quotes when present.
    #>
    function Normalize-SetupPowerShellToolsYamlScalar
    {
        param(
            [AllowNull()]
            [string]$Value
        )

        if ($null -eq $Value)
        {
            return $null
        }

        $trimmed = $Value.Trim()
        $trimmed = $trimmed -replace '\s+#.*$', ''

        if (($trimmed.StartsWith("'") -and $trimmed.EndsWith("'")) -or ($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')))
        {
            return $trimmed.Substring(1, $trimmed.Length - 2)
        }

        return $trimmed
    }

    <#
    .SYNOPSIS
    Parses dependency YAML when ConvertFrom-Yaml is unavailable.

    .DESCRIPTION
    Uses a minimal line-oriented parser to extract powershellRepositories,
    repositories, and powershellModules entries needed by this action.
    #>
    function Parse-SetupPowerShellToolsDependencyConfigFallback
    {
        param(
            [string]$RawYaml
        )

        $parsed = [PSCustomObject]@{
            powershellRepositories = @()
            repositories = @()
            powershellModules = @()
        }

        $targetSections = @('powershellRepositories', 'repositories', 'powershellModules')
        $currentSection = ''
        $currentEntry = $null

        <#
        .SYNOPSIS
        Appends the current parsed entry to the target section.

        .DESCRIPTION
        Adds a hashtable entry as a PSCustomObject to the resolved section list
        when both section name and entry content are present.
        #>
        function Add-CurrentEntry
        {
            param(
                [PSCustomObject]$Target,
                [string]$SectionName,
                [hashtable]$Entry
            )

            if ([string]::IsNullOrWhiteSpace($SectionName) -or $null -eq $Entry)
            {
                return
            }

            $entryObject = [PSCustomObject]$Entry
            switch ($SectionName)
            {
                'powershellRepositories' { $Target.powershellRepositories += $entryObject }
                'repositories' { $Target.repositories += $entryObject }
                'powershellModules' { $Target.powershellModules += $entryObject }
            }
        }

        foreach ($rawLine in ($RawYaml -split "`r?`n"))
        {
            if ($rawLine -match '^\s*#')
            {
                continue
            }

            if ($rawLine -match '^([A-Za-z0-9_]+)\s*:\s*$')
            {
                Add-CurrentEntry -Target $parsed -SectionName $currentSection -Entry $currentEntry
                $currentEntry = $null

                $candidateSection = [string]$matches[1]
                if ($targetSections -contains $candidateSection)
                {
                    $currentSection = $candidateSection
                }
                else
                {
                    $currentSection = ''
                }

                continue
            }

            if ([string]::IsNullOrWhiteSpace($currentSection))
            {
                continue
            }

            if ($rawLine -match '^\s*-\s*(.*)$')
            {
                Add-CurrentEntry -Target $parsed -SectionName $currentSection -Entry $currentEntry
                $currentEntry = @{}

                $inlineContent = [string]$matches[1]
                if ($inlineContent -match '^([A-Za-z0-9_\-]+)\s*:\s*(.*)$')
                {
                    $inlineKey = [string]$matches[1]
                    $inlineValue = Normalize-SetupPowerShellToolsYamlScalar -Value ([string]$matches[2])
                    $currentEntry[$inlineKey] = $inlineValue
                }

                continue
            }

            if ($null -eq $currentEntry)
            {
                continue
            }

            if ($rawLine -match '^\s+([A-Za-z0-9_\-]+)\s*:\s*(.*)$')
            {
                $entryKey = [string]$matches[1]
                $entryValue = Normalize-SetupPowerShellToolsYamlScalar -Value ([string]$matches[2])
                $currentEntry[$entryKey] = $entryValue
            }
        }

        Add-CurrentEntry -Target $parsed -SectionName $currentSection -Entry $currentEntry
        return $parsed
    }

    if ([string]::IsNullOrWhiteSpace($DependencyFile) -eq $false -and (Test-Path $DependencyFile))
    {
        $dependencyRawContent = Get-Content -Path $DependencyFile -Raw
        $canUseYamlCmdlet = $true

        if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue))
        {
            try
            {
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
                Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                Import-Module powershell-yaml -ErrorAction Stop
            }
            catch
            {
                $canUseYamlCmdlet = $false
                Write-Warning "Unable to install powershell-yaml from PSGallery. Falling back to limited parser for '$DependencyFile'. Error: $($_.Exception.Message)"
            }
        }

        if ($canUseYamlCmdlet)
        {
            try
            {
                $dependencyConfig = $dependencyRawContent | ConvertFrom-Yaml -ErrorAction Stop
            }
            catch
            {
                throw "Dependency file '$DependencyFile' is invalid YAML. $($_.Exception.Message)"
            }
        }
        else
        {
            $dependencyConfig = Parse-SetupPowerShellToolsDependencyConfigFallback -RawYaml $dependencyRawContent
        }

        $repoList = @()
        if ($null -ne $dependencyConfig.powershellRepositories)
        {
            $repoList = @($dependencyConfig.powershellRepositories)
        }
        elseif ($null -ne $dependencyConfig.repositories)
        {
            $repoList = @($dependencyConfig.repositories)
        }

        foreach ($repo in $repoList)
        {
            $repoName = $repo.name
            $repoUrl = $repo.sourceLocation
            if ([string]::IsNullOrWhiteSpace($repoUrl) -and [string]::IsNullOrWhiteSpace($repo.url) -eq $false)
            {
                $repoUrl = $repo.url
            }

            if ([string]::IsNullOrWhiteSpace($repoName) -or [string]::IsNullOrWhiteSpace($repoUrl))
            {
                throw "Each repository entry in '$DependencyFile' must include 'name' and 'sourceLocation' (or 'url')."
            }

            $parsedRepoUri = $null
            if (-not [System.Uri]::TryCreate($repoUrl, [System.UriKind]::Absolute, [ref]$parsedRepoUri))
            {
                throw "Repository '$repoName' has an invalid URL '$repoUrl'."
            }

            if ($parsedRepoUri.Host -match '(^|\.)example\.org$|(^|\.)example\.com$|(^|\.)example\.net$|\.example$')
            {
                Write-Warning "Skipping placeholder repository '$repoName' ($repoUrl). Replace with a real feed URL in '$DependencyFile'."
                continue
            }

            $installationPolicy = if ([string]::IsNullOrWhiteSpace($repo.installationPolicy))
            {
                "Trusted"
            }
            else
            {
                $repo.installationPolicy
            }
            $repositories += [PSCustomObject]@{
                Name = $repoName
                SourceLocation = $repoUrl
                InstallationPolicy = $installationPolicy
            }
        }
    }

    $modulesToInstall = @()
    if ($null -ne $dependencyConfig -and $null -ne $dependencyConfig.powershellModules)
    {
        foreach ($mod in @($dependencyConfig.powershellModules))
        {
            if ([string]::IsNullOrWhiteSpace($mod.name))
            {
                throw "Each powershellModules entry in '$DependencyFile' must include 'name'."
            }

            $pinned = if ([string]::IsNullOrWhiteSpace($mod.version) -or $mod.version -eq 'latest')
            {
                $null
            }
            else
            {
                $mod.version
            }
            $modulesToInstall += [PSCustomObject]@{
                Name = $mod.name
                Version = $pinned
            }
        }
    }
    else
    {
        foreach ($name in $ModuleList)
        {
            $modulesToInstall += [PSCustomObject]@{
                Name = $name
                Version = $null
            }
        }
    }

    [PSCustomObject]@{
        DependencyFileFound = ([string]::IsNullOrWhiteSpace($DependencyFile) -eq $false -and (Test-Path $DependencyFile))
        Repositories = $repositories
        ModulesToInstall = $modulesToInstall
    }
}
