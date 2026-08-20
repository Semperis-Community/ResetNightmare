<#
.SYNOPSIS
Signs and verifies release artifacts for the pipeline-build release workflow using Azure Key Vault.

.DESCRIPTION
Uses azureSignTool to apply Authenticode signatures to PowerShell scripts and module files
and creates detached signatures and plain-text checksum files for archive, NuGet, and Python artifacts.
The private key remains in Azure Key Vault and never leaves the vault.

The behavior is driven by pipeline-config/ref/signing.yaml and can be stage-gated.

.PARAMETER SigningConfigFile
Path to the signing configuration YAML file.
Defaults to pipeline-config/ref/signing.yaml.

.PARAMETER Stage
Release stage key used to evaluate stagePolicy in the signing configuration.
Defaults to production.

.PARAMETER WorkspaceRoot
Repository root path used as the search base for repository and artifact files.
Defaults to the current working directory.

.PARAMETER RepositorySignGlobs
File glob patterns used to find signable repository files.
Defaults to PowerShell script/module patterns (*.ps1, *.psm1, *.psd1).

.PARAMETER ArtifactRoots
Repository-relative directories scanned for release artifacts.
Defaults to release-content and out.

.PARAMETER AzureSignToolVersion
Version of azureSignTool to download and install.
Defaults to v7.0.1.

.EXAMPLE
./.github/internal/scripts/sign-release-artifacts.ps1

Runs signing with default settings using pipeline-config/ref/signing.yaml and the production stage.

.EXAMPLE
./.github/internal/scripts/sign-release-artifacts.ps1 -Stage beta

Runs signing for the beta stage and applies the configured stagePolicy for beta.

.EXAMPLE
./.github/internal/scripts/sign-release-artifacts.ps1 -SigningConfigFile pipeline-config/sample/signing.yaml -WorkspaceRoot .

Runs signing using an alternate signing config and an explicit workspace root.

.NOTES
- Signing must be enabled in the configuration file (enabled: true).
- Requires the following environment variables (from GitHub Actions secrets):
    - CODESIGN_AZURE_KEYVAULT_NAME: Azure Key Vault name
    - CODESIGN_AZURE_KEYVAULT_CERT_NAME: Certificate name in Key Vault
- Requires OIDC authentication to be configured for the GitHub runner.
- Non-PowerShell artifacts are signed with detached .sig files and plain-text checksum
    sidecars (.sha256 or .sha512).
#>

[CmdletBinding()]
param(
    [string]$SigningConfigFile = "pipeline-config/ref/signing.yaml",
    [string]$Stage = "production",
    [string]$WorkspaceRoot = (Get-Location).Path,
    [string[]]$RepositorySignGlobs = @('*.ps1', '*.psm1', '*.psd1'),
    [string[]]$ArtifactRoots = @('release-content', 'out'),
    [string]$AzureSignToolVersion = "v7.0.1"
)

$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
Initializes YAML parsing support for signing config processing.
#>
function Initialize-YamlSupport
{
    if (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)
    {
        return
    }

    if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue))
    {
        Register-PSRepository -Default -ErrorAction Stop
    }

    Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    Import-Module powershell-yaml -ErrorAction Stop
}

<#
.SYNOPSIS
Converts a value to boolean, handling string representations.
#>
function ConvertTo-Bool
{
    param([object]$Value)

    if ($null -eq $Value)
    {
        return $false
    }

    if ($Value -is [bool])
    {
        return [bool]$Value
    }

    return [string]$Value.Trim().ToLowerInvariant() -eq 'true'
}

<#
.SYNOPSIS
Resolves and validates the configured hash algorithm.
#>
function Resolve-HashAlgorithm
{
    param([string]$AlgorithmName)

    $resolved = [string]$AlgorithmName
    if ([string]::IsNullOrWhiteSpace($resolved))
    {
        $resolved = 'SHA256'
    }

    $resolved = $resolved.Trim().ToUpperInvariant()
    if ($resolved -notin @('SHA256', 'SHA512'))
    {
        throw "Unsupported hash algorithm '$resolved'. Use SHA256 or SHA512."
    }

    return $resolved
}

<#
.SYNOPSIS
Downloads and installs azureSignTool if not already present.
#>
function Install-AzureSignTool
{
    param([string]$Version)

    # Check if azureSignTool is in PATH
    $azureSignToolCmd = Get-Command azureSignTool -ErrorAction SilentlyContinue
    if ($null -ne $azureSignToolCmd)
    {
        #Write-Output "azureSignTool is already available at: $($azureSignToolCmd.Source)"
        Write-Information "azureSignTool is already available at: $($azureSignToolCmd.Source)" -InformationAction Continue
        return $azureSignToolCmd.Source
    }

    # Download from official GitHub releases
    $normalizedVersion = if ($Version -match '^v') { $Version } else { "v$Version" }
    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
    $assetName = if ($architecture -eq 'arm64') { 'AzureSignTool-arm64.exe' } else { 'AzureSignTool-x64.exe' }
    $downloadUrl = "https://github.com/vcsjones/AzureSignTool/releases/download/$normalizedVersion/$assetName"
    $installPath = Join-Path -Path $env:TEMP -ChildPath "azureSignTool.exe"
    $maxAttempts = 4
    $baseDelaySeconds = 2

    Write-Output "Downloading azureSignTool $normalizedVersion ($assetName) from: $downloadUrl"
    $downloadSucceeded = $false
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++)
    {
        try
        {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $installPath -ErrorAction Stop
            $downloadSucceeded = $true
            break
        }
        catch
        {
            if ($attempt -eq $maxAttempts)
            {
                throw "Failed to download azureSignTool after $maxAttempts attempts from '$downloadUrl': $($_.Exception.Message)"
            }

            $delaySeconds = $baseDelaySeconds * $attempt
            Write-Warning "Download attempt $attempt of $maxAttempts failed: $($_.Exception.Message). Retrying in $delaySeconds second(s)..."
            Start-Sleep -Seconds $delaySeconds
        }
    }

    if (-not $downloadSucceeded)
    {
        throw "Failed to download azureSignTool after $maxAttempts attempts from '$downloadUrl'."
    }

    # Guard against HTML/error responses being saved as .exe
    if (-not (Test-Path -Path $installPath))
    {
        throw "azureSignTool download did not produce an output file: $installPath"
    }

    $fileLength = (Get-Item -Path $installPath -ErrorAction Stop).Length
    if ($fileLength -lt 4096)
    {
        throw "Downloaded azureSignTool file is unexpectedly small ($fileLength bytes): $downloadUrl"
    }

    $probeLength = [Math]::Min(4096, $fileLength)
    $stream = [System.IO.File]::OpenRead($installPath)
    try
    {
        $probeBytes = New-Object byte[] $probeLength
        [void]$stream.Read($probeBytes, 0, $probeLength)
    }
    finally
    {
        $stream.Dispose()
    }

    $probeText = [System.Text.Encoding]::UTF8.GetString($probeBytes)
    if ($probeText -match '<!DOCTYPE html|<html|:root\s*\{|"featureFlags"')
    {
        throw "Downloaded content is not an executable (received HTML/error payload) from: $downloadUrl"
    }

    #Write-Output "azureSignTool installed at: $installPath"
    Write-Information "azureSignTool installed at: $installPath" -InformationAction Continue
    return $installPath
}

<#
.SYNOPSIS
Obtains an Azure Key Vault access token from the authenticated Azure CLI context.
#>
function Get-AzureKeyVaultAccessToken
{
    if (-not [string]::IsNullOrWhiteSpace($script:AzureKeyVaultAccessToken))
    {
        return $script:AzureKeyVaultAccessToken
    }

    $azCommand = Get-Command az -ErrorAction SilentlyContinue
    if ($null -eq $azCommand)
    {
        throw "Azure CLI (az) is required to obtain an access token for azureSignTool authentication."
    }

    $token = (& $azCommand.Source account get-access-token --resource https://vault.azure.net --query accessToken --output tsv).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token))
    {
        throw "Failed to acquire Azure Key Vault access token from Azure CLI for azureSignTool authentication."
    }

    $script:AzureKeyVaultAccessToken = $token
    return $script:AzureKeyVaultAccessToken
}

<#
.SYNOPSIS
Invokes azureSignTool to sign a file against an Azure Key Vault certificate.
#>
function Invoke-AzureSignTool
{
    param(
        [string]$FilePath,
        [string]$VaultUrl,
        [string]$CertificateName,
        [string]$TimestampServer,
        [string]$AzureSignToolPath
    )

    if (-not (Test-Path -Path $FilePath))
    {
        throw "File to sign not found: $FilePath"
    }

    $accessToken = Get-AzureKeyVaultAccessToken

    Write-Output "Signing '$([System.IO.Path]::GetFileName($FilePath))' with azureSignTool..."

    # Build azureSignTool arguments
    $arguments = @(
        "sign",
        "-kvu", $VaultUrl,
        "-kvc", $CertificateName,
        "--azure-key-vault-accesstoken", $accessToken,
        "-tr", $TimestampServer,
        "-td", "sha256",
        $FilePath
    )

    & $AzureSignToolPath @arguments
    if ($LASTEXITCODE -ne 0)
    {
        throw "azureSignTool signing failed for '$FilePath' with exit code $LASTEXITCODE"
    }

    Write-Output "[+] Signed '$([System.IO.Path]::GetFileName($FilePath))'"
}

<#
.SYNOPSIS
Resolves Azure Key Vault configuration from signing config and environment variables.
#>
function Get-AzureKeyVaultConfig
{
    param([object]$SigningConfig)

    $vaultName = [System.Environment]::GetEnvironmentVariable('CODESIGN_AZURE_KEYVAULT_NAME')
    $certName = [System.Environment]::GetEnvironmentVariable('CODESIGN_AZURE_KEYVAULT_CERT_NAME')

    if ([string]::IsNullOrWhiteSpace($vaultName))
    {
        throw "CODESIGN_AZURE_KEYVAULT_NAME environment variable is not configured."
    }
    if ([string]::IsNullOrWhiteSpace($certName))
    {
        throw "CODESIGN_AZURE_KEYVAULT_CERT_NAME environment variable is not configured."
    }

    $vaultUrl = "https://{0}.vault.azure.net/" -f $vaultName
    $timestampServer = [string]$SigningConfig.timestampServer

    if ([string]::IsNullOrWhiteSpace($timestampServer))
    {
        $timestampServer = "https://timestamp.digicert.com"
    }

    Write-Information "Azure Key Vault Configuration:" -InformationAction Continue
    Write-Information "  Vault URL: $vaultUrl" -InformationAction Continue
    Write-Information "  Certificate: $certName" -InformationAction Continue
    Write-Information "  Timestamp Server: $timestampServer" -InformationAction Continue

    return [pscustomobject]@{
        VaultUrl = $vaultUrl
        CertificateName = $certName
        TimestampServer = $timestampServer
    }
}

<#
.SYNOPSIS
Checks if a file is already signed.
#>
function Test-IsAlreadySigned
{
    param([string]$FilePath)

    $extension = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()

    if ($extension -in @('.ps1', '.psm1', '.psd1'))
    {
        # Check PowerShell Authenticode signature
        $sig = Get-AuthenticodeSignature -FilePath $FilePath -ErrorAction SilentlyContinue
        return $sig.Status -eq 'Valid'
    }
    else
    {
        # Check for detached .sig file
        return Test-Path -Path "$FilePath.sig"
    }
}

<#
.SYNOPSIS
Builds a plain-text checksum line for a file.
#>
function Get-ChecksumLine
{
    param(
        [string]$FilePath,
        [string]$HashAlgorithm
    )

    $resolvedAlgorithm = Resolve-HashAlgorithm -AlgorithmName $HashAlgorithm
    $fileHash = Get-FileHash -Path $FilePath -Algorithm $resolvedAlgorithm -ErrorAction Stop

    return "{0} *{1}" -f $fileHash.Hash.ToUpperInvariant(), [System.IO.Path]::GetFileName($FilePath)
}

<#
.SYNOPSIS
Validates a checksum sidecar file against a target artifact.
#>
function Test-ChecksumFile
{
    param(
        [string]$FilePath,
        [string]$ChecksumPath,
        [string]$ExpectedAlgorithm
    )

    if (-not (Test-Path -Path $ChecksumPath))
    {
        throw "Missing checksum file '$ChecksumPath' for '$FilePath'."
    }

    $expectedResolvedAlgorithm = Resolve-HashAlgorithm -AlgorithmName $ExpectedAlgorithm
    $line = ((Get-Content -Path $ChecksumPath -ErrorAction Stop) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace([string]$line))
    {
        throw "Checksum file '$ChecksumPath' is empty."
    }

    if ([string]$line -notmatch '^(?<hash>[A-Fa-f0-9]+)\s+\*(?<file>.+)$')
    {
        throw "Checksum file '$ChecksumPath' is not in expected plain-text checksum format '<HASH> *<FILE>'."
    }

    $expectedFileName = [System.IO.Path]::GetFileName($FilePath)
    if ([string]$Matches.file -ne $expectedFileName)
    {
        throw "Checksum file '$ChecksumPath' does not reference expected file '$expectedFileName'."
    }

    $actualHash = (Get-FileHash -Path $FilePath -Algorithm $expectedResolvedAlgorithm -ErrorAction Stop).Hash.ToUpperInvariant()
    if ($actualHash -ne ([string]$Matches.hash).ToUpperInvariant())
    {
        throw "Checksum verification failed for '$FilePath'."
    }
}

# Initialize and load config
Initialize-YamlSupport

if (-not (Test-Path -Path $SigningConfigFile))
{
    Write-Output "Signing config '$SigningConfigFile' not found. Skipping artifact signing."
    return
}

$signingConfig = Get-Content -Path $SigningConfigFile -Raw | ConvertFrom-Yaml -ErrorAction Stop
if (-not (ConvertTo-Bool $signingConfig.enabled))
{
    Write-Output "Signing is disabled in '$SigningConfigFile'."
    return
}

$stagePolicy = $signingConfig.stagePolicy.$Stage
if ($null -eq $stagePolicy)
{
    throw "Signing config does not define a stagePolicy entry for '$Stage'."
}

if (-not (ConvertTo-Bool $stagePolicy.sign))
{
    Write-Output "Signing is disabled for stage '$Stage'."
    return
}

if ($null -eq $signingConfig.azureKeyVault)
{
    throw "Signing config '$SigningConfigFile' must define an azureKeyVault section when signing is enabled."
}

# Get Key Vault configuration
$kvConfig = Get-AzureKeyVaultConfig -SigningConfig $signingConfig
$hashAlgorithm = Resolve-HashAlgorithm -AlgorithmName ([string]$signingConfig.hashAlgorithm)

# Install azureSignTool
$azureSignToolPath = Install-AzureSignTool -Version $AzureSignToolVersion

# Collect files for signing and checksums
$repoRoot = (Resolve-Path -Path $WorkspaceRoot).Path
$filesToSign = New-Object System.Collections.Generic.List[string]
$filesToChecksum = New-Object System.Collections.Generic.List[string]

foreach ($glob in $RepositorySignGlobs)
{
    $files = Get-ChildItem -Path $repoRoot -Recurse -File -Include $glob -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](out|\.git)[\\/]' }
    foreach ($file in $files)
    {
        [void]$filesToSign.Add($file.FullName)
        [void]$filesToChecksum.Add($file.FullName)
    }
}

foreach ($artifactRoot in $ArtifactRoots)
{
    $artifactRootPath = Join-Path -Path $repoRoot -ChildPath $artifactRoot
    if (-not (Test-Path -Path $artifactRootPath))
    {
        continue
    }

    $artifacts = Get-ChildItem -Path $artifactRootPath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -notin @('.sig', '.sha256', '.sha512') }
    foreach ($artifact in $artifacts)
    {
        [void]$filesToChecksum.Add($artifact.FullName)

        # zip archives are checksum-only artifacts and should not be Authenticode-signed
        if ($artifact.Extension.ToLowerInvariant() -eq '.zip')
        {
            continue
        }

        [void]$filesToSign.Add($artifact.FullName)
    }
}

$filesToSign = @($filesToSign | Sort-Object -Unique)
$filesToChecksum = @($filesToChecksum | Sort-Object -Unique)

if ($filesToChecksum.Count -eq 0)
{
    Write-Output 'No artifacts matched the signing/checksum scope.'
    return
}

Write-Output "Signing $($filesToSign.Count) file(s) and generating checksums for $($filesToChecksum.Count) file(s) for stage '$Stage'..."
# Sign supported files
foreach ($filePath in $filesToSign)
{
    # Skip files that are already signed
    if (Test-IsAlreadySigned -FilePath $filePath)
    {
        Write-Output "Skipping already-signed: '$([System.IO.Path]::GetFileName($filePath))'"
        continue
    }

    Invoke-AzureSignTool -FilePath $filePath `
        -VaultUrl $kvConfig.VaultUrl `
        -CertificateName $kvConfig.CertificateName `
        -TimestampServer $kvConfig.TimestampServer `
        -AzureSignToolPath $azureSignToolPath
}

# Create checksum files for all included artifacts (including checksum-only archives)
foreach ($filePath in $filesToChecksum)
{
    $checksumExtension = $hashAlgorithm.ToLowerInvariant()
    $checksumPath = "$filePath.$($checksumExtension)"
    $checksumLine = Get-ChecksumLine -FilePath $filePath -HashAlgorithm $hashAlgorithm
    $checksumLine | Out-File -FilePath $checksumPath -Encoding ascii -Force
    Write-Output "  [+] Checksum: $([System.IO.Path]::GetFileName($checksumPath))"
}

# Verify signatures
Write-Output "`nVerifying signatures for stage '$Stage'..."
foreach ($filePath in $filesToSign)
{
    $extension = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()

    if ($extension -in @('.ps1', '.psm1', '.psd1'))
    {
        # Verify Authenticode signature for PowerShell files
        $signature = Get-AuthenticodeSignature -FilePath $filePath
        if ($signature.Status -ne 'Valid')
        {
            throw "Authenticode verification failed for '$filePath' with status '$($signature.Status)'."
        }
        Write-Output "  [+] $([System.IO.Path]::GetFileName($filePath)) (Authenticode)"
    }
    else
    {
        # Verify file exists (azureSignTool creates .sig file)
        $sigPath = "$filePath.sig"
        if (-not (Test-Path -Path $sigPath))
        {
            throw "Missing detached signature file '$sigPath' for '$filePath'."
        }
        Write-Output "  [+] $([System.IO.Path]::GetFileName($filePath)) (Detached signature)"
    }
}

foreach ($filePath in $filesToChecksum)
{
    # Verify checksum file
    $checksumExtension = $hashAlgorithm.ToLowerInvariant()
    Test-ChecksumFile -FilePath $filePath -ChecksumPath "$filePath.$($checksumExtension)" -ExpectedAlgorithm $hashAlgorithm
    Write-Output "  [+] Checksum verified"
}

Write-Output "`n[OK] Signing and verification complete for stage '$Stage'."