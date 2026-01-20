# Azure DevOps to GitHub Pipeline Rewiring Tool

A PowerShell tool for migrating Azure DevOps pipelines to use GitHub repositories.

Provides a workaround for: [Issue: Pipeline rewiring not working for githubenterprise](https://github.com/github/gh-gei/issues/1496)

## Features

- **Test Mode**: Temporarily rewire a pipeline to GitHub, run a build, and automatically restore the original configuration
- **Migrate Mode**: Permanently rewire pipelines to GitHub with dry-run support
- Supports both GitHub.com and GitHub Enterprise
- Filter pipelines by ID or wildcard name patterns

## Prerequisites

- PowerShell 5.1 or later
- Azure DevOps Personal Access Token with pipeline read/write permissions
- Azure DevOps service connection to GitHub configured in your project

## Configuration

Set the following environment variables or pass them as parameters:

| Variable | Description |
|----------|-------------|
| `ADO_ORG` | Azure DevOps organization name |
| `ADO_PAT` | Azure DevOps Personal Access Token |
| `ADO_TEAM_PROJECT` | Azure DevOps Team Project name |
| `ADO_SVC_CON_ID` | Service connection ID for GitHub |
| `GH_ORG` | GitHub organization name |
| `GH_PAT` | GitHub Personal Access Token (optional) |
| `TARGET_API_URL` | GitHub API URL (for GitHub Enterprise; omit for github.com) |

## Usage

### Test Mode

Rewires the pipeline to GitHub, queues a build, waits for completion, then restores the original configuration:

```powershell
# Filter by pipeline name
.\Rewire-AdoPipelines.ps1 -Mode Test -PipelineFilter "*Validate*" -GhRepo "MyRepo"

# Specify pipeline IDs
.\Rewire-AdoPipelines.ps1 -Mode Test -PipelineIds @(123, 456) -GhRepo "MyRepo"

# With verbose output
.\Rewire-AdoPipelines.ps1 -Mode Test -PipelineIds @(789) -GhRepo "MyRepo" -Verbose
```

### Migrate Mode

Permanently updates pipelines to use GitHub:

```powershell
# Dry run - preview changes without applying
.\Rewire-AdoPipelines.ps1 -Mode Migrate -PipelineIds @(123) -GhRepo "MyRepo" -DryRun

# Actual migration
.\Rewire-AdoPipelines.ps1 -Mode Migrate -PipelineFilter "*Build*" -GhRepo "MyRepo"
```

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Mode` | Yes | `Test` or `Migrate` |
| `-GhRepo` | Yes | Target GitHub repository name |
| `-PipelineIds` | No* | Array of pipeline IDs to process |
| `-PipelineFilter` | No* | Wildcard filter for pipeline names |
| `-DryRun` | No | Preview changes without applying (Migrate mode only) |
| `-MaxConcurrentTests` | No | Max concurrent tests (default: 1) |
| `-WaitTimeoutMinutes` | No | Build timeout in minutes (default: 30) |

*Either `-PipelineIds` or `-PipelineFilter` must be specified.

## License

MIT