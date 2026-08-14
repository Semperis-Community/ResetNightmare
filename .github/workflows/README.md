# Local Wrapper Workflows

This folder contains repository-local wrapper workflows for centralized pipeline adoption.

## Purpose

- Keep local trigger definitions and repository policy controls.
- Pass repository-specific config file paths and runtime inputs.
- Call centralized reusable workflows from the organization workflow repository.

## Wrapper to Central Mapping

- ci-core.yaml -> .github/workflows/ci-core-reusable.yaml
- ci-powershell.yaml -> .github/workflows/ci-powershell-reusable.yaml
- ci-dotnet.yaml -> .github/workflows/ci-dotnet-reusable.yaml
- ci-python.yaml -> .github/workflows/ci-python-reusable.yaml
- release.yaml -> .github/workflows/release-reusable.yaml
- changelog.yaml -> .github/workflows/changelog-reusable.yaml
- notify.yaml -> .github/workflows/notify-reusable.yaml
- incident.yaml -> .github/workflows/incident-reusable.yaml

## Consumer Wrapper Pattern

Example call from a local wrapper:

```yaml
jobs:
  ci-core:
    uses: Semperis-Community/.github/.github/workflows/ci-core-reusable.yaml@v1.0.0
    with:
      checkout_ref: ${{ github.sha }}
      pkg_dependency_reference_file: pipeline-config/ref/pkg-dependencies.yaml
      test_dependency_reference_file: pipeline-config/ref/test-dependencies.yaml
      pipeline_config_file: pipeline-config/ref/pipeline.yaml
      publish_targets_file: pipeline-config/ref/publish-targets.yaml
      release_stage_config_file: pipeline-config/ref/release-stages.yaml
      release_package_exclusions_file: pipeline-config/ref/release-package-exclusions.yaml
      notify_config_file: pipeline-config/ref/notify.yaml
      incident_config_file: pipeline-config/ref/incidents.yaml
      workflow_contract_version: 1.0.0
    secrets: inherit
```

## Required Inputs Policy

- Wrapper contracts are strict: required inputs are always passed explicitly.
- No default path fallback is assumed in centralized reusable workflows.
- Wrapper updates are required when centralized contract versions change.

## Expression Context Rule

- For job-level reusable workflow calls (`jobs.<id>.uses`), do not map inputs from `${{ env.* }}` in `with:`.
- In that `with:` context, use literals or allowed contexts: `github`, `inputs`, `vars`, `needs`, `strategy`, `matrix`.

Allowed-context examples:

```yaml
with:
  checkout_ref: ${{ github.sha }}
  ref: ${{ inputs.ref }}
  workflow_contract_version: ${{ vars.WORKFLOW_CONTRACT_VERSION }}
  stage: ${{ needs.detect-stage.outputs.stage }}
  package_name: ${{ matrix.package }}
  os_name: ${{ strategy.job-index }}
```

Good:

```yaml
with:
  pipeline_config_file: pipeline-config/ref/pipeline.yaml
  checkout_ref: ${{ github.sha }}
```

Bad:

```yaml
env:
  PIPELINE_CONFIG_FILE: pipeline-config/ref/pipeline.yaml

with:
  pipeline_config_file: ${{ env.PIPELINE_CONFIG_FILE }}
```

## Compatibility and Pinning

- Keep required check names stable when branch protection depends on them.
- Pin centralized reusable workflow references to immutable SHA or controlled version tag.
- Do not consume moving default branches in production wrappers.
