param(
    [Parameter(Mandatory = $false)]
    [string]$Root = "."
)

$ErrorActionPreference = "Stop"

$excludePathPatterns = @(
    "\\.git\\",
    "\\node_modules\\",
    "\\out\\",
    "\\TestResults\\"
)

$files = Get-ChildItem -Path $Root -Recurse -File -Include *.ps1, *.psm1 |
    Where-Object {
        $fullName = $_.FullName
        foreach ($pattern in $excludePathPatterns)
        {
            if ($fullName -match $pattern)
            {
                return $false
            }
        }
        return $true
    }

$missingScriptHelp = New-Object System.Collections.Generic.List[string]
$missingFunctionHelp = New-Object System.Collections.Generic.List[string]

function Test-ContainsSynopsisHelp
{
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text))
    {
        return $false
    }

    return $Text -match '(?is)<#.*?\.SYNOPSIS.*?#>'
}

foreach ($file in $files)
{
    $content = Get-Content -Path $file.FullName -Raw
    $lines = Get-Content -Path $file.FullName

    # Require top-level comment-based help with .SYNOPSIS for script/module files.
    $headLineCount = [Math]::Min(120, $lines.Count)
    $headText = ($lines[0..($headLineCount - 1)] -join "`n")
    if ($headText -notmatch '(?is)<#.*?\.SYNOPSIS.*?#>')
    {
        $missingScriptHelp.Add($file.FullName)
    }

    # Require function/cmdlet comment-based help with .SYNOPSIS either immediately above
    # the declaration or near the start of the function body.
    $functionMatches = [regex]::Matches($content, '(?im)^\s*function\s+([A-Za-z0-9_-]+)\b')
    foreach ($match in $functionMatches)
    {
        $prefix = $content.Substring(0, $match.Index)
        $lineNumber = ([regex]::Matches($prefix, "`n")).Count + 1

        $beforeStartLine = [Math]::Max(1, $lineNumber - 20)
        $beforeEndLine = [Math]::Max(1, $lineNumber - 1)
        $beforeContext = ($lines[($beforeStartLine - 1)..($beforeEndLine - 1)] -join "`n")

        $afterStartLine = [Math]::Min($lines.Count, $lineNumber)
        $afterEndLine = [Math]::Min($lines.Count, $lineNumber + 30)
        $afterContext = ($lines[($afterStartLine - 1)..($afterEndLine - 1)] -join "`n")

        $hasBeforeHelp = Test-ContainsSynopsisHelp -Text $beforeContext
        $hasAfterHelp = Test-ContainsSynopsisHelp -Text $afterContext

        if (-not $hasBeforeHelp -and -not $hasAfterHelp)
        {
            $functionName = $match.Groups[1].Value
            $missingFunctionHelp.Add("$($file.FullName):$lineNumber ($functionName)")
        }
    }
}

if ($missingScriptHelp.Count -gt 0 -or $missingFunctionHelp.Count -gt 0)
{
    Write-Output "PowerShell help validation failed."

    if ($missingScriptHelp.Count -gt 0)
    {
        Write-Output ""
        Write-Output "Scripts/modules missing top-level .SYNOPSIS help:"
        $missingScriptHelp | Sort-Object -Unique | ForEach-Object { Write-Output " - $_" }
    }

    if ($missingFunctionHelp.Count -gt 0)
    {
        Write-Output ""
        Write-Output "Functions/cmdlets missing nearby .SYNOPSIS help:"
        $missingFunctionHelp | Sort-Object -Unique | ForEach-Object { Write-Output " - $_" }
    }

    exit 1
}

Write-Output "PowerShell help validation passed."
