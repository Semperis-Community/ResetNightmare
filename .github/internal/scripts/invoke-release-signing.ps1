#!/usr/bin/env pwsh
<#
.SYNOPSIS
Wrapper script to invoke release artifact signing with proper environment handling.

.DESCRIPTION
This script invokes the main signing script (sign-release-artifacts.ps1)
with environment variables passed from the GitHub Actions workflow.

The purpose of this wrapper is to prevent GitHub Actions' temporary script generation
from corrupting complex PowerShell commands with inline parameter expressions and arrays.

By moving the invocation into a dedicated script file, we ensure:
- Proper encoding handling without mojibake corruption
- Clear separation of concerns (workflow orchestration vs. signing logic)
- Better error messages and stack traces

.NOTES
This script is invoked by the GitHub Actions release workflow at:
.github/workflows/release.yaml (Sign release inputs with azureSignTool step)

Environment variables (passed from workflow):
- SIGNING_CONFIG_FILE: Path to signing configuration YAML file
- RELEASE_STAGE: Release stage (alpha, beta, rc, production)
#>

$ErrorActionPreference = 'Stop'

# Invoke the main signing script with environment variables and literal parameters
& ./.github/internal/scripts/sign-release-artifacts.ps1 `
    -SigningConfigFile $env:SIGNING_CONFIG_FILE `
    -Stage $env:RELEASE_STAGE `
    -WorkspaceRoot (Get-Location).Path `
    -ArtifactRoots @('release-content')
