# Local GitHub Actions

This folder is for local reusable actions, such as composite actions.

## Suggested layout

```text
.github/
  actions/
    setup-tools/
      action.yaml
      install.ps1
```

Create one subfolder per local action, and keep related scripts with that action.

## Included starter action

- setup-powershell-tools

### Purpose

Installs PowerShell modules needed by CI tasks.
The repository standard is Pester 5.

### Inputs

- modules: Comma-separated module names. Default is PSScriptAnalyzer,Pester.
- dependency-file: Optional YAML file path that defines external PowerShell repositories. Default is pipeline-config/ref/test-dependencies.yaml.

For deterministic CI behavior, pin Pester to a Pester 5 version in `powershellModules` within `pipeline-config/ref/test-dependencies.yaml`.

### Usage

```yaml
- name: Setup PowerShell tools
  uses: ./.github/actions/setup-powershell-tools
  with:
    modules: PSScriptAnalyzer,Pester
    dependency-file: pipeline-config/ref/test-dependencies.yaml
```

### Dependency file format

```yaml
powershellRepositories:
  - name: ExamplePowerShellRepoA
    sourceLocation: https://packages.example.org/powershell
    installationPolicy: Trusted
  - name: ExamplePowerShellRepoB
    sourceLocation: https://packages.example.net/powershell
    installationPolicy: Trusted

powershellModules:
  - name: ExamplePowerShellRepoA
    version: latest
  - name: ExamplePowerShellRepoB
    version: latest

nugetSources:
  - name: NuGet.org
    url: https://api.nuget.org/v3/index.json

pythonIndexes:
  - name: PyPI
    url: https://pypi.org/simple
```

The sample above is intentionally generic. Replace the placeholder names and URLs with the repositories or feeds your organization actually consumes.

