# SomehowIManage

`manage.ps1` is a local orchestration script for multi-project .NET development. It helps you:

- Start/stop APIs by project, group, or entire stack
- Manage dependency-aware startup order
- Stream logs and inspect service status
- Generate and maintain a stack definition (`manage.yaml`)
- Build local NuGet client packages
- Scaffold new API/client solutions
- Run tests with coverage and summarized output
- Perform common Git operations across related repositories

## Requirements

- PowerShell (Windows PowerShell or PowerShell 7+)
- .NET SDK (`dotnet`) on `PATH`
- A stack file (`manage.yaml` by default) for most commands

Optional:

- `git` for Git commands
- `gh` (GitHub CLI) for `git configure` (auto-installed via `winget` if missing)
- `curl.exe` for `logging stream`

## Basic Usage

```powershell
.\manage.ps1 <command> [target] [options]
```

Examples:

```powershell
.\manage.ps1 generate
.\manage.ps1 list
.\manage.ps1 start all --launch
.\manage.ps1 stop all
.\manage.ps1 logs logging --tail
```

## Stack File

Default stack file path is `manage.yaml` at repo root (override with `STACK_FILE`).

### YAML format (preferred)

```yaml
apis:
  - name: some-api
    path: src/Some.API/Some.API.csproj
    port: 5101
    depends_on: ["other-api"]
    groups: ["core"]
    default_branch: develop

clients:
  - name: some-client
    path: src/Some.Client/Some.Client.csproj
    default_branch: develop
```

### Legacy pipe format (still supported)

```text
name|path|port|depends_on|groups|default_branch
```

## Commands

### Service orchestration

- `start [all|group|project] [--launch] [--clean] [--restore]`
  - Starts projects in dependency order.
  - `--launch` opens each started API at `/scalar`.
  - `--clean` runs `dotnet clean` before run.
  - `--restore` runs `dotnet restore` before run.
- `stop [all|group|project]`
  - Stops tracked processes and cleans stale tracking data.
- `list`
  - Shows project status table with base port, tracked port, status, and groups.
- `logs <project> [--tail|-f]`
  - Shows last log lines (default) or streams with tail mode.

### Stack generation

- `generate [output.yaml]`
- `regenerate`
  - Scans repository for `.csproj` files.
  - Registers ASP.NET Core web projects (`Microsoft.NET.Sdk.Web`) under `apis`.
  - Registers `*.Client` projects under `clients`.
  - Infers API dependencies via project/package references to client libraries.

### Logging API polling

- `logging stream [--interval <seconds>]`
  - Polls `GET /api` on the resolved logging API and refreshes terminal output continuously.
  - Requires a logging project in stack (name `logging` or matching `*-logging[-api]`).

### NuGet client packaging

- `nuget build [all|clientName]`
  - Packs client projects to local NuGet folder (`.manage/nuget` by default).
- `nuget list`
  - Lists local `.nupkg` artifacts.

### Project scaffolding

- `new api <name> [--with-client] [--path <path>] [--no-parent]`
  - Creates API solution skeleton with API, data, and test projects.
  - Adds Scalar/OpenAPI setup and updates `appsettings` docs toggle.
  - With `--with-client`, also creates client/contracts and corresponding tests.
- `new client <name> [--path <path>] [--no-parent]`
  - Creates client library + test project.

Both `new` commands:

- create/update a solution file (`.sln` or `.slnx`)
- ensure a `.gitignore`
- create README if missing in scaffold root
- attempt to register new projects into `manage.yaml`

### Instructions management

- `add instructions --project-name <name> [--path-to-instructions <file>]`
  - Copies instructions file into one registered project’s `.github/copilot-instructions.md`.
- `update instructions [--path-to-instructions <file>] [--path-to-update <path>]`
  - Updates instructions across all registered project roots or one explicit registered path.

### Test execution

- `run tests [--project-name <name>] [--restore]`
  - Runs discovered `*.Test.csproj` / `*.Tests.csproj` projects.
  - Uses coverage collection (`XPlat Code Coverage`).
  - Runs tests in parallel and outputs colored summary.
  - Writes artifacts under `.manage/test-results/<timestamp>`.
  - Fails command if any test project fails.

### Git helpers

- `git sync [branch]`
  - Discovers repositories from registered APIs/clients, checks out target branch, and pulls.
  - Uses per-project `default_branch` when no override is provided.
- `git configure`
  - Ensures GitHub CLI auth and validates credential helper configuration.
- `git help`
  - Shows Git command help.

#### Branch operations

```powershell
.\manage.ps1 git branch [program] <new|delete|list|swap> [feature|hotfix] <branchname>
.\manage.ps1 git branch [program] swap pick
.\manage.ps1 git branch help
```

Behavior notes:

- `program` can be omitted; script tries to resolve it from current directory/repo.
- `new` branches are created from `origin/dev` and pushed with upstream.
- `delete` removes remote and local branches (if present).
- `swap` checks out local branch or creates tracking branch from origin.
- `swap pick` provides an interactive numbered selection.

### Upgrade helper

- `upgrade <version> <project>`
  - Updates target framework in selected project and runs restore.
  - Prints outdated package information.

### Shorthand alias

- `shorthand [--alias <name>] [--persist]`
  - Creates a PowerShell function alias for `manage.ps1`.
  - Session-only by default; `--persist` writes it to your PowerShell profile.

### Help

- `help`, `-h`, `--help`

## Environment Variables

- `STACK_FILE`: stack definition file path (default `manage.yaml`)
- `DOTNET_CMD`: dotnet executable (default `dotnet`)
- `DOTNET_VERSION`: required dotnet version prefix (optional)
- `BUILD_CONFIGURATION`: `Debug` or `Release` (default `Debug`)
- `ASPNETCORE_ENVIRONMENT`: runtime environment override
- `START_DELAY_SECONDS`: delay between dependency-ordered starts (default `3`)
- `DEV_PORT_OFFSET`: start port offset before search (default `0`)
- `PORT_SEARCH_LIMIT`: max port increments to search (default `200`)
- `STARTUP_TIMEOUT_SECONDS`: startup wait timeout (default `60`)
- `STARTUP_POLL_SECONDS`: startup polling interval (default `1`)
- `STARTUP_PROGRESS_SECONDS`: startup progress dot interval (default `1`)
- `LOG_TAIL_LINES`: default tail line count (default `25`)
- `NUGET_DIR`: local NuGet output folder (default `.manage/nuget`)
- `GENERATE_BASE_PORT`: base port for `generate` command (default `5101`)

## Working Directories and Artifacts

The script creates and uses:

- `.manage/logs` for stdout/stderr process logs
- `.manage/pids` for pid/port tracking files
- `.manage/nuget` for local package artifacts
- `.manage/test-results/<timestamp>` for test/coverage outputs

## Notes

- Most commands require a valid stack file. If missing, run:

```powershell
.\manage.ps1 generate
```

- `start` automatically resolves dependencies and starts in topological order.
- If a project is already listening on its base port, it is treated as running and tracked.