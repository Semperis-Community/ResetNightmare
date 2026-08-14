@{
    # Enforce formatting-oriented rules used by CI PowerShell style checks.
    Rules = @{
        PSUseConsistentIndentation = @{
            Enable = $true
            Kind = 'space'
            IndentationSize = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }

        PSPlaceOpenBrace = @{
            Enable = $true
            OnSameLine = $false
            NewLineAfter = $true
            IgnoreOneLineBlock = $true
        }

        PSPlaceCloseBrace = @{
            Enable = $true
            NewLineAfter = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore = $false
        }

        PSUseConsistentWhitespace = @{
            Enable = $true
        }

        PSAvoidTrailingWhitespace = @{
            Enable = $true
        }

        PSAlignAssignmentStatement = @{
            Enable = $false
        }
    }
}
