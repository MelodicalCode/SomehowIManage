param(
    [string]$Command = "list",
    [string]$Target = "all",
    [switch]$Tail
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $RootDir ".manage\logs"
$PidDir = Join-Path $RootDir ".manage\pids"

$StartDelaySeconds = if ($env:START_DELAY_SECONDS) { [int]$env:START_DELAY_SECONDS } else { 3 }
$BuildConfigurationRaw = if ($env:BUILD_CONFIGURATION) { $env:BUILD_CONFIGURATION } else { "Debug" }
$DotnetCmd = if ($env:DOTNET_CMD) { $env:DOTNET_CMD } else { "dotnet" }
$DotnetVersionRequired = if ($env:DOTNET_VERSION) { $env:DOTNET_VERSION } else { "" }
$PortSearchLimit = if ($env:PORT_SEARCH_LIMIT) { [int]$env:PORT_SEARCH_LIMIT } else { 200 }
$DevPortOffset = if ($env:DEV_PORT_OFFSET) { [int]$env:DEV_PORT_OFFSET } else { 0 }
$StackFile = if ($env:STACK_FILE) { $env:STACK_FILE } else { Join-Path $RootDir "manage.yaml" }
$StartupTimeoutSeconds = if ($env:STARTUP_TIMEOUT_SECONDS) { [int]$env:STARTUP_TIMEOUT_SECONDS } else { 60 }
$StartupPollSeconds = if ($env:STARTUP_POLL_SECONDS) { [int]$env:STARTUP_POLL_SECONDS } else { 1 }
$StartupProgressSeconds = if ($env:STARTUP_PROGRESS_SECONDS) { [int]$env:STARTUP_PROGRESS_SECONDS } else { 1 }
$LogTailLines = if ($env:LOG_TAIL_LINES) { [int]$env:LOG_TAIL_LINES } else { 25 }
$NugetDir = if ($env:NUGET_DIR) { $env:NUGET_DIR } else { Join-Path $RootDir ".manage\nuget" }

if (-not $Tail -and (($args -contains "--tail") -or ($args -contains "-f"))) {
    $Tail = $true
}

switch ($BuildConfigurationRaw.ToLowerInvariant()) {
    "debug" {
        $BuildConfiguration = "Debug"
        $DefaultAspNetCoreEnvironment = "Development"
    }
    "release" {
        $BuildConfiguration = "Release"
        $DefaultAspNetCoreEnvironment = "Production"
    }
    default {
        throw "Invalid BUILD_CONFIGURATION: $BuildConfigurationRaw (expected Debug or Release)"
    }
}

$AspNetCoreEnvironment = if ($env:ASPNETCORE_ENVIRONMENT) { $env:ASPNETCORE_ENVIRONMENT } else { $DefaultAspNetCoreEnvironment }
$ActiveDotnetVersion = ""
$AllocatedPorts = New-Object 'System.Collections.Generic.HashSet[int]'
$Projects = @()
$Groups = @()
$Clients = @()
$ProjectDependencies = @{}

if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}
if (-not (Test-Path -LiteralPath $PidDir)) {
    New-Item -ItemType Directory -Path $PidDir | Out-Null
}

function Show-Usage {
    $commandColWidth = 29
    function Write-UsageCommand {
        param(
            [string]$CommandText,
            [string]$DescriptionText
        )

        Write-Host ("  " + $CommandText.PadRight($commandColWidth) + " " + $DescriptionText)
    }

    Write-Host "Usage: .\manage.ps1 <command> [target]"
    Write-Host ""
    Write-Host "Stack file: $StackFile"
    Write-Host "Commands:"
    Write-UsageCommand -CommandText "start [all|group|project] [--launch] [--clean] [--restore]" -DescriptionText "Start services and optionally pre-clean/restore before run; launch /scalar in browser"
    Write-UsageCommand -CommandText "stop [all|group|project]" -DescriptionText "Stop all services, one group, or one project"
    Write-UsageCommand -CommandText "generate [output.yaml]" -DescriptionText "Scan repo for web apps and generate stack yaml"
    Write-UsageCommand -CommandText "regenerate" -DescriptionText "Recreate stack file from current repository projects"
    Write-UsageCommand -CommandText "nuget build [all|client]" -DescriptionText "Build NuGet package(s) from clients into ./.manage/nuget"
    Write-UsageCommand -CommandText "nuget list" -DescriptionText "List local .nupkg artifacts under ./.manage/nuget"
    Write-UsageCommand -CommandText "list" -DescriptionText "List controllable APIs and ports"
    Write-UsageCommand -CommandText "logs <project> [--tail]" -DescriptionText "Show last $LogTailLines log lines or stream live logs"
    Write-UsageCommand -CommandText "logging stream [--interval <seconds>]" -DescriptionText "Poll GET /api on local logging API and refresh terminal output in place"
    Write-UsageCommand -CommandText "upgrade <version> <project>" -DescriptionText "Upgrade project to .NET version and update NuGet packages"
    Write-UsageCommand -CommandText "git sync [branch]" -DescriptionText "Checkout+pull all repos using default_branch from stack (or override branch)"
    Write-UsageCommand -CommandText "git configure" -DescriptionText "Install GitHub CLI if needed, authenticate, and validate git credential helper setup"
    Write-UsageCommand -CommandText "git branch [program] <new|delete|list|swap> [feature|hotfix] <branchname>" -DescriptionText "Manage branches; omit [program] to resolve from current folder"
    Write-UsageCommand -CommandText "git branch help" -DescriptionText "Show git branch command help"
    Write-UsageCommand -CommandText "git help" -DescriptionText "Show git command help"
    Write-UsageCommand -CommandText "new api <name> [--with-client] [--path <path>] [--no-parent]" -DescriptionText "Scaffold API solution with tests and optional client/contracts"
    Write-UsageCommand -CommandText "new client <name> [--path <path>] [--no-parent]" -DescriptionText "Scaffold client solution with test project"
    Write-UsageCommand -CommandText "add instructions --project-name <name> [--path-to-instructions <file>]" -DescriptionText "Copy copilot instructions file into one registered project's .github folder"
    Write-UsageCommand -CommandText "update instructions [--path-to-instructions <file>] [--path-to-update <path>]" -DescriptionText "Overwrite instructions in all or one target project directory"
    Write-UsageCommand -CommandText "run tests [--project-name <name>] [--restore]" -DescriptionText "Run dotnet test with coverage; defaults to --no-restore unless --restore is specified"
    Write-UsageCommand -CommandText "shorthand [--alias <name>] [--persist]" -DescriptionText "Set a PowerShell function alias (session-only by default; use --persist for future sessions)"
    Write-UsageCommand -CommandText "help" -DescriptionText "Show this help"
    Write-Host ""
    Write-Host "Groups: $(Get-GroupNamesCsv)"
    Write-Host "APIs: $(Get-ProjectNamesCsv)"
    Write-Host "Clients: $(Get-ClientNamesCsv)"
}

function Get-ProjectNamesCsv {
    if ($Projects.Count -eq 0) {
        return "<none loaded>"
    }

    return (($Projects | ForEach-Object { $_.Name }) -join ", ")
}

function Get-GroupNamesCsv {
    if ($Groups.Count -eq 0) {
        return "<none loaded>"
    }

    return (($Groups | ForEach-Object { $_.Name }) -join ", ")
}

function Get-ClientNamesCsv {
    if ($Clients.Count -eq 0) {
        return "<none loaded>"
    }

    return (($Clients | ForEach-Object { $_.Name }) -join ", ")
}

function Get-Client {
    param([string]$Name)
    return $Clients | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Remove-SurroundingQuotes {
    param([string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    $value = $Text.Trim()
    if ($value.Length -ge 2) {
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            return $value.Substring(1, $value.Length - 2)
        }
    }

    return $value
}

function Resolve-DefaultBranchName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "develop"
    }

    return $Value.Trim()
}

function Load-StackDefinition {
    if (-not (Test-Path -LiteralPath $StackFile)) {
        throw "Stack file not found: $StackFile"
    }

    $projects = @()
    $groupMap = @{}
    $deps = @{}
    $clients = @()

    $contentLines = Get-Content -LiteralPath $StackFile
    $firstContentLine = $null
    foreach ($l in $contentLines) {
        $t = $l.Trim()
        if (-not [string]::IsNullOrWhiteSpace($t) -and -not $t.StartsWith("#")) {
            $firstContentLine = $t
            break
        }
    }

    $isYaml = ($firstContentLine -eq "apis:") -or ($firstContentLine -eq "projects:")

    if ($isYaml) {
        $currentProject = $null
        $currentClient = $null
        $currentSection = ""

        $projectClientsMap = @{}

        $flushProject = {
            param($item)
            if ($null -eq $item) {
                return
            }

            $name = [string]$item.Name
            $relPath = [string]$item.Path
            $basePortText = [string]$item.Port
            $dependsCsv = [string]$item.DependsOn
            $groupsCsv = [string]$item.Groups
            $defaultBranch = Resolve-DefaultBranchName -Value ([string]$item.DefaultBranch)

            if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($relPath) -or [string]::IsNullOrWhiteSpace($basePortText)) {
                throw "Invalid YAML project entry in stack file: $StackFile"
            }

            $basePort = 0
            if (-not [int]::TryParse($basePortText, [ref]$basePort)) {
                throw "Invalid base port '$basePortText' for project '$name' in stack file."
            }

            $projects += [pscustomobject]@{ Name = $name; RelPath = $relPath; BasePort = $basePort; DefaultBranch = $defaultBranch }

            if ([string]::IsNullOrWhiteSpace($dependsCsv)) {
                $deps[$name] = @()
            } else {
                $deps[$name] = @($dependsCsv.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }

            if (-not [string]::IsNullOrWhiteSpace($groupsCsv)) {
                foreach ($groupName in @($groupsCsv.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
                    if (-not $groupMap.ContainsKey($groupName)) {
                        $groupMap[$groupName] = New-Object 'System.Collections.Generic.List[string]'
                    }
                    $groupMap[$groupName].Add($name)
                }
            }
        }

        $flushClient = {
            param($item)
            if ($null -eq $item) {
                return
            }

            $name = [string]$item.Name
            $relPath = [string]$item.Path
            $defaultBranch = Resolve-DefaultBranchName -Value ([string]$item.DefaultBranch)

            if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($relPath)) {
                throw "Invalid YAML client entry in stack file: $StackFile"
            }

            $clients += [pscustomobject]@{ Name = $name; RelPath = $relPath; DefaultBranch = $defaultBranch }
        }

        foreach ($rawLine in $contentLines) {
            $line = $rawLine.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
                continue
            }

            if (($line -eq "apis:") -or ($line -eq "projects:")) {
                . $flushClient $currentClient
                $currentClient = $null
                $currentSection = "apis"
                continue
            }

            if ($line -eq "clients:") {
                . $flushProject $currentProject
                $currentProject = $null
                $currentSection = "clients"
                continue
            }

            if ($line -match "^-\s*name:\s*(.+)$") {
                $nameValue = Remove-SurroundingQuotes -Text $Matches[1]
                if ($currentSection -eq "apis") {
                    . $flushProject $currentProject
                    $currentProject = [ordered]@{ Name = $nameValue; Path = ""; Port = ""; DependsOn = ""; Groups = ""; DefaultBranch = "develop" }
                } elseif ($currentSection -eq "clients") {
                    . $flushClient $currentClient
                    $currentClient = [ordered]@{ Name = $nameValue; Path = ""; DefaultBranch = "develop" }
                }
                continue
            }

            if ($currentSection -eq "apis" -and $null -ne $currentProject) {
                if ($line -match "^path:\s*(.+)$") {
                    $currentProject.Path = Remove-SurroundingQuotes -Text $Matches[1]
                    continue
                }

                if ($line -match "^port:\s*([0-9]+)$") {
                    $currentProject.Port = $Matches[1].Trim()
                    continue
                }

                if ($line -match "^depends_on:\s*(.*)$") {
                    $dependsRaw = $Matches[1].Trim()
                    $dependsRaw = $dependsRaw.TrimStart("[").TrimEnd("]")
                    $currentProject.DependsOn = @($dependsRaw.Split(",") | ForEach-Object { Remove-SurroundingQuotes -Text $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ","
                    continue
                }

                if ($line -match "^groups:\s*(.*)$") {
                    $groupsRaw = $Matches[1].Trim()
                    $groupsRaw = $groupsRaw.TrimStart("[").TrimEnd("]")
                    $currentProject.Groups = @($groupsRaw.Split(",") | ForEach-Object { Remove-SurroundingQuotes -Text $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ","
                    continue
                }

                if ($line -match "^default_branch:\s*(.+)$") {
                    $currentProject.DefaultBranch = Resolve-DefaultBranchName -Value (Remove-SurroundingQuotes -Text $Matches[1])
                    continue
                }
            }

            if ($currentSection -eq "clients" -and $null -ne $currentClient) {
                if ($line -match "^path:\s*(.+)$") {
                    $currentClient.Path = Remove-SurroundingQuotes -Text $Matches[1]
                    continue
                }

                if ($line -match "^default_branch:\s*(.+)$") {
                    $currentClient.DefaultBranch = Resolve-DefaultBranchName -Value (Remove-SurroundingQuotes -Text $Matches[1])
                    continue
                }
            }
        }

        . $flushProject $currentProject
        . $flushClient $currentClient
    }

    if (-not $isYaml) {
        foreach ($rawLine in $contentLines) {
            $line = $rawLine.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
                continue
            }

            $parts = $line.Split("|")
            if ($parts.Count -lt 3) {
                throw "Invalid stack line (expected name|path|port|depends_on|groups): $line"
            }

            $name = $parts[0].Trim()
            $relPath = $parts[1].Trim()
            $basePortText = $parts[2].Trim()
            $dependsCsv = if ($parts.Count -ge 4) { $parts[3].Trim() } else { "" }
            $groupsCsv = if ($parts.Count -ge 5) { $parts[4].Trim() } else { "" }

            if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($relPath) -or [string]::IsNullOrWhiteSpace($basePortText)) {
                throw "Invalid stack line (expected name|path|port|depends_on|groups): $line"
            }

            $basePort = 0
            if (-not [int]::TryParse($basePortText, [ref]$basePort)) {
                throw "Invalid base port '$basePortText' for project '$name' in stack file."
            }

            $defaultBranch = if ($parts.Count -ge 6) { Resolve-DefaultBranchName -Value $parts[5].Trim() } else { "develop" }
            $projects += [pscustomobject]@{ Name = $name; RelPath = $relPath; BasePort = $basePort; DefaultBranch = $defaultBranch }

            if ([string]::IsNullOrWhiteSpace($dependsCsv)) {
                $deps[$name] = @()
            } else {
                $deps[$name] = @($dependsCsv.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }

            if (-not [string]::IsNullOrWhiteSpace($groupsCsv)) {
                foreach ($groupName in @($groupsCsv.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
                    if (-not $groupMap.ContainsKey($groupName)) {
                        $groupMap[$groupName] = New-Object 'System.Collections.Generic.List[string]'
                    }
                    $groupMap[$groupName].Add($name)
                }
            }
        }
    }

    if ($projects.Count -eq 0) {
        throw "No APIs loaded from stack file: $StackFile"
    }

    $groups = @()
    foreach ($groupName in $groupMap.Keys) {
        $groups += [pscustomobject]@{ Name = $groupName; Members = @($groupMap[$groupName]) }
    }

    $script:Projects = $projects
    $script:Groups = $groups
    $script:Clients = $clients
    $script:ProjectDependencies = $deps
}

function Convert-ToSlug {
    param([string]$Text)

    $value = if ($null -eq $Text) { "app" } else { $Text.ToLowerInvariant() }
    $value = [regex]::Replace($value, "[^a-z0-9]+", "-").Trim("-")
    if ([string]::IsNullOrWhiteSpace($value)) {
        return "app"
    }

    return $value
}

function Generate-StackFile {
    param([string]$OutputPath)

    $basePort = if ($env:GENERATE_BASE_PORT) { [int]$env:GENERATE_BASE_PORT } else { 5101 }
    $currentPort = $basePort
    $seenNames = @{}
    $seenClientNames = @{}
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $clientRows = New-Object 'System.Collections.Generic.List[object]'
    $resolvedRoot = (Resolve-Path -LiteralPath $RootDir).Path
    $webCsprojByName = @{}
    $apiNameByPath = @{}
    $clientNameByPath = @{}
    $clientNameByProjectFileName = @{}
    $clientNameByPackageId = @{}
    $dependsByApiName = @{}
    $apiNameByBaseName = @{}

    if ([string]::IsNullOrWhiteSpace($OutputPath) -or $OutputPath -eq "all") {
        $OutputPath = $StackFile
    } elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath = Join-Path $RootDir $OutputPath
    }

    $csprojFiles = Get-ChildItem -Path $RootDir -Recurse -Filter *.csproj -File | Where-Object {
        $_.FullName -notmatch "[\\/](bin|obj)[\\/]"
    } | Sort-Object FullName

    foreach ($file in $csprojFiles) {
        $projectFileName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $fullRoot = [System.IO.Path]::GetFullPath($resolvedRoot)
        $fullFile = [System.IO.Path]::GetFullPath($file.FullName)
        if ($fullFile.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relativePath = $fullFile.Substring($fullRoot.Length).TrimStart([char[]]@([char]92, [char]47))
        } else {
            $relativePath = $file.Name
        }
        $relativePath = ($relativePath -replace "\\", "/")

        if ($projectFileName.EndsWith(".Client", [System.StringComparison]::OrdinalIgnoreCase)) {
            $clientBaseName = Convert-ToSlug -Text $projectFileName
            $clientName = $clientBaseName
            $clientSuffix = 2
            while ($seenClientNames.ContainsKey($clientName)) {
                $clientName = "$clientBaseName-$clientSuffix"
                $clientSuffix++
            }
            $seenClientNames[$clientName] = $true

            $clientRows.Add([pscustomobject]@{
                Name = $clientName
                Path = $relativePath
            }) | Out-Null

            $clientPathKey = $relativePath.ToLowerInvariant()
            if (-not $clientNameByPath.ContainsKey($clientPathKey)) {
                $clientNameByPath[$clientPathKey] = $clientName
            }

            $clientProjectFileNameKey = $projectFileName.ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($clientProjectFileNameKey) -and -not $clientNameByProjectFileName.ContainsKey($clientProjectFileNameKey)) {
                $clientNameByProjectFileName[$clientProjectFileNameKey] = $clientName
            }

            $clientPackageId = ""
            try {
                [xml]$clientCsprojXml = Get-Content -LiteralPath $file.FullName -Raw
                $packageIdNodes = $clientCsprojXml.SelectNodes("//*[local-name()='PackageId']")
                if ($null -ne $packageIdNodes -and $packageIdNodes.Count -gt 0) {
                    $clientPackageId = [string]$packageIdNodes[0].InnerText
                }
            } catch {
            }

            if ([string]::IsNullOrWhiteSpace($clientPackageId)) {
                $clientPackageId = $projectFileName
            }

            $clientPackageIdKey = $clientPackageId.Trim().ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($clientPackageIdKey) -and -not $clientNameByPackageId.ContainsKey($clientPackageIdKey)) {
                $clientNameByPackageId[$clientPackageIdKey] = $clientName
            }
        }

        $isWeb = Select-String -Path $file.FullName -Pattern '<Project[^>]*Sdk="Microsoft\.NET\.Sdk\.Web"' -Quiet
        if (-not $isWeb) {
            continue
        }

        $baseName = Convert-ToSlug -Text $projectFileName
        $name = $baseName
        $suffix = 2
        while ($seenNames.ContainsKey($name)) {
            $name = "$baseName-$suffix"
            $suffix++
        }
        $seenNames[$name] = $true

        $rows.Add([pscustomobject]@{
            Name = $name
            Path = $relativePath
            Port = $currentPort
        }) | Out-Null

        $apiPathKey = $relativePath.ToLowerInvariant()
        if (-not $apiNameByPath.ContainsKey($apiPathKey)) {
            $apiNameByPath[$apiPathKey] = $name
        }

        if (-not $dependsByApiName.ContainsKey($name)) {
            $dependsByApiName[$name] = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        }

        $webCsprojByName[$name] = $file.FullName

        $currentPort++
    }

    if ($rows.Count -eq 0) {
        throw "No ASP.NET Core web projects found (Microsoft.NET.Sdk.Web)."
    }

    foreach ($row in $rows) {
        $apiName = [string]$row.Name
        $baseName = $apiName
        if ($baseName.EndsWith("-api", [System.StringComparison]::OrdinalIgnoreCase)) {
            $baseName = $baseName.Substring(0, $baseName.Length - "-api".Length)
        }

        if (-not $apiNameByBaseName.ContainsKey($baseName)) {
            $apiNameByBaseName[$baseName] = $apiName
        }
    }

    foreach ($apiName in $webCsprojByName.Keys) {
        $apiCsprojPath = $webCsprojByName[$apiName]
        [xml]$apiCsprojXml = Get-Content -LiteralPath $apiCsprojPath -Raw
        $apiCsprojDir = Split-Path -Parent $apiCsprojPath

        $projectReferenceNodes = $apiCsprojXml.SelectNodes("//*[local-name()='ProjectReference']")
        if ($null -ne $projectReferenceNodes) {
            foreach ($projectReferenceNode in $projectReferenceNodes) {
            $includePath = [string]$projectReferenceNode.GetAttribute("Include")
            if ([string]::IsNullOrWhiteSpace($includePath)) {
                continue
            }

            $referencedCsprojFullPath = [System.IO.Path]::GetFullPath((Join-Path $apiCsprojDir $includePath))
            $referencedRelativePath = ""
            $fullRoot = [System.IO.Path]::GetFullPath($resolvedRoot)
            if ($referencedCsprojFullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $referencedRelativePath = $referencedCsprojFullPath.Substring($fullRoot.Length).TrimStart([char[]]@([char]92, [char]47))
            } else {
                continue
            }

            $referencedRelativePath = ($referencedRelativePath -replace "\\", "/")
            $referencedPathKey = $referencedRelativePath.ToLowerInvariant()

            $clientName = ""
            if ($clientNameByPath.ContainsKey($referencedPathKey)) {
                $clientName = [string]$clientNameByPath[$referencedPathKey]
            } else {
                $referencedProjectFileName = [System.IO.Path]::GetFileNameWithoutExtension($includePath)
                $referencedProjectFileNameKey = if ([string]::IsNullOrWhiteSpace($referencedProjectFileName)) { "" } else { $referencedProjectFileName.ToLowerInvariant() }
                if (-not [string]::IsNullOrWhiteSpace($referencedProjectFileNameKey) -and $clientNameByProjectFileName.ContainsKey($referencedProjectFileNameKey)) {
                    $clientName = [string]$clientNameByProjectFileName[$referencedProjectFileNameKey]
                }
            }

            if ([string]::IsNullOrWhiteSpace($clientName)) {
                continue
            }

            $inferredApiName = $clientName
            if ($inferredApiName.EndsWith("-client", [System.StringComparison]::OrdinalIgnoreCase)) {
                $inferredApiName = $inferredApiName.Substring(0, $inferredApiName.Length - "-client".Length)
            }

            if ($apiNameByBaseName.ContainsKey($inferredApiName)) {
                $inferredApiName = [string]$apiNameByBaseName[$inferredApiName]
            }

            if ($inferredApiName -eq $apiName) {
                continue
            }

            if ($dependsByApiName.ContainsKey($apiName)) {
                [void]$dependsByApiName[$apiName].Add($inferredApiName)
            }
        }
        }

        $packageReferenceNodes = $apiCsprojXml.SelectNodes("//*[local-name()='PackageReference']")
        if ($null -ne $packageReferenceNodes) {
            foreach ($packageReferenceNode in $packageReferenceNodes) {
                $packageId = [string]$packageReferenceNode.GetAttribute("Include")
                if ([string]::IsNullOrWhiteSpace($packageId)) {
                    continue
                }

                $packageIdKey = $packageId.Trim().ToLowerInvariant()
                $clientName = ""
                if ($clientNameByPackageId.ContainsKey($packageIdKey)) {
                    $clientName = [string]$clientNameByPackageId[$packageIdKey]
                } else {
                    $clientName = Convert-ToSlug -Text $packageId
                }

                $inferredApiName = $clientName
                if ($inferredApiName.EndsWith("-client", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $inferredApiName = $inferredApiName.Substring(0, $inferredApiName.Length - "-client".Length)
                } else {
                    continue
                }

                if ($apiNameByBaseName.ContainsKey($inferredApiName)) {
                    $inferredApiName = [string]$apiNameByBaseName[$inferredApiName]
                }

                if ($inferredApiName -eq $apiName) {
                    continue
                }

                if ($dependsByApiName.ContainsKey($apiName)) {
                    [void]$dependsByApiName[$apiName].Add($inferredApiName)
                }
            }
        }
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("apis:") | Out-Null
    foreach ($row in $rows) {
        $dependsOn = @()
        if ($dependsByApiName.ContainsKey($row.Name)) {
            $dependsOn = @($dependsByApiName[$row.Name] | Sort-Object)
        }
        $dependsOnYaml = if ($dependsOn.Count -eq 0) { "[]" } else { "[" + (($dependsOn | ForEach-Object { "'$_'" }) -join ", ") + "]" }

        $lines.Add("  - name: $($row.Name)") | Out-Null
        $lines.Add("    path: $($row.Path)") | Out-Null
        $lines.Add("    port: $($row.Port)") | Out-Null
        $lines.Add("    depends_on: $dependsOnYaml") | Out-Null
        $lines.Add("    groups: []") | Out-Null
        $lines.Add("    default_branch: develop") | Out-Null
        $lines.Add("") | Out-Null
    }

    if ($clientRows.Count -gt 0) {
        $lines.Add("clients:") | Out-Null
        foreach ($client in $clientRows) {
            $lines.Add("  - name: $($client.Name)") | Out-Null
            $lines.Add("    path: $($client.Path)") | Out-Null
            $lines.Add("    default_branch: develop") | Out-Null
            $lines.Add("") | Out-Null
        }
    }

    Set-Content -LiteralPath $OutputPath -Value $lines -Encoding UTF8
    Write-Host "Generated $OutputPath with $($rows.Count) web projects and $($clientRows.Count) client projects."
}

function Show-Clients {
    if (-not (Test-Path -LiteralPath $NugetDir)) {
        Write-Host "No local NuGet directory found at $NugetDir"
        return
    }

    $items = Get-ChildItem -LiteralPath $NugetDir -Recurse -File -Filter *.nupkg | Sort-Object FullName
    if ($items.Count -eq 0) {
        Write-Host "No local NuGet packages found in $NugetDir"
        return
    }

    $root = [System.IO.Path]::GetFullPath($NugetDir)
    $rows = foreach ($item in $items) {
        $fullItem = [System.IO.Path]::GetFullPath($item.FullName)
        $relativePath = if ($fullItem.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $fullItem.Substring($root.Length).TrimStart([char[]]@([char]92, [char]47))
        } else {
            $item.Name
        }

        [pscustomobject]@{
            Package = ($relativePath -replace "\\", "/")
            SizeKB = [Math]::Round(($item.Length / 1KB), 2)
            Modified = $item.LastWriteTime
        }
    }

    $rows | Format-Table -AutoSize -Wrap
}

function Build-NugetPackages {
    param([string]$TargetName = "all")

    Validate-DotnetForStart

    if ($Clients.Count -eq 0) {
        throw "No clients loaded from stack file: $StackFile"
    }

    if (-not (Test-Path -LiteralPath $NugetDir)) {
        New-Item -ItemType Directory -Path $NugetDir | Out-Null
    }

    $clientsToBuild = @()
    if ($TargetName -eq "all") {
        $clientsToBuild = $Clients
    } else {
        $client = Get-Client -Name $TargetName
        if ($null -eq $client) {
            throw "Unknown client: $TargetName"
        }
        $clientsToBuild = @($client)
    }

    Write-Host "Using dotnet command: $DotnetCmd"
    Write-Host "Using dotnet version: $ActiveDotnetVersion"
    Write-Host "Using BUILD_CONFIGURATION=$BuildConfiguration"
    Write-Host "Packing NuGet package(s) into: $NugetDir"

    foreach ($client in $clientsToBuild) {
        $projectPath = Join-Path $RootDir $client.RelPath
        if (-not (Test-Path -LiteralPath $projectPath)) {
            throw "Client project not found for '$($client.Name)' at $projectPath"
        }

        Write-Host "Packing client $($client.Name)..."
        & $DotnetCmd pack $projectPath --configuration $BuildConfiguration --output $NugetDir
        if ($LASTEXITCODE -ne 0) {
            throw "NuGet pack failed for client '$($client.Name)'"
        }
    }

    Write-Host "Packed $($clientsToBuild.Count) client package(s) into $NugetDir"
}

function Ensure-LocalNugetConfig {
    param([string]$RelPath)

    $normalizedRelPath = ($RelPath -replace "\\", "/")
    $segments = $normalizedRelPath.Split("/")
    if ($segments.Count -lt 2 -or [string]::IsNullOrWhiteSpace($segments[0])) {
        Write-Host "Skipping local NuGet.config for '$RelPath': unable to resolve repository root."
        return
    }

    $repoRoot = Join-Path $RootDir $segments[0]
    if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) {
        Write-Host "Skipping local NuGet.config for '$RelPath': repository root '$repoRoot' not found."
        return
    }

    $nugetConfigPath = Join-Path $repoRoot "NuGet.config"
    $localSource = [System.IO.Path]::GetFullPath($NugetDir)
    $configContent = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="local-manage" value="$localSource" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
"@
    Set-Content -LiteralPath $nugetConfigPath -Value $configContent -Encoding UTF8

    $gitignorePath = Join-Path $repoRoot ".gitignore"
    $ignoreEntry = "/NuGet.config"
    if (-not (Test-Path -LiteralPath $gitignorePath)) {
        Set-Content -LiteralPath $gitignorePath -Value $ignoreEntry -Encoding UTF8
    } else {
        $gitignoreLines = @(Get-Content -LiteralPath $gitignorePath -ErrorAction SilentlyContinue)
        $hasExactIgnore = $false
        foreach ($line in $gitignoreLines) {
            if ($line.Trim() -ceq $ignoreEntry) {
                $hasExactIgnore = $true
                break
            }
        }
        if (-not $hasExactIgnore) {
            Add-Content -LiteralPath $gitignorePath -Value $ignoreEntry
        }
    }
}

function Resolve-StartOrder {
    param([string[]]$Roots)

    $order = New-Object 'System.Collections.Generic.List[string]'
    $state = @{}

    function Visit-Project {
        param([string]$ProjectName)

        if ($state.ContainsKey($ProjectName)) {
            if ($state[$ProjectName] -eq "done") {
                return
            }

            if ($state[$ProjectName] -eq "visiting") {
                throw "Dependency cycle detected at project: $ProjectName"
            }
        }

        if ($null -eq (Get-Project -Name $ProjectName)) {
            throw "Unknown project in dependency graph: $ProjectName"
        }

        $state[$ProjectName] = "visiting"

        $deps = @()
        if ($ProjectDependencies.ContainsKey($ProjectName)) {
            $deps = $ProjectDependencies[$ProjectName]
        }

        foreach ($dep in $deps) {
            Visit-Project -ProjectName $dep
        }

        $state[$ProjectName] = "done"
        $order.Add($ProjectName)
    }

    foreach ($root in $Roots) {
        Visit-Project -ProjectName $root
    }

    return @($order)
}

function Get-LogTailText {
    param([string[]]$LogFiles)

    $chunks = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in $LogFiles) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }

        try {
            $tail = Get-Content -LiteralPath $candidate -Tail $LogTailLines -ErrorAction SilentlyContinue
            if ($null -eq $tail) {
                continue
            }

            $chunks.Add($tail -join [Environment]::NewLine) | Out-Null
        } catch {
        }
    }

    if ($chunks.Count -eq 0) {
        return ""
    }

    return ($chunks -join ([Environment]::NewLine + [Environment]::NewLine))
}

function Test-StartupExceptionInLog {
    param([string[]]$LogFiles)

    foreach ($candidate in $LogFiles) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }

        try {
            $tail = Get-Content -LiteralPath $candidate -Tail 300 -ErrorAction SilentlyContinue
            if ($null -eq $tail) {
                continue
            }

            if ($tail | Select-String -Pattern "Unhandled exception|Exception:" -Quiet) {
                return $true
            }
        } catch {
        }
    }

    return $false
}

function Wait-ForProjectStartup {
    param(
        [string]$Name,
        [int]$ProcessId,
        [int]$Port,
        [string]$LogFile,
        [string]$ErrorLogFile
    )

        Write-Host -NoNewline "  waiting for startup: port $Port (timeout ${StartupTimeoutSeconds}s) "

    $startTime = Get-Date
    $deadline = $startTime.AddSeconds($StartupTimeoutSeconds)
    $nextProgress = $StartupProgressSeconds
    while ((Get-Date) -lt $deadline) {
        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $proc) {
            Write-Host ""
            $tailText = Get-LogTailText -LogFiles @($LogFile, $ErrorLogFile)
            throw "Startup failed for ${Name}: process exited before listening on port $Port.$([Environment]::NewLine)$tailText"
        }

        if (Test-StartupExceptionInLog -LogFiles @($LogFile, $ErrorLogFile)) {
            Write-Host ""
            $tailText = Get-LogTailText -LogFiles @($LogFile, $ErrorLogFile)
            throw "Startup failed for ${Name}: exception detected in log.$([Environment]::NewLine)$tailText"
        }

        if (Test-PortInUse -Port $Port) {
            Write-Host ""
            Write-Host "  startup ready: port $Port is listening"
            return
        }

        Start-Sleep -Seconds $StartupPollSeconds
        $elapsedSeconds = [int]([Math]::Floor(((Get-Date) - $startTime).TotalSeconds))
        if ($elapsedSeconds -ge $nextProgress -and $elapsedSeconds -lt $StartupTimeoutSeconds) {
            Write-Host -NoNewline "."
            $nextProgress += $StartupProgressSeconds
        }
    }

    Write-Host ""
    $timeoutTail = Get-LogTailText -LogFiles @($LogFile, $ErrorLogFile)
    throw "Startup failed for ${Name}: timed out waiting for port $Port after ${StartupTimeoutSeconds}s.$([Environment]::NewLine)$timeoutTail"
}

function Show-Logs {
    param(
        [string]$ProjectName,
        [switch]$Tail
    )

    if ([string]::IsNullOrWhiteSpace($ProjectName) -or $ProjectName -eq "all") {
        throw "Please provide a project name. Example: .\manage.ps1 logs <project> [-Tail]"
    }

    $project = Get-Project -Name $ProjectName
    if ($null -eq $project) {
        throw "Unknown project: $ProjectName"
    }

    $logFile = Join-Path $LogDir "$($project.Name).log"
    if (-not (Test-Path -LiteralPath $logFile)) {
        throw "No log file found for $ProjectName at $logFile"
    }

    if ($Tail) {
        Get-Content -LiteralPath $logFile -Tail $LogTailLines -Wait
    } else {
        Get-Content -LiteralPath $logFile -Tail $LogTailLines
    }
}

function Get-LoggingStreamOptions {
    param([string[]]$RawArgs)

    $intervalSeconds = 10
    $tokens = if ($null -eq $RawArgs) { @() } else { @($RawArgs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) }

    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = [string]$tokens[$i]
        if ($token -eq "--interval") {
            if (($i + 1) -ge $tokens.Count) {
                throw "Missing value for --interval. Usage: .\\manage.ps1 logging stream [--interval <seconds>]"
            }

            $intervalText = [string]$tokens[$i + 1]
            $parsed = 0
            if (-not [int]::TryParse($intervalText, [ref]$parsed) -or $parsed -le 0) {
                throw "Invalid --interval value '$intervalText'. Use a positive integer."
            }

            $intervalSeconds = $parsed
            $i++
            continue
        }

        throw "Unknown option: $token"
    }

    return [pscustomobject]@{
        IntervalSeconds = $intervalSeconds
    }
}

function Resolve-LoggingProjectForStream {
    $exact = Get-Project -Name "logging"
    if ($null -ne $exact) {
        return $exact
    }

    $candidate = $Projects | Where-Object {
        $_.Name -match "(^|-)logging(-api)?$"
    } | Select-Object -First 1

    if ($null -eq $candidate) {
        throw "Unable to resolve logging API project from stack. Ensure manage.yaml has a logging API entry."
    }

    return $candidate
}

function Convert-ToSingleLineText {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    $text = [string]$Value
    $text = $text -replace "`r", " "
    $text = $text -replace "`n", " "
    $text = [regex]::Replace($text, "\s+", " ").Trim()
    return $text
}

function Format-FixedWidthCell {
    param(
        [string]$Value,
        [int]$Width
    )

    $safeValue = if ($null -eq $Value) { "" } else { $Value }
    if ($Width -lt 1) {
        return ""
    }

    if ($safeValue.Length -gt $Width) {
        if ($Width -le 3) {
            return $safeValue.Substring(0, $Width)
        }

        return ($safeValue.Substring(0, $Width - 3) + "...")
    }

    return $safeValue.PadRight($Width)
}

function Show-LoggingTable {
    param([object]$JsonData)

    if ($null -eq $JsonData) {
        Write-Host "<empty response body>"
        return
    }

    $rows = @()
    if ($JsonData -is [System.Collections.IEnumerable] -and -not ($JsonData -is [string])) {
        foreach ($item in $JsonData) {
            $rows += $item
        }
    } else {
        $rows = @($JsonData)
    }

    if ($rows.Count -eq 0) {
        Write-Host "<empty response body>"
        return
    }

    $columns = @(
        [pscustomobject]@{ Header = "type"; Width = 15; Selector = { param($r) Convert-ToSingleLineText $r.log_type } },
        [pscustomobject]@{ Header = "level"; Width = 11; Selector = { param($r) Convert-ToSingleLineText $r.log_level } },
        [pscustomobject]@{ Header = "caller"; Width = 26; Selector = { param($r) Convert-ToSingleLineText $r.caller } },
        [pscustomobject]@{ Header = "message"; Width = 56; Selector = { param($r) Convert-ToSingleLineText $r.Log_message } },
        [pscustomobject]@{ Header = "correlation_id"; Width = 36; Selector = { param($r) Convert-ToSingleLineText $r.correlation_id } }
    )

    $header = ($columns | ForEach-Object { Format-FixedWidthCell -Value $_.Header -Width $_.Width }) -join " | "
    $separator = ($columns | ForEach-Object { "-" * $_.Width }) -join "-+-"
    Write-Host $header
    Write-Host $separator

    foreach ($row in $rows) {
        $line = ($columns | ForEach-Object {
            $rawValue = & $_.Selector $row
            Format-FixedWidthCell -Value $rawValue -Width $_.Width
        }) -join " | "
        Write-Host $line
    }
}

function Invoke-LoggingStreamCommand {
    param([string[]]$RawArgs)

    $curlCommand = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -eq $curlCommand) {
        throw "curl.exe was not found on PATH."
    }

    $options = Get-LoggingStreamOptions -RawArgs $RawArgs
    $loggingProject = Resolve-LoggingProjectForStream
    $port = [int]$loggingProject.BasePort
    $url = "http://localhost:$port/api"

    $initialResponse = & curl.exe "-sS" "--max-time" "5" $url 2>&1
    if ($LASTEXITCODE -ne 0) {
        $initialText = if ($null -eq $initialResponse) { "" } else { (($initialResponse | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) }
        throw "Initial ping failed for $url. Ensure the logging API is running locally.$([Environment]::NewLine)$initialText"
    }

    while ($true) {
        $response = & curl.exe "-sS" "--max-time" "10" $url 2>&1
        $exitCode = $LASTEXITCODE

        Clear-Host
        Write-Host "URL: $url"
        Write-Host "Next refresh in $($options.IntervalSeconds) seconds"
        Write-Host ""

        if ($exitCode -eq 0) {
            $bodyText = if ($null -eq $response) { "" } else { (($response | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) }
            if ([string]::IsNullOrWhiteSpace($bodyText)) {
                Write-Host "<empty response body>"
            } else {
                try {
                    $json = $bodyText | ConvertFrom-Json
                    Show-LoggingTable -JsonData $json
                } catch {
                    # If response isn't valid JSON, still print raw body so stream remains usable.
                    Write-Host $bodyText
                }
            }
        } else {
            $errorText = if ($null -eq $response) { "" } else { (($response | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) }
            Write-Host "Request failed (exit code $exitCode)."
            if (-not [string]::IsNullOrWhiteSpace($errorText)) {
                Write-Host $errorText
            }
        }

        Start-Sleep -Seconds $options.IntervalSeconds
    }
}

function Upgrade-DotnetProject {
    param(
        [string]$DotnetVersion,
        [string]$ProjectName
    )

    Validate-DotnetForStart

    if ([string]::IsNullOrWhiteSpace($DotnetVersion) -or [string]::IsNullOrWhiteSpace($ProjectName)) {
        throw "Usage: upgrade <dotnet-version> <project>"
    }

    $project = Get-Project -Name $ProjectName
    if ($null -eq $project) {
        throw "Unknown project: $ProjectName"
    }

    $projectPath = Join-Path $RootDir $project.RelPath
    if (-not (Test-Path -LiteralPath $projectPath)) {
        throw "Project not found at $projectPath"
    }

    $version = "net${DotnetVersion}".Replace(".", "")

    Write-Host "Upgrading $ProjectName to .NET $DotnetVersion..."
    Write-Host "Project: $projectPath"

    Write-Host "Updating TargetFramework to $version..."
    $csprojContent = Get-Content -LiteralPath $projectPath -Raw
    $csprojContent = $csprojContent -replace '<TargetFramework>net\d+(\.\d+)?</TargetFramework>', "<TargetFramework>$version</TargetFramework>"
    Set-Content -LiteralPath $projectPath -Value $csprojContent -NoNewline

    Write-Host "Restoring dependencies..."
    & $DotnetCmd restore $projectPath

    Write-Host "Updating NuGet packages..."
    & $DotnetCmd list package --project $projectPath --outdated | ForEach-Object {
        if ($_ -match '^\s+>') {
            Write-Host $_
        }
    }

    Write-Host "Upgrade complete for $ProjectName to .NET $DotnetVersion"
}

function Get-GitRepoRoot {
    param([string]$StartPath)

    if ([string]::IsNullOrWhiteSpace($StartPath) -or -not (Test-Path -LiteralPath $StartPath)) {
        return $null
    }

    $root = & git -C $StartPath rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($root)) {
        return $null
    }

    return $root.Trim()
}

function Sync-GitRepositories {
    param([string]$Branch = "")

    $gitExists = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
    if (-not $gitExists) {
        throw "git CLI was not found on PATH."
    }

    $seenRepos = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $repoRoots = New-Object 'System.Collections.Generic.List[string]'
    $repoBranches = @{}

    $branchOverride = if ([string]::IsNullOrWhiteSpace($Branch)) { "" } else { $Branch.Trim() }

    foreach ($entry in $Projects) {
        $csprojPath = Join-Path $RootDir $entry.RelPath
        $repoRoot = Get-GitRepoRoot -StartPath (Split-Path -Parent $csprojPath)
        $targetBranch = if ([string]::IsNullOrWhiteSpace($branchOverride)) { Resolve-DefaultBranchName -Value $entry.DefaultBranch } else { $branchOverride }
        if (-not [string]::IsNullOrWhiteSpace($repoRoot)) {
            if ($seenRepos.Add($repoRoot)) {
                $repoRoots.Add($repoRoot) | Out-Null
                $repoBranches[$repoRoot] = $targetBranch
            } elseif ($repoBranches[$repoRoot] -ne $targetBranch) {
                Write-Host "Warning: conflicting default_branch for $repoRoot ('$($repoBranches[$repoRoot])' vs '$targetBranch'). Using '$($repoBranches[$repoRoot])'."
            }
        }
    }

    foreach ($entry in $Clients) {
        $csprojPath = Join-Path $RootDir $entry.RelPath
        $repoRoot = Get-GitRepoRoot -StartPath (Split-Path -Parent $csprojPath)
        $targetBranch = if ([string]::IsNullOrWhiteSpace($branchOverride)) { Resolve-DefaultBranchName -Value $entry.DefaultBranch } else { $branchOverride }
        if (-not [string]::IsNullOrWhiteSpace($repoRoot)) {
            if ($seenRepos.Add($repoRoot)) {
                $repoRoots.Add($repoRoot) | Out-Null
                $repoBranches[$repoRoot] = $targetBranch
            } elseif ($repoBranches[$repoRoot] -ne $targetBranch) {
                Write-Host "Warning: conflicting default_branch for $repoRoot ('$($repoBranches[$repoRoot])' vs '$targetBranch'). Using '$($repoBranches[$repoRoot])'."
            }
        }
    }

    if ($repoRoots.Count -eq 0) {
        throw "No git repositories were discovered from projects/clients in $StackFile"
    }

    $failures = 0
    $skipped = 0
    foreach ($repoRoot in $repoRoots) {
        $targetBranch = Resolve-DefaultBranchName -Value $repoBranches[$repoRoot]

        $hasLocalBranch = $false
        $hasRemoteBranch = $false
        & git -C $repoRoot rev-parse --verify --quiet ("refs/heads/{0}" -f $targetBranch) 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $hasLocalBranch = $true
        }

        & git -C $repoRoot rev-parse --verify --quiet ("refs/remotes/origin/{0}" -f $targetBranch) 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $hasRemoteBranch = $true
        }

        if (-not $hasLocalBranch -and -not $hasRemoteBranch -and [string]::IsNullOrWhiteSpace($branchOverride)) {
            $originHeadRef = (& git -C $repoRoot symbolic-ref --short refs/remotes/origin/HEAD 2>$null).Trim()
            if (-not [string]::IsNullOrWhiteSpace($originHeadRef) -and $originHeadRef.StartsWith("origin/")) {
                $fallbackBranch = $originHeadRef.Substring("origin/".Length)
                if (-not [string]::IsNullOrWhiteSpace($fallbackBranch)) {
                    Write-Host "Warning: branch '$targetBranch' not found for $repoRoot. Falling back to '$fallbackBranch'."
                    $targetBranch = $fallbackBranch
                }
            }
        }

        $currentBranch = (& git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null).Trim()
        $isDirty = -not [string]::IsNullOrWhiteSpace((& git -C $repoRoot status --porcelain 2>$null))

        if ($isDirty -and -not [string]::IsNullOrWhiteSpace($currentBranch) -and $currentBranch -ne $targetBranch) {
            Write-Host ""
            Write-Host "Syncing $repoRoot (branch $targetBranch)"
            Write-Host "  skipped: working tree has local changes on '$currentBranch'"
            $skipped++
            continue
        }

        Write-Host ""
        Write-Host "Syncing $repoRoot (branch $targetBranch)"

        if ([string]::IsNullOrWhiteSpace($currentBranch) -or $currentBranch -ne $targetBranch) {
            if ($hasLocalBranch) {
                & git -C $repoRoot switch $targetBranch
            } elseif ($hasRemoteBranch) {
                & git -C $repoRoot switch --track ("origin/{0}" -f $targetBranch)
            } else {
                Write-Host "  failed: branch '$targetBranch' was not found locally or on origin"
                $failures++
                continue
            }

            if ($LASTEXITCODE -ne 0) {
                Write-Host "  failed: switch $targetBranch"
                $failures++
                continue
            }
        }

        & git -C $repoRoot pull
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  failed: pull"
            $failures++
            continue
        }

        Write-Host "  ok"
    }

    if ($failures -gt 0) {
        throw "Git sync completed with $failures failure(s)."
    }

    Write-Host ""
    Write-Host "Git sync completed successfully for $($repoRoots.Count - $skipped) repository(s)."
    if ($skipped -gt 0) {
        Write-Host "Skipped $skipped repository(s) due to local changes on a different branch."
    }
}

function Invoke-ExternalCommandChecked {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$ErrorMessage
    )

    if ([string]::IsNullOrWhiteSpace($Executable)) {
        throw "Executable name is required."
    }

    $safeArgs = if ($null -eq $Arguments) { @() } else { $Arguments }
    Write-Host "> $Executable $($safeArgs -join ' ')"

    if ($safeArgs.Count -gt 0) {
        & $Executable @safeArgs
    } else {
        & $Executable
    }

    if ($LASTEXITCODE -ne 0) {
        if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
            throw "$Executable failed with exit code $LASTEXITCODE"
        }

        throw "$ErrorMessage (exit code $LASTEXITCODE)"
    }
}

function Get-CommandOutputLines {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0)
    )

    if ([string]::IsNullOrWhiteSpace($Executable)) {
        throw "Executable name is required."
    }

    $safeArgs = if ($null -eq $Arguments) { @() } else { $Arguments }
    Write-Host "> $Executable $($safeArgs -join ' ')"

    $output = if ($safeArgs.Count -gt 0) {
        & $Executable @safeArgs 2>&1
    } else {
        & $Executable 2>&1
    }

    if ($AllowedExitCodes -notcontains $LASTEXITCODE) {
        $flat = if ($null -eq $output) { "" } else { (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) }
        throw "$Executable failed with exit code $LASTEXITCODE.$([Environment]::NewLine)$flat"
    }

    if ($null -eq $output) {
        return @()
    }

    return @($output | ForEach-Object { [string]$_ })
}

function Ensure-GitHubCliInstalled {
    $ghExists = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)
    if ($ghExists) {
        return
    }

    $wingetExists = $null -ne (Get-Command winget -ErrorAction SilentlyContinue)
    if (-not $wingetExists) {
        throw "GitHub CLI (gh) is not installed and winget was not found on PATH. Install gh manually, then re-run: .\\manage.ps1 git configure"
    }

    Write-Host "GitHub CLI not found. Installing with winget..."
    Invoke-ExternalCommandChecked -Executable "winget" -Arguments @("install", "--id", "GitHub.cli") -ErrorMessage "Failed to install GitHub CLI with winget"

    $ghExistsAfterInstall = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)
    if (-not $ghExistsAfterInstall) {
        throw "GitHub CLI installation completed but 'gh' is still not discoverable in this terminal. Open a new terminal and run .\\manage.ps1 git configure again."
    }
}

function Validate-GitHubAuthStatus {
    $statusLines = Get-CommandOutputLines -Executable "gh" -Arguments @("auth", "status")
    $statusText = ($statusLines -join [Environment]::NewLine)

    $hasLoggedIn = $statusText -match '(?im)^\s*\S*\s*Logged in to github\.com\b'
    $hasActiveAccount = $statusText -match '(?im)^\s*-\s*Active account:\s*true\s*$'

    if (-not $hasLoggedIn -or -not $hasActiveAccount) {
        throw "GitHub authentication validation failed. Expected gh auth status to show 'Logged in' and 'Active account: true'.$([Environment]::NewLine)$statusText"
    }

    Write-Host "GitHub authentication is active for github.com."
}

function Get-NonEmptyTrimmedLines {
    param([string[]]$Lines)

    if ($null -eq $Lines -or $Lines.Count -eq 0) {
        return @()
    }

    $results = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $Lines) {
        $value = [string]$line
        $trimmed = $value.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $results.Add($trimmed) | Out-Null
        }
    }

    return $results.ToArray()
}

function Validate-GitCredentialHelperConfiguration {
    $originLinesRaw = Get-CommandOutputLines -Executable "git" -Arguments @("config", "--show-origin", "--get-all", "credential.helper") -AllowedExitCodes @(0, 1)
    $globalHelperLinesRaw = Get-CommandOutputLines -Executable "git" -Arguments @("config", "--global", "--get-all", "credential.helper") -AllowedExitCodes @(0, 1)
    $githubHostHelperLinesRaw = Get-CommandOutputLines -Executable "git" -Arguments @("config", "--global", "--get-all", "credential.https://github.com.helper") -AllowedExitCodes @(0, 1)

    $originLines = Get-NonEmptyTrimmedLines -Lines $originLinesRaw
    $globalHelperLines = Get-NonEmptyTrimmedLines -Lines $globalHelperLinesRaw
    $githubHostHelperLines = Get-NonEmptyTrimmedLines -Lines $githubHostHelperLinesRaw

    $originHelperValues = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $originLines) {
        $parts = $line -split "`t", 2
        $valuePart = if ($parts.Length -eq 2) { $parts[1] } else { $line }
        $trimmedValue = $valuePart.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmedValue)) {
            $originHelperValues.Add($trimmedValue) | Out-Null
        }
    }

    $distinctOriginHelpers = @($originHelperValues | Sort-Object -Unique)
    if ($distinctOriginHelpers.Count -gt 1) {
        throw "Conflicting credential.helper values detected across git config origins: $($distinctOriginHelpers -join ', ')"
    }

    $distinctGlobalHelpers = @($globalHelperLines | Sort-Object -Unique)
    if ($distinctGlobalHelpers.Count -gt 1) {
        throw "Conflicting global credential.helper values detected: $($distinctGlobalHelpers -join ', ')"
    }

    $expectedHostHelper = "!gh auth git-credential"
    $githubHostNonEmptyValues = @($githubHostHelperLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $distinctHostHelpers = @($githubHostNonEmptyValues | Sort-Object -Unique)
    if ($distinctHostHelpers.Count -ne 1 -or $distinctHostHelpers[0] -ne $expectedHostHelper) {
        $displayValues = if ($distinctHostHelpers.Count -eq 0) { "<none>" } else { $distinctHostHelpers -join ', ' }
        throw "GitHub host credential helper is invalid. Expected '$expectedHostHelper' and found: $displayValues"
    }

    Write-Host "Credential helper validation passed."
}

function Configure-GitHubAuthentication {
    Ensure-GitHubCliInstalled

    Write-Host "Configuring GitHub authentication for git over HTTPS..."

    # Continue when there is no active login to remove.
    & gh auth logout --hostname github.com 2>$null

    Invoke-ExternalCommandChecked -Executable "gh" -Arguments @("auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web") -ErrorMessage "GitHub CLI login failed"
    Invoke-ExternalCommandChecked -Executable "gh" -Arguments @("auth", "setup-git") -ErrorMessage "Failed to configure git credential integration via gh"

    Validate-GitHubAuthStatus
    Validate-GitCredentialHelperConfiguration

    Write-Host "Git configuration completed successfully for github.com."
}

function Show-GitHelp {
    Write-Host "Usage: .\\manage.ps1 git <subcommand> [options]"
    Write-Host ""
    Write-Host "Subcommands:"
    Write-Host "  sync [branch]"
    Write-Host "    Checkout and pull each discovered repository using stack default_branch or provided branch override."
    Write-Host ""
    Write-Host "  configure"
    Write-Host "    Configure GitHub CLI authentication and git credential helper integration."
    Write-Host ""
    Write-Host "  branch [program] new [feature|hotfix] <branchname>"
    Write-Host "    Create a branch from origin/dev and push to origin with upstream configured."
    Write-Host ""
    Write-Host "  branch [program] delete [feature|hotfix] <branchname>"
    Write-Host "    Delete a branch locally and on origin when present."
    Write-Host ""
    Write-Host "  branch [program] list"
    Write-Host "    List local and remote branches for the program's git repository."
    Write-Host ""
    Write-Host "  branch [program] swap <branchname|pick>"
    Write-Host "    Checkout selected branch if it exists locally or on origin (tracks origin when needed)."
    Write-Host "    Use 'pick' to choose from a numbered list of origin branches."
    Write-Host ""
    Write-Host "  branch help"
    Write-Host "    Show detailed help for git branch commands."
}

function Show-GitBranchHelp {
    Write-Host "Usage: .\\manage.ps1 git branch [program] <new|delete|list|swap> [feature|hotfix] <branchname>"
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  [program] new [feature|hotfix] <branchname>"
    Write-Host "    Creates branch from origin/dev and pushes it to origin with upstream tracking."
    Write-Host "    If 'feature' or 'hotfix' is supplied, branch becomes feature/<branchname> or hotfix/<branchname>."
    Write-Host ""
    Write-Host "  [program] delete [feature|hotfix] <branchname>"
    Write-Host "    Deletes branch on origin (if present) and local (if present)."
    Write-Host "    If 'feature' or 'hotfix' is supplied, branch becomes feature/<branchname> or hotfix/<branchname>."
    Write-Host ""
    Write-Host "  [program] list"
    Write-Host "    Lists local and remote branches for the resolved program repository."
    Write-Host ""
    Write-Host "  [program] swap <branchname|pick>"
    Write-Host "    Checks out branch name as provided; creates a local tracking branch from origin if only remote exists."
    Write-Host "    Use 'pick' to interactively select a branch from origin."
    Write-Host ""
    Write-Host "Notes:"
    Write-Host "  - [program] can be omitted; when omitted, the current directory is used to resolve the program from manage.yaml APIs/clients."
    Write-Host "  - [program] must match a program name from manage.yaml APIs or clients when provided."
    Write-Host "  - Branch actions are executed in the program's git repository root."
    Write-Host "  - Base branch for new branches is always origin/dev."
}

function Resolve-ProgramEntryFromCurrentLocationForGitBranch {
    $currentDirectory = [System.IO.Path]::GetFullPath((Get-Location).Path)
    $matchingEntries = New-Object 'System.Collections.Generic.List[object]'

    $allEntries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($project in $Projects) {
        $allEntries.Add([pscustomobject]@{ Name = $project.Name; RelPath = $project.RelPath; Kind = "api" }) | Out-Null
    }

    foreach ($client in $Clients) {
        $allEntries.Add([pscustomobject]@{ Name = $client.Name; RelPath = $client.RelPath; Kind = "client" }) | Out-Null
    }

    foreach ($entry in $allEntries) {
        $entryPath = Join-Path $RootDir $entry.RelPath
        if (-not (Test-Path -LiteralPath $entryPath)) {
            continue
        }

        $entryDirectory = if ($entryPath.EndsWith(".csproj", [System.StringComparison]::OrdinalIgnoreCase)) { Split-Path -Parent $entryPath } else { $entryPath }
        $entryDirectoryFull = [System.IO.Path]::GetFullPath($entryDirectory)

        if ($currentDirectory.StartsWith($entryDirectoryFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            $matchingEntries.Add([pscustomobject]@{ Entry = $entry; MatchLength = $entryDirectoryFull.Length }) | Out-Null
        }
    }

    if ($matchingEntries.Count -gt 0) {
        $bestLength = ($matchingEntries | Measure-Object -Property MatchLength -Maximum).Maximum
        $bestMatches = @($matchingEntries | Where-Object { $_.MatchLength -eq $bestLength })
        if ($bestMatches.Count -eq 1) {
            return $bestMatches[0].Entry
        }

        $bestNames = ($bestMatches | ForEach-Object { $_.Entry.Name }) -join ", "
        throw "Current directory '$currentDirectory' matches multiple programs: $bestNames. Please provide an explicit program name."
    }

    $currentRepoRoot = Get-GitRepoRoot -StartPath $currentDirectory
    if (-not [string]::IsNullOrWhiteSpace($currentRepoRoot)) {
        $repoMatches = New-Object 'System.Collections.Generic.List[object]'
        foreach ($entry in $allEntries) {
            $entryPath = Join-Path $RootDir $entry.RelPath
            if (-not (Test-Path -LiteralPath $entryPath)) {
                continue
            }

            $entryDirectory = if ($entryPath.EndsWith(".csproj", [System.StringComparison]::OrdinalIgnoreCase)) { Split-Path -Parent $entryPath } else { $entryPath }
            $entryRepoRoot = Get-GitRepoRoot -StartPath $entryDirectory
            if (-not [string]::IsNullOrWhiteSpace($entryRepoRoot) -and $entryRepoRoot.Equals($currentRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $repoMatches.Add($entry) | Out-Null
            }
        }

        if ($repoMatches.Count -eq 1) {
            return $repoMatches[0]
        }

        if ($repoMatches.Count -gt 1) {
            $apiRepoMatches = @($repoMatches | Where-Object { $_.Kind -eq "api" })
            if ($apiRepoMatches.Count -eq 1) {
                return $apiRepoMatches[0]
            }

            $repoNames = ($repoMatches | ForEach-Object { $_.Name }) -join ", "
            throw "Current repository '$currentRepoRoot' maps to multiple programs: $repoNames. Please provide an explicit program name."
        }
    }

    throw "Unable to resolve program from current directory '$currentDirectory'. Provide an explicit program name."
}

function Resolve-ProgramEntryForGitBranchOperation {
    param([string]$ProgramName)

    if ([string]::IsNullOrWhiteSpace($ProgramName)) {
        return Resolve-ProgramEntryFromCurrentLocationForGitBranch
    }

    return Resolve-ProgramEntryForGitBranch -ProgramName $ProgramName
}

function Resolve-ProgramEntryForGitBranch {
    param([string]$ProgramName)

    if ([string]::IsNullOrWhiteSpace($ProgramName)) {
        throw "Program name is required."
    }

    $matches = New-Object 'System.Collections.Generic.List[object]'

    foreach ($project in $Projects) {
        if ($project.Name -eq $ProgramName) {
            $matches.Add([pscustomobject]@{ Name = $project.Name; RelPath = $project.RelPath; Kind = "api" }) | Out-Null
        }
    }

    foreach ($client in $Clients) {
        if ($client.Name -eq $ProgramName) {
            $matches.Add([pscustomobject]@{ Name = $client.Name; RelPath = $client.RelPath; Kind = "client" }) | Out-Null
        }
    }

    if ($matches.Count -eq 0) {
        throw "Unknown program '$ProgramName'. Use names from manage.yaml APIs/clients."
    }

    if ($matches.Count -gt 1) {
        throw "Program '$ProgramName' is ambiguous across APIs and clients."
    }

    return $matches[0]
}

function Get-GitRepositoryRootForProgramEntry {
    param([pscustomobject]$Entry)

    $entryPath = Join-Path $RootDir $Entry.RelPath
    if (-not (Test-Path -LiteralPath $entryPath)) {
        throw "Configured path not found for program '$($Entry.Name)': $entryPath"
    }

    $startPath = if ($entryPath.EndsWith(".csproj", [System.StringComparison]::OrdinalIgnoreCase)) { Split-Path -Parent $entryPath } else { $entryPath }
    $repoRoot = Get-GitRepoRoot -StartPath $startPath
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        throw "No git repository found for program '$($Entry.Name)' from path '$startPath'."
    }

    return $repoRoot
}

function Invoke-GitInRepositoryChecked {
    param(
        [string]$RepositoryRoot,
        [string[]]$Arguments,
        [string]$ErrorMessage
    )

    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        throw "Repository root is required."
    }

    if ($null -eq $Arguments -or $Arguments.Count -eq 0) {
        throw "Git arguments are required."
    }

    Write-Host "> git -C $RepositoryRoot $($Arguments -join ' ')"
    & git -C $RepositoryRoot @Arguments
    if ($LASTEXITCODE -ne 0) {
        if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
            throw "git command failed (exit code $LASTEXITCODE): git -C $RepositoryRoot $($Arguments -join ' ')"
        }

        throw "$ErrorMessage (exit code $LASTEXITCODE)"
    }
}

function Get-GitInRepositoryOutput {
    param(
        [string]$RepositoryRoot,
        [string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0)
    )

    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        throw "Repository root is required."
    }

    if ($null -eq $Arguments -or $Arguments.Count -eq 0) {
        throw "Git arguments are required."
    }

    Write-Host "> git -C $RepositoryRoot $($Arguments -join ' ')"
    $output = & git -C $RepositoryRoot @Arguments 2>&1
    if ($AllowedExitCodes -notcontains $LASTEXITCODE) {
        $flat = if ($null -eq $output) { "" } else { (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) }
        throw "git command failed with exit code $LASTEXITCODE.$([Environment]::NewLine)$flat"
    }

    if ($null -eq $output) {
        return @()
    }

    return @($output | ForEach-Object { [string]$_ })
}

function Normalize-FeatureBranchName {
    param([string]$BranchName)

    if ([string]::IsNullOrWhiteSpace($BranchName)) {
        throw "Branch name is required."
    }

    $trimmed = $BranchName.Trim()
    if ($trimmed.StartsWith("feature/", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $trimmed
    }

    return "feature/$trimmed"
}

function Resolve-NewDeleteBranchName {
    param([string[]]$OperationArgs)

    $normalizedArgs = New-Object 'System.Collections.Generic.List[string]'
    if ($null -ne $OperationArgs) {
        foreach ($arg in @($OperationArgs)) {
            $token = [string]$arg
            if (-not [string]::IsNullOrWhiteSpace($token)) {
                $normalizedArgs.Add($token.Trim()) | Out-Null
            }
        }
    }

    $argsArray = $normalizedArgs.ToArray()
    if ($argsArray.Count -eq 0) {
        throw "Branch name is required."
    }

    if ($argsArray.Count -eq 1) {
        $single = [string]$argsArray[0]
        if ($single.ToLowerInvariant() -in @("feature", "hotfix")) {
            throw "Branch name is required after '$single'."
        }

        return $single
    }

    if ($argsArray.Count -eq 2) {
        $kind = ([string]$argsArray[0]).ToLowerInvariant()
        $name = [string]$argsArray[1]
        if ($kind -in @("feature", "hotfix")) {
            if ($name.StartsWith("$kind/", [System.StringComparison]::OrdinalIgnoreCase)) {
                return $name
            }

            return "$kind/$name"
        }
    }

    throw "Invalid branch arguments. Expected: [feature|hotfix] <branchname> or <branchname>."
}

function Invoke-GitBranchNew {
    param(
        [string]$ProgramName,
        [string]$BranchName
    )

    $entry = Resolve-ProgramEntryForGitBranch -ProgramName $ProgramName
    $repoRoot = Get-GitRepositoryRootForProgramEntry -Entry $entry
    $targetBranch = $BranchName

    Write-Host "Creating branch '$targetBranch' for program '$ProgramName' in repo '$repoRoot'..."

    Invoke-GitInRepositoryChecked -RepositoryRoot $repoRoot -Arguments @("fetch", "origin") -ErrorMessage "Failed to fetch origin"

    $originDevCheck = Get-GitInRepositoryOutput -RepositoryRoot $repoRoot -Arguments @("rev-parse", "--verify", "--quiet", "refs/remotes/origin/dev") -AllowedExitCodes @(0, 1)
    if ($LASTEXITCODE -ne 0) {
        throw "Required base branch 'origin/dev' was not found in repository '$repoRoot'."
    }

    $localBranchCheck = Get-GitInRepositoryOutput -RepositoryRoot $repoRoot -Arguments @("rev-parse", "--verify", "--quiet", ("refs/heads/{0}" -f $targetBranch)) -AllowedExitCodes @(0, 1)
    if ($LASTEXITCODE -eq 0) {
        throw "Local branch '$targetBranch' already exists in '$repoRoot'."
    }

    Invoke-GitInRepositoryChecked -RepositoryRoot $repoRoot -Arguments @("checkout", "-b", $targetBranch, "origin/dev") -ErrorMessage "Failed to create branch '$targetBranch' from origin/dev"
    Invoke-GitInRepositoryChecked -RepositoryRoot $repoRoot -Arguments @("push", "-u", "origin", $targetBranch) -ErrorMessage "Failed to push branch '$targetBranch' to origin"

    Write-Host "Branch '$targetBranch' created from origin/dev and pushed to origin with upstream tracking."
}

function Invoke-GitBranchDelete {
    param(
        [string]$ProgramName,
        [string]$BranchName
    )

    $entry = Resolve-ProgramEntryForGitBranch -ProgramName $ProgramName
    $repoRoot = Get-GitRepositoryRootForProgramEntry -Entry $entry
    $targetBranch = $BranchName

    Write-Host "Deleting branch '$targetBranch' for program '$ProgramName' in repo '$repoRoot'..."

    $remoteExistsOutput = Get-GitInRepositoryOutput -RepositoryRoot $repoRoot -Arguments @("ls-remote", "--exit-code", "--heads", "origin", $targetBranch) -AllowedExitCodes @(0, 2)
    if ($LASTEXITCODE -eq 0) {
        Invoke-GitInRepositoryChecked -RepositoryRoot $repoRoot -Arguments @("push", "origin", "--delete", $targetBranch) -ErrorMessage "Failed to delete remote branch '$targetBranch'"
    } else {
        Write-Host "Remote branch '$targetBranch' not found on origin."
    }

    $localExistsOutput = Get-GitInRepositoryOutput -RepositoryRoot $repoRoot -Arguments @("rev-parse", "--verify", "--quiet", ("refs/heads/{0}" -f $targetBranch)) -AllowedExitCodes @(0, 1)
    if ($LASTEXITCODE -eq 0) {
        $currentBranch = ((Get-GitInRepositoryOutput -RepositoryRoot $repoRoot -Arguments @("rev-parse", "--abbrev-ref", "HEAD") -AllowedExitCodes @(0)) -join "").Trim()
        if ($currentBranch -eq $targetBranch) {
            Invoke-GitInRepositoryChecked -RepositoryRoot $repoRoot -Arguments @("checkout", "--detach", "origin/dev") -ErrorMessage "Failed to detach from '$targetBranch' before delete"
        }

        Invoke-GitInRepositoryChecked -RepositoryRoot $repoRoot -Arguments @("branch", "-D", $targetBranch) -ErrorMessage "Failed to delete local branch '$targetBranch'"
    } else {
        Write-Host "Local branch '$targetBranch' not found."
    }

    Write-Host "Delete operation completed for '$targetBranch'."
}

function Invoke-GitBranchList {
    param([string]$ProgramName)

    $entry = Resolve-ProgramEntryForGitBranch -ProgramName $ProgramName
    $repoRoot = Get-GitRepositoryRootForProgramEntry -Entry $entry

    Write-Host "Listing branches for program '$ProgramName' in repo '$repoRoot'..."
    Invoke-GitInRepositoryChecked -RepositoryRoot $repoRoot -Arguments @("fetch", "origin") -ErrorMessage "Failed to fetch origin before branch list"
    $localBranches = Get-GitInRepositoryOutput -RepositoryRoot $repoRoot -Arguments @("branch", "--list") -AllowedExitCodes @(0)
    $remoteBranches = Get-GitInRepositoryOutput -RepositoryRoot $repoRoot -Arguments @("branch", "-r") -AllowedExitCodes @(0)

    Write-Host ""
    Write-Host "Local branches:"
    if ($localBranches.Count -eq 0) {
        Write-Host "  <none>"
    } else {
        foreach ($line in $localBranches) {
            Write-Host "  $line"
        }
    }

    Write-Host ""
    Write-Host "Remote branches:"
    if ($remoteBranches.Count -eq 0) {
        Write-Host "  <none>"
    } else {
        foreach ($line in $remoteBranches) {
            Write-Host "  $line"
        }
    }
}

function Invoke-GitBranchSwap {
    param(
        [string]$ProgramName,
        [string]$BranchName
    )

    $entry = Resolve-ProgramEntryForGitBranch -ProgramName $ProgramName
    $repoRoot = Get-GitRepositoryRootForProgramEntry -Entry $entry
    $requestedBranch = [string]$BranchName
    if ([string]::IsNullOrWhiteSpace($requestedBranch)) {
        throw "Branch name is required for swap."
    }

    $normalizedRequestedBranch = $requestedBranch.Trim()
    if ($normalizedRequestedBranch.StartsWith("origin/", [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalizedRequestedBranch = $normalizedRequestedBranch.Substring("origin/".Length)
    }

    if ([string]::IsNullOrWhiteSpace($normalizedRequestedBranch)) {
        throw "Invalid branch name '$requestedBranch'."
    }

    $branchCandidates = New-Object 'System.Collections.Generic.List[string]'
    $branchCandidates.Add($normalizedRequestedBranch) | Out-Null
    if (-not $normalizedRequestedBranch.Contains("/")) {
        $featureCandidate = "feature/$normalizedRequestedBranch"
        if (-not $featureCandidate.Equals($normalizedRequestedBranch, [System.StringComparison]::OrdinalIgnoreCase)) {
            $branchCandidates.Add($featureCandidate) | Out-Null
        }
    }

    Write-Host "Swapping to branch '$normalizedRequestedBranch' for program '$ProgramName' in repo '$repoRoot'..."
    Invoke-GitInRepositoryChecked -RepositoryRoot $repoRoot -Arguments @("fetch", "origin") -ErrorMessage "Failed to fetch origin before branch swap"

    foreach ($candidate in $branchCandidates) {
        $localExistsOutput = Get-GitInRepositoryOutput -RepositoryRoot $repoRoot -Arguments @("rev-parse", "--verify", "--quiet", ("refs/heads/{0}" -f $candidate)) -AllowedExitCodes @(0, 1)
        if ($LASTEXITCODE -eq 0) {
            Invoke-GitInRepositoryChecked -RepositoryRoot $repoRoot -Arguments @("checkout", $candidate) -ErrorMessage "Failed to checkout local branch '$candidate'"
            return
        }

        $remoteExistsOutput = Get-GitInRepositoryOutput -RepositoryRoot $repoRoot -Arguments @("rev-parse", "--verify", "--quiet", ("refs/remotes/origin/{0}" -f $candidate)) -AllowedExitCodes @(0, 1)
        if ($LASTEXITCODE -eq 0) {
            Invoke-GitInRepositoryChecked -RepositoryRoot $repoRoot -Arguments @("checkout", "-b", $candidate, ("origin/{0}" -f $candidate)) -ErrorMessage "Failed to create local branch '$candidate' from origin"
            Invoke-GitInRepositoryChecked -RepositoryRoot $repoRoot -Arguments @("branch", "--set-upstream-to", ("origin/{0}" -f $candidate), $candidate) -ErrorMessage "Failed to set upstream for '$candidate'"
            return
        }
    }

    $candidateText = $branchCandidates -join ", "
    throw "Branch '$normalizedRequestedBranch' was not found locally or on origin in '$repoRoot'. Tried: $candidateText"
}

function Invoke-GitBranchSwapPick {
    param([string]$ProgramName)

    $entry = Resolve-ProgramEntryForGitBranch -ProgramName $ProgramName
    $repoRoot = Get-GitRepositoryRootForProgramEntry -Entry $entry

    Write-Host "Loading available origin branches for program '$ProgramName' in repo '$repoRoot'..."
    Invoke-GitInRepositoryChecked -RepositoryRoot $repoRoot -Arguments @("fetch", "origin") -ErrorMessage "Failed to fetch origin before branch pick"

    $remoteLines = Get-GitInRepositoryOutput -RepositoryRoot $repoRoot -Arguments @("branch", "-r") -AllowedExitCodes @(0)
    $branchNames = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $remoteLines) {
        $trimmed = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        if ($trimmed.StartsWith("origin/HEAD", [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        if ($trimmed.StartsWith("origin/", [System.StringComparison]::OrdinalIgnoreCase)) {
            $name = $trimmed.Substring("origin/".Length)
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $branchNames.Add($name) | Out-Null
            }
        }
    }

    $distinctBranches = @($branchNames | Sort-Object -Unique)
    if ($distinctBranches.Count -eq 0) {
        throw "No origin branches were found in '$repoRoot'."
    }

    Write-Host ""
    Write-Host "Pick a branch to swap to:"
    for ($i = 0; $i -lt $distinctBranches.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i + 1), $distinctBranches[$i])
    }

    Write-Host ""
    $selectionInput = Read-Host "Enter branch number"
    if ([string]::IsNullOrWhiteSpace($selectionInput)) {
        Write-Host "No selection provided. Swap canceled."
        return
    }

    $selectedIndex = 0
    if (-not [int]::TryParse($selectionInput, [ref]$selectedIndex)) {
        throw "Invalid selection '$selectionInput'. Enter a number from 1 to $($distinctBranches.Count)."
    }

    if ($selectedIndex -lt 1 -or $selectedIndex -gt $distinctBranches.Count) {
        throw "Selection '$selectedIndex' is out of range. Enter a number from 1 to $($distinctBranches.Count)."
    }

    $selectedBranch = [string]$distinctBranches[$selectedIndex - 1]
    Invoke-GitBranchSwap -ProgramName $ProgramName -BranchName $selectedBranch
}

function Invoke-GitBranchCommand {
    param([string[]]$RawArgs)

    $argsListBuffer = New-Object 'System.Collections.Generic.List[string]'
    if ($null -ne $RawArgs) {
        foreach ($raw in @($RawArgs)) {
            $token = [string]$raw
            if (-not [string]::IsNullOrWhiteSpace($token)) {
                $argsListBuffer.Add($token) | Out-Null
            }
        }
    }

    $argsList = $argsListBuffer.ToArray()
    if ($argsList.Count -eq 0 -or $argsList[0].ToLowerInvariant() -eq "help") {
        Show-GitBranchHelp
        return
    }

    $operations = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    [void]$operations.Add("new")
    [void]$operations.Add("delete")
    [void]$operations.Add("list")
    [void]$operations.Add("swap")
    [void]$operations.Add("help")

    $programName = ""
    $operation = ""
    $branchName = ""
    $operationArgs = @()
    $operationArgStartIndex = 0

    if ($operations.Contains([string]$argsList[0])) {
        $operation = [string]$argsList[0]
        $operationArgStartIndex = 1
    } else {
        if ($argsList.Count -lt 2) {
            throw "Usage: .\\manage.ps1 git branch [program] <new|delete|list|swap> [branchname]"
        }

        $programName = [string]$argsList[0]
        $operation = [string]$argsList[1]
        $operationArgStartIndex = 2
    }

    if ($argsList.Count -gt $operationArgStartIndex) {
        $operationArgs = @($argsList[$operationArgStartIndex..($argsList.Count - 1)])
    }

    if ($operation.ToLowerInvariant() -eq "help") {
        Show-GitBranchHelp
        return
    }

    $resolvedEntry = Resolve-ProgramEntryForGitBranchOperation -ProgramName $programName
    $resolvedProgramName = [string]$resolvedEntry.Name

    switch ($operation.ToLowerInvariant()) {
        "new" {
            if ($operationArgs.Count -eq 0) {
                throw "Usage: .\\manage.ps1 git branch [program] new [feature|hotfix] <branchname>"
            }

            $branchName = Resolve-NewDeleteBranchName -OperationArgs $operationArgs

            Invoke-GitBranchNew -ProgramName $resolvedProgramName -BranchName $branchName
        }
        "delete" {
            if ($operationArgs.Count -eq 0) {
                throw "Usage: .\\manage.ps1 git branch [program] delete [feature|hotfix] <branchname>"
            }

            $branchName = Resolve-NewDeleteBranchName -OperationArgs $operationArgs

            Invoke-GitBranchDelete -ProgramName $resolvedProgramName -BranchName $branchName
        }
        "list" {
            Invoke-GitBranchList -ProgramName $resolvedProgramName
        }
        "swap" {
            if ($operationArgs.Count -eq 0) {
                throw "Usage: .\\manage.ps1 git branch [program] swap <branchname|pick>"
            }

            $branchName = [string]$operationArgs[0]
            if ($branchName.ToLowerInvariant() -eq "pick") {
                Invoke-GitBranchSwapPick -ProgramName $resolvedProgramName
                break
            }

            Invoke-GitBranchSwap -ProgramName $resolvedProgramName -BranchName $branchName
        }
        default {
            throw "Unknown git branch action '$operation'. Expected: new, delete, list, swap, help"
        }
    }
}

function Get-ShorthandOptions {
    param(
        [string]$TargetValue,
        [string[]]$RawArgs
    )

    $tokens = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($TargetValue) -and $TargetValue -ne "all") {
        $tokens.Add([string]$TargetValue) | Out-Null
    }

    if ($null -ne $RawArgs) {
        foreach ($arg in $RawArgs) {
            if (-not [string]::IsNullOrWhiteSpace([string]$arg)) {
                $tokens.Add([string]$arg) | Out-Null
            }
        }
    }

    $aliasName = "manage"
    $persist = $false
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = [string]$tokens[$i]
        if ($token -eq "--alias") {
            if (($i + 1) -ge $tokens.Count) {
                throw "Missing value for --alias. Usage: .\\manage.ps1 shorthand [--alias <name>] [--persist]"
            }

            $aliasName = [string]$tokens[$i + 1]
            $i++
            continue
        }

        if ($token -eq "--persist") {
            $persist = $true
            continue
        }

        throw "Unknown shorthand option: $token. Usage: .\\manage.ps1 shorthand [--alias <name>] [--persist]"
    }

    if ([string]::IsNullOrWhiteSpace($aliasName)) {
        throw "Alias name cannot be empty."
    }

    if ($aliasName -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$') {
        throw "Invalid alias name '$aliasName'. Use letters, numbers, underscore, or dash; and start with a letter or underscore."
    }

    return [pscustomobject]@{
        AliasName = $aliasName
        Persist = $persist
    }
}

function Configure-ManageShorthand {
    param(
        [string]$AliasName = "manage",
        [bool]$Persist = $false
    )

    $scriptPath = [System.IO.Path]::GetFullPath((Join-Path $RootDir "manage.ps1"))
    $escapedScriptPath = $scriptPath.Replace("'", "''")
    $startMarker = "# >>> manage shorthand >>>"
    $endMarker = "# <<< manage shorthand <<<"

    $functionTemplate = @'
# >>> manage shorthand >>>
function {ALIAS_NAME} {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$ManageArgs
    )

    & '{SCRIPT_PATH}' @ManageArgs
}
# <<< manage shorthand <<<
'@
    $functionBlock = $functionTemplate.Replace("{SCRIPT_PATH}", $escapedScriptPath).Replace("{ALIAS_NAME}", $AliasName)

    if ($Persist) {
        $profilePath = $PROFILE
        if ([string]::IsNullOrWhiteSpace($profilePath)) {
            throw "Unable to resolve PowerShell profile path."
        }

        $profileDirectory = Split-Path -Parent $profilePath
        if (-not [string]::IsNullOrWhiteSpace($profileDirectory) -and -not (Test-Path -LiteralPath $profileDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
        }

        if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
            New-Item -ItemType File -Path $profilePath -Force | Out-Null
        }

        $existingContent = Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue
        if ($null -eq $existingContent) {
            $existingContent = ""
        }

        $replacementPattern = "(?s)" + [regex]::Escape($startMarker) + ".*" + [regex]::Escape($endMarker)
        $updatedContent = ""
        if ($existingContent -match $replacementPattern) {
            $updatedContent = [regex]::Replace($existingContent, $replacementPattern, $functionBlock)
        } else {
            $separator = if ([string]::IsNullOrWhiteSpace($existingContent)) { "" } else { [Environment]::NewLine + [Environment]::NewLine }
            $updatedContent = $existingContent + $separator + $functionBlock
        }

        Set-Content -LiteralPath $profilePath -Value $updatedContent -Encoding UTF8 -NoNewline
        Write-Host "Shorthand configured in profile: $profilePath"
    }

    $runtimeScriptPath = $scriptPath
    $runtimeAlias = $AliasName
    $aliasScriptBlock = {
        param(
            [Parameter(ValueFromRemainingArguments = $true)]
            [string[]]$ManageArgs
        )

        & $runtimeScriptPath @ManageArgs
    }.GetNewClosure()
    Set-Item -Path ("Function:\global:{0}" -f $runtimeAlias) -Value $aliasScriptBlock

    Write-Host "Alias '$AliasName' is active in this session."
    if ($Persist) {
        Write-Host "Alias '$AliasName' will also be available in future PowerShell sessions."
    } else {
        Write-Host "Use --persist to make this alias available in future PowerShell sessions."
    }
    Write-Host "Then use: $AliasName <command>"
}

function Invoke-DotnetCommandChecked {
    param(
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    if ($null -eq $Arguments -or $Arguments.Count -eq 0) {
        throw "Invoke-DotnetCommandChecked requires at least one argument."
    }

    Write-Host "> $DotnetCmd $($Arguments -join ' ')"

    $hasWorkingDirectory = -not [string]::IsNullOrWhiteSpace($WorkingDirectory)
    if ($hasWorkingDirectory) {
        Push-Location -LiteralPath $WorkingDirectory
    }

    try {
        & $DotnetCmd @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet command failed (exit code $LASTEXITCODE): $DotnetCmd $($Arguments -join ' ')"
        }
    } finally {
        if ($hasWorkingDirectory) {
            Pop-Location
        }
    }
}

function Add-StandardCsprojPropertyGroups {
    param(
        [string]$CsprojPath,
        [string]$ProjectName,
        [bool]$IsClientProject
    )

    if (-not (Test-Path -LiteralPath $CsprojPath)) {
        throw "Project file not found: $CsprojPath"
    }

    $content = Get-Content -LiteralPath $CsprojPath -Raw
    if ($content -match '<!--\s*\*\*\*AUTO-GENERATED\*\*\*\s*-->') {
        return
    }

    $clientConfig = ""
    if ($IsClientProject) {
        $packageId = "$ProjectName.Client"
        $description = "Typed HTTP Client for $ProjectName API. Provides easy integration for microservices to interact with the $ProjectName API."
        $clientConfig = @"

  <PropertyGroup>
    <!-- NuGet Package Configuration -->
    <GeneratePackageOnBuild>true</GeneratePackageOnBuild>
    <PackageId>$packageId</PackageId>
    <Version>1.0.0</Version>
    <Description>$description</Description>
    <PackageReadmeFile>README.md</PackageReadmeFile>
    <RepositoryType>git</RepositoryType>
  </PropertyGroup>
"@
    }

    $groups = @'

  <!-- ***AUTO-GENERATED*** -->

  <PropertyGroup>
    <ParallelBuild>True</ParallelBuild>
    <RunAnalyzers>True</RunAnalyzers>
    <TreatWarningsAsErrors>True</TreatWarningsAsErrors>
  </PropertyGroup>

  <PropertyGroup Condition="'$(Configuration)' == 'Debug'">
    <DebugSymbols>true</DebugSymbols>
    <DefineDebug>true</DefineDebug>
    <Optimization>false</Optimization>
    <Obfuscate>false</Obfuscate>
  </PropertyGroup>

  <PropertyGroup Condition="'$(Configuration)' == 'Release'">
    <DebugSymbols>false</DebugSymbols>
    <DefineDebug>false</DefineDebug>
    <Optimization>true</Optimization>
    <Obfuscate>true</Obfuscate>
  </PropertyGroup>
'@

    $allGenerated = $groups + $clientConfig
    $updated = $content -replace '</Project>', "$allGenerated`r`n</Project>"
    if ($updated -eq $content) {
        throw "Unable to update project file: $CsprojPath"
    }

    Set-Content -LiteralPath $CsprojPath -Value $updated -Encoding UTF8 -NoNewline
}

function Get-ProgramSuffix {
    param([string]$ProjectName)

    $parts = @($ProjectName.Split('.') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts.Count -eq 0) {
        return $ProjectName
    }

    return $parts[$parts.Count - 1]
}

function Write-BasicClassFile {
    param(
        [string]$FilePath,
        [string]$Namespace,
        [string]$ClassName,
        [bool]$IsStatic = $false
    )

    $modifier = if ($IsStatic) { "static " } else { "" }
    $content = @"
namespace $Namespace;

public ${modifier}class $ClassName
{
}
"@

    Set-Content -LiteralPath $FilePath -Value $content -Encoding UTF8
}

function Remove-DefaultScaffoldFiles {
    param(
        [string]$ScaffoldRootPath,
        [string[]]$ProjectFolders
    )

    $defaultFiles = @("Class1.cs", "UnitTest1.cs", "UnitTests1.cs")

    foreach ($folder in $ProjectFolders) {
        $projectDir = Join-Path $ScaffoldRootPath $folder
        foreach ($fileName in $defaultFiles) {
            $candidate = Join-Path $projectDir $fileName
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Create-ApiDataScaffoldingFiles {
    param(
        [string]$ProjectName,
        [string]$ScaffoldRootPath
    )

    $suffix = Get-ProgramSuffix -ProjectName $ProjectName
    $dataProject = "$ProjectName.API.Data"
    $registrationDir = Join-Path (Join-Path $ScaffoldRootPath $dataProject) "Registration"
    New-Item -ItemType Directory -Path $registrationDir -Force | Out-Null

    Write-BasicClassFile -FilePath (Join-Path $registrationDir ("$($suffix)DbContext.cs")) -Namespace "$dataProject.Registration" -ClassName "$($suffix)DbContext"
    Write-BasicClassFile -FilePath (Join-Path $registrationDir ("$($suffix)DataServiceExtension.cs")) -Namespace "$dataProject.Registration" -ClassName "$($suffix)DataServiceExtension" -IsStatic:$true
    Write-BasicClassFile -FilePath (Join-Path $registrationDir ("$($suffix)DataOptions.cs")) -Namespace "$dataProject.Registration" -ClassName "$($suffix)DataOptions"
    Write-BasicClassFile -FilePath (Join-Path $registrationDir "ServiceCollectionExtension.cs") -Namespace "$dataProject.Registration" -ClassName "ServiceCollectionExtension" -IsStatic:$true
}

function Create-ApiScaffoldingFiles {
    param(
        [string]$ProjectName,
        [string]$ScaffoldRootPath
    )

    $suffix = Get-ProgramSuffix -ProjectName $ProjectName
    $apiProject = "$ProjectName.API"
    $registrationDir = Join-Path (Join-Path $ScaffoldRootPath $apiProject) "Registration"
    $endpointDir = Join-Path (Join-Path $ScaffoldRootPath $apiProject) "FirstEndpoint"
    New-Item -ItemType Directory -Path $registrationDir -Force | Out-Null
    New-Item -ItemType Directory -Path $endpointDir -Force | Out-Null

    Write-BasicClassFile -FilePath (Join-Path $registrationDir ("$($suffix)Registration.cs")) -Namespace "$apiProject.Registration" -ClassName "$($suffix)Registration"
    Write-BasicClassFile -FilePath (Join-Path $endpointDir "FirstEndpoint.cs") -Namespace "$apiProject.FirstEndpoint" -ClassName "FirstEndpoint"
}

function Create-ClientScaffoldingFiles {
    param(
        [string]$ProjectName,
        [string]$ScaffoldRootPath
    )

    $suffix = Get-ProgramSuffix -ProjectName $ProjectName
    $clientProject = "$ProjectName.Client"
    $registeredDir = Join-Path (Join-Path $ScaffoldRootPath $clientProject) "Registered"
    New-Item -ItemType Directory -Path $registeredDir -Force | Out-Null

    Write-BasicClassFile -FilePath (Join-Path $registeredDir ("$($suffix)ClientRegistration.cs")) -Namespace "$clientProject.Registered" -ClassName "$($suffix)ClientRegistration" -IsStatic:$true
    Write-BasicClassFile -FilePath (Join-Path $registeredDir ("$($suffix)Options.cs")) -Namespace "$clientProject.Registered" -ClassName "$($suffix)Options"
}

function Resolve-InstructionsPath {
    param([string]$PathValue)

    $resolved = ""
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        $resolved = Join-Path (Get-Location).Path "copilot-instructions.md"
    } elseif ([System.IO.Path]::IsPathRooted($PathValue)) {
        $resolved = [System.IO.Path]::GetFullPath($PathValue)
    } else {
        $resolved = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $PathValue))
    }

    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Instructions file not found: $resolved"
    }

    return $resolved
}

function Resolve-DirectoryPathFromOption {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        throw "Missing required path value."
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $PathValue))
}

function Resolve-RegisteredProjectRootByName {
    param([string]$ProjectName)

    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        throw "Project name is required."
    }

    $matches = New-Object 'System.Collections.Generic.List[string]'

    foreach ($project in $Projects) {
        if ($project.Name -eq $ProjectName) {
            $fullPath = Join-Path $RootDir $project.RelPath
            $projectRoot = if ($fullPath.EndsWith(".csproj", [System.StringComparison]::OrdinalIgnoreCase)) { Split-Path -Parent $fullPath } else { $fullPath }
            $matches.Add([System.IO.Path]::GetFullPath($projectRoot)) | Out-Null
        }
    }

    foreach ($client in $Clients) {
        if ($client.Name -eq $ProjectName) {
            $fullPath = Join-Path $RootDir $client.RelPath
            $projectRoot = if ($fullPath.EndsWith(".csproj", [System.StringComparison]::OrdinalIgnoreCase)) { Split-Path -Parent $fullPath } else { $fullPath }
            $matches.Add([System.IO.Path]::GetFullPath($projectRoot)) | Out-Null
        }
    }

    if ($matches.Count -eq 0) {
        throw "Unknown registered project/client name: $ProjectName"
    }

    if ($matches.Count -gt 1) {
        throw "Project name '$ProjectName' is ambiguous across APIs and clients."
    }

    return $matches[0]
}

function Get-AddInstructionsOptions {
    param([string[]]$RawArgs)

    $projectName = ""
    $pathToInstructions = ""

    for ($i = 0; $i -lt $RawArgs.Count; $i++) {
        $token = [string]$RawArgs[$i]
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }

        if ($token -eq "--project-name") {
            if (($i + 1) -ge $RawArgs.Count) {
                throw "Missing value for --project-name"
            }

            $i++
            $projectName = [string]$RawArgs[$i]
            continue
        }

        if ($token -eq "--path-to-instructions") {
            if (($i + 1) -ge $RawArgs.Count) {
                throw "Missing value for --path-to-instructions"
            }

            $i++
            $pathToInstructions = [string]$RawArgs[$i]
            continue
        }

        throw "Unknown option: $token"
    }

    if ([string]::IsNullOrWhiteSpace($projectName)) {
        throw "--project-name is required"
    }

    [pscustomobject]@{
        InstructionsPath = Resolve-InstructionsPath -PathValue $pathToInstructions
        TargetPath = Resolve-RegisteredProjectRootByName -ProjectName $projectName
    }
}

function Get-UpdateInstructionsOptions {
    param([string[]]$RawArgs)

    $pathToInstructions = ""
    $pathToUpdate = ""
    for ($i = 0; $i -lt $RawArgs.Count; $i++) {
        $token = [string]$RawArgs[$i]
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }

        if ($token -eq "--path-to-instructions") {
            if (($i + 1) -ge $RawArgs.Count) {
                throw "Missing value for --path-to-instructions"
            }

            $i++
            $pathToInstructions = [string]$RawArgs[$i]
            continue
        }

        if ($token -eq "--path-to-update") {
            if (($i + 1) -ge $RawArgs.Count) {
                throw "Missing value for --path-to-update"
            }

            $i++
            $pathToUpdate = [string]$RawArgs[$i]
            continue
        }

        throw "Unknown option: $token"
    }

    [pscustomobject]@{
        InstructionsPath = Resolve-InstructionsPath -PathValue $pathToInstructions
        PathToUpdate = if ([string]::IsNullOrWhiteSpace($pathToUpdate)) { "" } else { Resolve-DirectoryPathFromOption -PathValue $pathToUpdate }
    }
}

function Get-StartOptions {
    param([string[]]$RawArgs)

    $launch = $false
    $clean = $false
    $restore = $false
    for ($i = 0; $i -lt $RawArgs.Count; $i++) {
        $token = [string]$RawArgs[$i]
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }

        if ($token -eq "--launch") {
            $launch = $true
            continue
        }

        if ($token -eq "--clean") {
            $clean = $true
            continue
        }

        if ($token -eq "--restore") {
            $restore = $true
            continue
        }

        throw "Unknown option: $token"
    }

    [pscustomobject]@{
        Launch = $launch
        Clean = $clean
        Restore = $restore
    }
}

function Copy-InstructionsToProject {
    param(
        [string]$InstructionsPath,
        [string]$ProjectRootPath
    )

    if (-not (Test-Path -LiteralPath $ProjectRootPath -PathType Container)) {
        throw "Target project directory not found: $ProjectRootPath"
    }

    $githubDir = Join-Path $ProjectRootPath ".github"
    if (-not (Test-Path -LiteralPath $githubDir)) {
        New-Item -ItemType Directory -Path $githubDir | Out-Null
    }

    $targetFile = Join-Path $githubDir "copilot-instructions.md"
    Copy-Item -LiteralPath $InstructionsPath -Destination $targetFile -Force
    Write-Host "Updated instructions: $targetFile"
}

function Add-InstructionsCommand {
    param([string[]]$RawArgs)

    $options = Get-AddInstructionsOptions -RawArgs $RawArgs
    Copy-InstructionsToProject -InstructionsPath $options.InstructionsPath -ProjectRootPath $options.TargetPath
}

function Update-InstructionsCommand {
    param([string[]]$RawArgs)

    $options = Get-UpdateInstructionsOptions -RawArgs $RawArgs
    $registeredRoots = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($project in $Projects) {
        $fullPath = Join-Path $RootDir $project.RelPath
        $projectRoot = if ($fullPath.EndsWith(".csproj", [System.StringComparison]::OrdinalIgnoreCase)) { Split-Path -Parent $fullPath } elseif (Test-Path -LiteralPath $fullPath -PathType Leaf) { Split-Path -Parent $fullPath } else { $fullPath }
        if (-not [string]::IsNullOrWhiteSpace($projectRoot)) {
            [void]$registeredRoots.Add([System.IO.Path]::GetFullPath($projectRoot))
        }
    }

    foreach ($client in $Clients) {
        $fullPath = Join-Path $RootDir $client.RelPath
        $projectRoot = if ($fullPath.EndsWith(".csproj", [System.StringComparison]::OrdinalIgnoreCase)) { Split-Path -Parent $fullPath } elseif (Test-Path -LiteralPath $fullPath -PathType Leaf) { Split-Path -Parent $fullPath } else { $fullPath }
        if (-not [string]::IsNullOrWhiteSpace($projectRoot)) {
            [void]$registeredRoots.Add([System.IO.Path]::GetFullPath($projectRoot))
        }
    }

    if ($registeredRoots.Count -eq 0) {
        throw "No registered APIs or clients were found in stack file: $StackFile"
    }

    if (-not [string]::IsNullOrWhiteSpace($options.PathToUpdate)) {
        $targetRoot = [System.IO.Path]::GetFullPath($options.PathToUpdate)
        if (-not $registeredRoots.Contains($targetRoot)) {
            throw "Target path is not a registered API/client directory: $targetRoot"
        }

        if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
            Write-Host "WARNING: Skipping missing project directory '$targetRoot'" -ForegroundColor Red
            return
        }

        Copy-InstructionsToProject -InstructionsPath $options.InstructionsPath -ProjectRootPath $targetRoot
        return
    }

    foreach ($root in $registeredRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            Write-Host "WARNING: Skipping missing project directory '$root'" -ForegroundColor Red
            continue
        }

        Copy-InstructionsToProject -InstructionsPath $options.InstructionsPath -ProjectRootPath $root
    }
}

function Get-RunTestsOptions {
    param([string[]]$RawArgs)

    $projectName = ""
    $restore = $false
    for ($i = 0; $i -lt $RawArgs.Count; $i++) {
        $token = [string]$RawArgs[$i]
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }

        if ($token -eq "--project-name") {
            if (($i + 1) -ge $RawArgs.Count) {
                throw "Missing value for --project-name"
            }

            $i++
            $projectName = [string]$RawArgs[$i]
            continue
        }

        if ($token -eq "--restore") {
            $restore = $true
            continue
        }

        throw "Unknown option: $token"
    }

    [pscustomobject]@{
        ProjectName = $projectName
        Restore = $restore
    }
}

function Get-RegisteredEntriesForTestRun {
    param([string]$ProjectName)

    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($project in $Projects) {
        if ([string]::IsNullOrWhiteSpace($ProjectName) -or $project.Name -eq $ProjectName) {
            $entries.Add([pscustomobject]@{ Name = $project.Name; RelPath = $project.RelPath; Type = "api" }) | Out-Null
        }
    }

    foreach ($client in $Clients) {
        if ([string]::IsNullOrWhiteSpace($ProjectName) -or $client.Name -eq $ProjectName) {
            $entries.Add([pscustomobject]@{ Name = $client.Name; RelPath = $client.RelPath; Type = "client" }) | Out-Null
        }
    }

    if ($entries.Count -eq 0) {
        if ([string]::IsNullOrWhiteSpace($ProjectName)) {
            throw "No registered APIs/clients were found in stack file: $StackFile"
        }

        throw "Unknown registered project/client name: $ProjectName"
    }

    return $entries.ToArray()
}

function Get-TestProjectPathsForEntry {
    param([pscustomobject]$Entry)

    $entryPath = Join-Path $RootDir $Entry.RelPath
    $entryProjectDir = if ($entryPath.EndsWith(".csproj", [System.StringComparison]::OrdinalIgnoreCase)) { Split-Path -Parent $entryPath } else { $entryPath }
    $entryProjectDir = [System.IO.Path]::GetFullPath($entryProjectDir)
    $solutionRoot = Split-Path -Parent $entryProjectDir

    if ([string]::IsNullOrWhiteSpace($solutionRoot) -or -not (Test-Path -LiteralPath $solutionRoot -PathType Container)) {
        Write-Host "WARNING: Skipping missing project directory '$solutionRoot'" -ForegroundColor Red
        return @()
    }

    $familyPrefix = [System.IO.Path]::GetFileNameWithoutExtension($Entry.RelPath)
    if ($familyPrefix.EndsWith(".API", [System.StringComparison]::OrdinalIgnoreCase)) {
        $familyPrefix = $familyPrefix.Substring(0, $familyPrefix.Length - 4)
    } elseif ($familyPrefix.EndsWith(".Client", [System.StringComparison]::OrdinalIgnoreCase)) {
        $familyPrefix = $familyPrefix.Substring(0, $familyPrefix.Length - 7)
    }

    $tests = Get-ChildItem -LiteralPath $solutionRoot -Recurse -Filter *.csproj -File | Where-Object {
        ($_.Name -like "$familyPrefix*.Test.csproj" -or $_.Name -like "$familyPrefix*.Tests.csproj") -and
        ($_.FullName -notmatch "[\\/](bin|obj)[\\/]")
    } | Sort-Object FullName

    return @($tests | ForEach-Object { $_.FullName })
}

function Parse-TestOutputSummary {
    param([string[]]$OutputLines)

    $summary = [pscustomobject]@{ Passed = 0; Failed = 0; Skipped = 0; Total = 0 }
    if ($null -eq $OutputLines -or $OutputLines.Count -eq 0) {
        return $summary
    }

    $flat = ($OutputLines -join [Environment]::NewLine)
    $m = [regex]::Match($flat, 'Failed:\s*(\d+),\s*Passed:\s*(\d+),\s*Skipped:\s*(\d+),\s*Total:\s*(\d+)')
    if ($m.Success) {
        $summary.Failed = [int]$m.Groups[1].Value
        $summary.Passed = [int]$m.Groups[2].Value
        $summary.Skipped = [int]$m.Groups[3].Value
        $summary.Total = [int]$m.Groups[4].Value
        return $summary
    }

    $totalMatch = [regex]::Match($flat, '(?m)^\s*Total tests:\s*(\d+)\s*$')
    $passedMatch = [regex]::Match($flat, '(?m)^\s*Passed:\s*(\d+)\s*$')
    $failedMatch = [regex]::Match($flat, '(?m)^\s*Failed:\s*(\d+)\s*$')
    $skippedMatch = [regex]::Match($flat, '(?m)^\s*Skipped:\s*(\d+)\s*$')

    if ($totalMatch.Success) {
        $summary.Total = [int]$totalMatch.Groups[1].Value
    }
    if ($passedMatch.Success) {
        $summary.Passed = [int]$passedMatch.Groups[1].Value
    }
    if ($failedMatch.Success) {
        $summary.Failed = [int]$failedMatch.Groups[1].Value
    }
    if ($skippedMatch.Success) {
        $summary.Skipped = [int]$skippedMatch.Groups[1].Value
    }

    return $summary
}

function Write-RunningTestsProgressLine {
    param(
        [string]$TestProjectName,
        [int]$CompletedTests,
        [int]$TotalTests,
        [double]$ElapsedSeconds
    )

    $barWidth = 20
    $safeCompleted = [Math]::Max($CompletedTests, 0)
    $hasKnownTotal = ($TotalTests -gt 0)
    if ($hasKnownTotal) {
        $safeCompleted = [Math]::Min($safeCompleted, $TotalTests)
    }

    if ($hasKnownTotal) {
        $percent = [int][Math]::Floor(($safeCompleted * 100.0) / $TotalTests)
        $filled = [int][Math]::Round(($percent / 100.0) * $barWidth)
    } else {
        $percent = -1
        $filled = [Math]::Min($barWidth, $safeCompleted)
    }

    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $barWidth) { $filled = $barWidth }
    $bar = ("#" * $filled) + ("-" * ($barWidth - $filled))
    $displayTotal = if ($hasKnownTotal) { [string]$TotalTests } else { "?" }
    $elapsed = if ($ElapsedSeconds -lt 0) { 0.0 } else { $ElapsedSeconds }
    $percentText = if ($hasKnownTotal) { ("{0,3}%" -f $percent) } else { "  ?%" }
    $progressText = ("[{0}] {1} ({2}/{3}) {4:N2}s" -f $bar, $percentText, $safeCompleted, $displayTotal, $elapsed)

    $prefix = "Running tests: $TestProjectName"
    $windowWidth = 120
    try {
        if ($Host -and $Host.UI -and $Host.UI.RawUI -and $Host.UI.RawUI.WindowSize.Width -gt 0) {
            $windowWidth = $Host.UI.RawUI.WindowSize.Width
        }
    } catch {
    }

    $minSpacer = 2
    $paddingCount = $windowWidth - $prefix.Length - $progressText.Length
    if ($paddingCount -lt $minSpacer) {
        $paddingCount = $minSpacer
    }

    return ($prefix + (" " * $paddingCount) + $progressText)
}

function Write-ProgressLineAtRow {
    param(
        [int]$Row,
        [string]$Text
    )

    $windowWidth = 120
    try {
        if ($Host -and $Host.UI -and $Host.UI.RawUI -and $Host.UI.RawUI.WindowSize.Width -gt 0) {
            $windowWidth = $Host.UI.RawUI.WindowSize.Width
        }
    } catch {
    }

    $safeText = if ($Text.Length -gt $windowWidth) { $Text.Substring(0, $windowWidth) } else { $Text }
    $lineText = $safeText.PadRight($windowWidth)

    try {
        $currentPos = $Host.UI.RawUI.CursorPosition
        $target = New-Object System.Management.Automation.Host.Coordinates 0, $Row
        $Host.UI.RawUI.CursorPosition = $target

        # Explicitly clear the whole line, then write the updated progress text.
        Write-Host -NoNewline (" " * $windowWidth)
        $Host.UI.RawUI.CursorPosition = $target
        Write-Host -NoNewline $safeText

        $Host.UI.RawUI.CursorPosition = $currentPos
        return $true
    } catch {
        return $false
    }
}

function Get-TestCountForProject {
    param([string]$ProjectPath)

    try {
        $listOutput = (& $DotnetCmd test $ProjectPath --list-tests --nologo 2>&1)
        if ($LASTEXITCODE -ne 0 -or $null -eq $listOutput) {
            return 0
        }

        return Get-TestCountFromListOutput -OutputLines @($listOutput)
    } catch {
        return 0
    }
}

function Get-TestCountFromListOutput {
    param([string[]]$OutputLines)

    if ($null -eq $OutputLines -or $OutputLines.Count -eq 0) {
        return 0
    }

    $inList = $false
    $count = 0
    foreach ($line in $OutputLines) {
        $text = [string]$line
        if (-not $inList) {
            if ($text -match 'The following Tests are available:') {
                $inList = $true
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        if ($text -match '^\s{2,}\S') {
            $count++
        }
    }

    return $count
}

function Get-CompletedTestsCountFromLog {
    param([string]$LogPath)

    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        return 0
    }

    try {
        $text = Get-Content -LiteralPath $LogPath -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($text)) {
            return 0
        }

        $matches = [regex]::Matches($text, '(?m)^\s*(Passed|Failed|Skipped)\s+\S')
        return $matches.Count
    } catch {
        return 0
    }
}

function Get-CoveragePercentFromResults {
    param([string]$ResultsDir)

    if (-not (Test-Path -LiteralPath $ResultsDir -PathType Container)) {
        return "N/A"
    }

    $coverageFile = Get-ChildItem -LiteralPath $ResultsDir -Recurse -Filter coverage.cobertura.xml -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $coverageFile) {
        return "N/A"
    }

    try {
        $xml = [xml](Get-Content -LiteralPath $coverageFile.FullName -Raw)
        $lineRateText = [string]$xml.coverage.'line-rate'
        $lineRate = 0.0
        if ([double]::TryParse($lineRateText, [ref]$lineRate)) {
            return ("{0:N2}%" -f ($lineRate * 100.0))
        }
    } catch {
    }

    return "N/A"
}

function Test-TestOutputHasErrors {
    param([string[]]$OutputLines)

    if ($null -eq $OutputLines -or $OutputLines.Count -eq 0) {
        return $false
    }

    foreach ($line in $OutputLines) {
        $text = [string]$line
        if ($text -match '(?i)\berror\s+[A-Z]{2}[0-9]{4}\b') {
            return $true
        }

        if ($text -match '(?i)^\s*Build\s+FAILED\.?\s*$') {
            return $true
        }
    }

    return $false
}

function Get-CoverageForegroundColor {
    param([string]$CoverageText)

    if ($CoverageText -match '^([0-9]+(?:\.[0-9]+)?)%$') {
        $value = 0.0
        if ([double]::TryParse($Matches[1], [ref]$value)) {
            if ($value -lt 80.0) {
                return "Red"
            }

            if ($value -lt 90.0) {
                return "Yellow"
            }

            return "Green"
        }
    }

    return "Gray"
}

function Get-LoadBearingThroughputSummary {
    param([string[]]$OutputLines)

    if ($null -eq $OutputLines -or $OutputLines.Count -eq 0) {
        return $null
    }

    $inSustainedSection = $false
    $perSecondReq = New-Object 'System.Collections.Generic.List[double]'
    $lastThreeAverage = $null

    foreach ($line in $OutputLines) {
        $text = [string]$line
        if (-not $inSustainedSection) {
            if ($text -match '^\s*===\s*Sustained Load Test') {
                $inSustainedSection = $true
            }
            continue
        }

        if ($text -match '^\s*===\s*' -and $text -notmatch '^\s*===\s*Sustained Load Test') {
            break
        }

        $secondMatch = [regex]::Match($text, 'Second\s+\d+:\s*([0-9]+(?:\.[0-9]+)?)\s+req/s')
        if ($secondMatch.Success) {
            $value = 0.0
            if ([double]::TryParse($secondMatch.Groups[1].Value, [ref]$value)) {
                $perSecondReq.Add($value) | Out-Null
            }
            continue
        }

        $lastThreeMatch = [regex]::Match($text, 'Last\s+3\s+seconds\s+avg:\s*([0-9]+(?:\.[0-9]+)?)\s+req/s')
        if ($lastThreeMatch.Success) {
            $value = 0.0
            if ([double]::TryParse($lastThreeMatch.Groups[1].Value, [ref]$value)) {
                $lastThreeAverage = $value
            }
        }
    }

    if ($perSecondReq.Count -eq 0 -and $null -eq $lastThreeAverage) {
        return $null
    }

    $highestReqPerSec = if ($perSecondReq.Count -gt 0) { ($perSecondReq | Measure-Object -Maximum).Maximum } else { 0.0 }
    if ($null -eq $lastThreeAverage) {
        if ($perSecondReq.Count -ge 3) {
            $tail = @($perSecondReq | Select-Object -Last 3)
            $lastThreeAverage = ($tail | Measure-Object -Average).Average
        } elseif ($perSecondReq.Count -gt 0) {
            $lastThreeAverage = ($perSecondReq | Measure-Object -Average).Average
        } else {
            $lastThreeAverage = 0.0
        }
    }

    return [pscustomobject]@{
        HighestAcceptedReqPerSec = [double]$highestReqPerSec
        LastThreeSecondsAverageReqPerSec = [double]$lastThreeAverage
    }
}

function Test-IsAllGreenTestSummaryRow {
    param([object]$Row)

    if ($null -eq $Row) {
        return $false
    }

    $statusRaw = [string]$Row.Status
    if ($statusRaw -ne "PASS") {
        return $false
    }

    $totalValue = 0
    $passedValue = 0
    $failedValue = 0
    $hasTotal = [int]::TryParse([string]$Row.Total, [ref]$totalValue)
    $hasPassed = [int]::TryParse([string]$Row.Passed, [ref]$passedValue)
    $hasFailed = [int]::TryParse([string]$Row.Failed, [ref]$failedValue)

    if (-not $hasPassed -or -not $hasFailed) {
        return $false
    }

    if ($failedValue -gt 0) {
        return $false
    }

    if ($hasTotal -and $passedValue -lt $totalValue) {
        return $false
    }

    $coverageColor = Get-CoverageForegroundColor -CoverageText ([string]$Row.Coverage)
    return ($coverageColor -eq "Green")
}

function Invoke-LaunchScalarBrowsers {
    param(
        [object[]]$StartResults,
        [switch]$Launch
    )

    if (-not $Launch) {
        return
    }

    $scalarUrls = New-Object 'System.Collections.Generic.List[string]'
    foreach ($result in $StartResults) {
        if ($null -eq $result) {
            continue
        }

        $baseUrl = [string]$result.Url
        if ([string]::IsNullOrWhiteSpace($baseUrl)) {
            continue
        }

        $scalarUrl = $baseUrl.TrimEnd('/') + "/scalar"
        if (-not [string]::IsNullOrWhiteSpace($scalarUrl) -and -not $scalarUrls.Contains($scalarUrl)) {
            $scalarUrls.Add($scalarUrl) | Out-Null
        }
    }

    if ($scalarUrls.Count -eq 0) {
        Write-Host "No running URLs were available to launch in browser."
        return
    }

    Write-Host "Launching Scalar UI..."
    foreach ($scalarUrl in $scalarUrls) {
        Write-Host ("  {0}" -f $scalarUrl)
        Start-Process $scalarUrl | Out-Null
    }
}

function Write-ColorizedTestSummaryTable {
    param([object[]]$Rows)

    if ($null -eq $Rows -or $Rows.Count -eq 0) {
        Write-Host "No test summary rows to display."
        return
    }

    $headers = [ordered]@{
        Registered = "Registered"
        TestProject = "TestProject"
        Status = "Status"
        Total = "Total"
        Passed = "Passed"
        Failed = "Failed"
        Skipped = "Skipped"
        Coverage = "Coverage"
        DurationSec = "DurationSec"
    }

    $widths = @{}
    foreach ($key in $headers.Keys) {
        $widths[$key] = [int]$headers[$key].Length
    }

    foreach ($row in $Rows) {
        foreach ($key in $headers.Keys) {
            $text = [string]$row.$key
            if ($text.Length -gt $widths[$key]) {
                $widths[$key] = $text.Length
            }
        }
    }

    $orderedKeys = @("Registered", "TestProject", "Status", "Total", "Passed", "Failed", "Skipped", "Coverage", "DurationSec")
    $headerText = ""
    foreach ($key in $orderedKeys) {
        if ($headerText.Length -gt 0) {
            $headerText += " "
        }
        $headerText += $headers[$key].PadRight($widths[$key])
    }
    Write-Host $headerText

    $separatorText = ""
    foreach ($key in $orderedKeys) {
        if ($separatorText.Length -gt 0) {
            $separatorText += " "
        }
        $separatorText += ("-" * $widths[$key])
    }
    Write-Host $separatorText

    foreach ($row in $Rows) {
        $registeredText = ([string]$row.Registered).PadRight($widths["Registered"])
        $testProjectText = ([string]$row.TestProject).PadRight($widths["TestProject"])
        $statusRaw = [string]$row.Status
        $statusText = $statusRaw.PadRight($widths["Status"])
        $totalText = ([string]$row.Total).PadRight($widths["Total"])
        $passedText = ([string]$row.Passed).PadRight($widths["Passed"])
        $failedText = ([string]$row.Failed).PadRight($widths["Failed"])
        $skippedText = ([string]$row.Skipped).PadRight($widths["Skipped"])
        $durationText = ([string]$row.DurationSec).PadRight($widths["DurationSec"])

        $statusColor = "Gray"
        if ($statusRaw -eq "PASS") {
            $statusColor = "Green"
        } elseif ($statusRaw -eq "FAIL") {
            $statusColor = "Red"
        }

        $totalValue = 0
        $passedValue = 0
        $failedValue = 0
        $hasTotal = [int]::TryParse([string]$row.Total, [ref]$totalValue)
        $hasPassed = [int]::TryParse([string]$row.Passed, [ref]$passedValue)
        $hasFailed = [int]::TryParse([string]$row.Failed, [ref]$failedValue)

        $passedColor = "Gray"
        if ($hasPassed) {
            if ($hasTotal -and $passedValue -lt $totalValue) {
                $passedColor = "Yellow"
            } else {
                $passedColor = "Green"
            }
        }

        $failedColor = "Gray"
        if ($hasFailed) {
            if ($failedValue -gt 0) {
                $failedColor = "Red"
            } else {
                $failedColor = "Green"
            }
        }

        $coverageText = ([string]$row.Coverage).PadRight($widths["Coverage"])
        $coverageColor = Get-CoverageForegroundColor -CoverageText ([string]$row.Coverage)
        $fullRowText = $registeredText + " " + $testProjectText + " " + $statusText + " " + $totalText + " " + $passedText + " " + $failedText + " " + $skippedText + " " + $coverageText + " " + $durationText
        $allGreen = Test-IsAllGreenTestSummaryRow -Row $row

        if ($allGreen) {
            Write-Host $fullRowText -ForegroundColor Green
            continue
        }

        Write-Host -NoNewline ($registeredText + " " + $testProjectText + " ")
        Write-Host -NoNewline $statusText -ForegroundColor $statusColor
        Write-Host -NoNewline (" " + $totalText + " ")
        Write-Host -NoNewline $passedText -ForegroundColor $passedColor
        Write-Host -NoNewline " "
        Write-Host -NoNewline $failedText -ForegroundColor $failedColor
        Write-Host -NoNewline (" " + $skippedText + " ")

        Write-Host -NoNewline $coverageText -ForegroundColor $coverageColor

        Write-Host (" " + $durationText)
    }
}

function Run-TestsCommand {
    param([string[]]$RawArgs)

    Write-Host "Validating .NET environment..."
    Validate-DotnetForStart
    Write-Host "Parsing test command options..."
    $options = Get-RunTestsOptions -RawArgs $RawArgs
    if ($options.Restore) {
        Write-Host "Test restore mode: enabled (--restore)"
    } else {
        Write-Host "Test restore mode: disabled (--no-restore)"
    }
    Write-Host "Resolving registered project scope..."
    $entries = Get-RegisteredEntriesForTestRun -ProjectName $options.ProjectName

    $allTestProjects = New-Object 'System.Collections.Generic.List[object]'
    Write-Host "Discovering test projects..."
    foreach ($entry in $entries) {
        Write-Host ("  Scanning: {0}" -f $entry.Name)
        $paths = Get-TestProjectPathsForEntry -Entry $entry
        foreach ($path in $paths) {
            $allTestProjects.Add([pscustomobject]@{ EntryName = $entry.Name; TestProjectPath = $path }) | Out-Null
            Write-Host ("    Found test project: {0}" -f [System.IO.Path]::GetFileNameWithoutExtension($path))
        }
    }

    if ($allTestProjects.Count -eq 0) {
        throw "No test projects were found for the selected scope."
    }

    $runStamp = (Get-Date -Format "yyyyMMdd-HHmmss")
    $rootResultsDir = Join-Path $RootDir ".manage\test-results\$runStamp"
    Write-Host ("Creating results directory at {0}" -f $rootResultsDir)
    New-Item -ItemType Directory -Path $rootResultsDir -Force | Out-Null

    $reportRows = New-Object 'System.Collections.Generic.List[object]'

    Write-Host ""
    Write-Host "****************************************************************************************************" -ForegroundColor DarkGray
    Write-Host "*****************************************Running Tests**********************************************" -ForegroundColor DarkGray
    Write-Host "****************************************************************************************************" -ForegroundColor DarkGray
    Write-Host ("TestProjectsDiscovered: {0}" -f $allTestProjects.Count)
    Write-Host "TestsDiscovered: Pending (calculated from test results)"

    Write-Host "Starting test execution in parallel..."
    $overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $anyProjectFailed = $false
    $runItems = New-Object 'System.Collections.Generic.List[object]'
    $throughputSummaries = New-Object 'System.Collections.Generic.List[object]'

    foreach ($run in $allTestProjects) {
        $projectName = [System.IO.Path]::GetFileNameWithoutExtension($run.TestProjectPath)
        $resultsDir = Join-Path $rootResultsDir $projectName
        $outputLog = Join-Path $resultsDir "dotnet-test.out.log"
        $errorLog = Join-Path $resultsDir "dotnet-test.err.log"
        New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

        $argList = @("test", $run.TestProjectPath)
        if (-not $options.Restore) {
            $argList += "--no-restore"
        }
        $argList += @('--collect:"XPlat Code Coverage"', "--results-directory", $resultsDir, "--logger", "console;verbosity=normal")
        $process = Start-Process -FilePath $DotnetCmd -ArgumentList $argList -WorkingDirectory (Split-Path -Parent $run.TestProjectPath) -NoNewWindow -PassThru -RedirectStandardOutput $outputLog -RedirectStandardError $errorLog
        Write-Host ("  Started: {0} (PID {1})" -f $projectName, $process.Id)

        $runItems.Add([pscustomobject]@{
            Registered = $run.EntryName
            ProjectName = $projectName
            ProjectPath = $run.TestProjectPath
            ResultsDir = $resultsDir
            OutputLog = $outputLog
            ErrorLog = $errorLog
            Process = $process
            StartTime = Get-Date
            EndTime = $null
        }) | Out-Null
    }

    $showLiveElapsed = $false
    try {
        if ($Host -and $Host.Name -eq "ConsoleHost") {
            $showLiveElapsed = $true
        }
    } catch {
        $showLiveElapsed = $false
    }

    $running = $true
    $lastElapsedRender = -1.0
    Write-Host "Monitoring running tests..."
    while ($running) {
        $running = $false
        $activeIds = New-Object 'System.Collections.Generic.List[int]'

        foreach ($runItem in $runItems) {
            if (-not $runItem.Process.HasExited) {
                $running = $true
                $activeIds.Add([int]$runItem.Process.Id) | Out-Null
            } elseif ($null -eq $runItem.EndTime) {
                $runItem.EndTime = Get-Date
            }
        }

        if ($showLiveElapsed) {
            $elapsedNow = $overallStopwatch.Elapsed.TotalSeconds
            if ($elapsedNow -ge 0.05 -and [Math]::Abs($elapsedNow - $lastElapsedRender) -ge 0.05) {
                Write-Host -NoNewline ("`rElapsed: {0:N2}s" -f $elapsedNow)
                $lastElapsedRender = $elapsedNow
            }
        }

        if ($running -and $activeIds.Count -gt 0) {
            Wait-Process -Id $activeIds.ToArray() -Timeout 1 -ErrorAction SilentlyContinue | Out-Null
        }
    }

    if ($showLiveElapsed) {
        Write-Host ""
    }

    Write-Host "Collecting test results..."
    foreach ($runItem in $runItems) {
        if ($null -eq $runItem.EndTime) {
            $runItem.EndTime = Get-Date
        }
        Write-Host ("  Processing: {0}" -f $runItem.ProjectName)

        $outputLines = @()
        if (Test-Path -LiteralPath $runItem.OutputLog -PathType Leaf) {
            $outputLines += @(Get-Content -LiteralPath $runItem.OutputLog -ErrorAction SilentlyContinue)
        }
        if (Test-Path -LiteralPath $runItem.ErrorLog -PathType Leaf) {
            $outputLines += @(Get-Content -LiteralPath $runItem.ErrorLog -ErrorAction SilentlyContinue)
        }

        $summary = Parse-TestOutputSummary -OutputLines $outputLines
        $coverage = Get-CoveragePercentFromResults -ResultsDir $runItem.ResultsDir
        $throughput = Get-LoadBearingThroughputSummary -OutputLines $outputLines
        if ($null -ne $throughput) {
            $throughputSummaries.Add([pscustomobject]@{
                TestProject = $runItem.ProjectName
                HighestAcceptedReqPerSec = ("{0:F0}" -f $throughput.HighestAcceptedReqPerSec)
                LastThreeSecondsAverageReqPerSec = ("{0:F0}" -f $throughput.LastThreeSecondsAverageReqPerSec)
            }) | Out-Null
        }
        $exitCode = [int]$runItem.Process.ExitCode
        $hasToolErrors = Test-TestOutputHasErrors -OutputLines $outputLines
        if ($exitCode -eq 0 -and $summary.Total -eq 0 -and $hasToolErrors) {
            $exitCode = 1
        }

        $status = if ($exitCode -eq 0) { "PASS" } else { "FAIL" }
        if ($exitCode -ne 0) {
            $anyProjectFailed = $true
        }

        $durationSeconds = ($runItem.EndTime - $runItem.StartTime).TotalSeconds

        $reportRows.Add([pscustomobject]@{
            Registered = $runItem.Registered
            TestProject = $runItem.ProjectName
            Status = $status
            Total = $summary.Total
            Passed = $summary.Passed
            Failed = $summary.Failed
            Skipped = $summary.Skipped
            Coverage = $coverage
            DurationSec = ("{0:N2}" -f $durationSeconds)
        }) | Out-Null
    }
    $overallStopwatch.Stop()

    Write-Host "Rendering final summary..."
    Write-Host ""
    Write-Host "****************************************************************************************************" -ForegroundColor DarkGray
    Write-Host "****************************************Test Summary************************************************" -ForegroundColor DarkGray
    Write-Host "****************************************************************************************************" -ForegroundColor DarkGray

    $testsDiscovered = 0
    foreach ($row in $reportRows) {
        $testsDiscovered += [int]$row.Total
    }

    Write-Host ("TestProjectsDiscovered: {0}" -f $allTestProjects.Count)
    Write-Host ("TestsDiscovered: {0}" -f $testsDiscovered)

    $sortedReportRows = @(
        $reportRows | Sort-Object -Property `
            @{ Expression = { if (([string]$_.Status) -eq "FAIL") { 0 } else { 1 } } }, `
            @{ Expression = { if (Test-IsAllGreenTestSummaryRow -Row $_) { 1 } else { 0 } } }, `
            @{ Expression = { [string]$_.TestProject } }
    )

    Write-ColorizedTestSummaryTable -Rows $sortedReportRows

    if ($throughputSummaries.Count -gt 0) {
        Write-Host ""
        Write-Host "Load Bearing Throughput" -ForegroundColor DarkGray
        $throughputSummaries | Format-Table TestProject, HighestAcceptedReqPerSec, LastThreeSecondsAverageReqPerSec -AutoSize
    }

    $overallTotal = 0
    $overallPassed = 0
    $overallFailed = 0
    $overallSkipped = 0
    $coverageValues = New-Object 'System.Collections.Generic.List[double]'

    foreach ($row in $reportRows) {
        $overallTotal += [int]$row.Total
        $overallPassed += [int]$row.Passed
        $overallFailed += [int]$row.Failed
        $overallSkipped += [int]$row.Skipped

        $coverageText = [string]$row.Coverage
        if ($coverageText -match '^([0-9]+(?:\.[0-9]+)?)%$') {
            $coverageNumber = 0.0
            if ([double]::TryParse($Matches[1], [ref]$coverageNumber)) {
                $coverageValues.Add($coverageNumber) | Out-Null
            }
        }
    }

    $avgCoverage = "N/A"
    if ($coverageValues.Count -gt 0) {
        $sum = 0.0
        foreach ($value in $coverageValues) {
            $sum += $value
        }
        $avgCoverage = ("{0:N2}%" -f ($sum / $coverageValues.Count))
    }

    Write-Host ""
    Write-Host ("Overall: {0} total, {1} passed, {2} failed, {3} skipped, Avg coverage {4}" -f $overallTotal, $overallPassed, $overallFailed, $overallSkipped, $avgCoverage)
    Write-Host ("Duration: {0:N2}s" -f $overallStopwatch.Elapsed.TotalSeconds)
    Write-Host ""
    Write-Host "****************************************************************************************************" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Results directory: $rootResultsDir"

    if ($anyProjectFailed) {
        throw "One or more test projects failed."
    }
}

function Set-EnableApiDocsInAppSettings {
    param(
        [string]$AppSettingsPath,
        [bool]$Enabled
    )

    if (-not (Test-Path -LiteralPath $AppSettingsPath)) {
        return
    }

    $json = Get-Content -LiteralPath $AppSettingsPath -Raw | ConvertFrom-Json
    $json | Add-Member -NotePropertyName EnableApiDocs -NotePropertyValue $Enabled -Force
    $updatedJson = Format-JsonWithTabs -JsonText ($json | ConvertTo-Json -Depth 30)
    Set-Content -LiteralPath $AppSettingsPath -Value $updatedJson -Encoding UTF8
}

function Format-JsonWithTabs {
    param([string]$JsonText)

    $lines = $JsonText -split "`r?`n"
    $indentLevel = 0
    $formattedLines = New-Object 'System.Collections.Generic.List[string]'

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        if ($trimmed.StartsWith("}") -or $trimmed.StartsWith("]")) {
            $indentLevel = [Math]::Max(0, $indentLevel - 1)
        }

        $normalized = $trimmed -replace '":\s+', '": '
        $formattedLines.Add(("`t" * $indentLevel) + $normalized) | Out-Null

        if ($trimmed.EndsWith("{") -or $trimmed.EndsWith("[")) {
            $indentLevel++
        }
    }

    return ($formattedLines -join [Environment]::NewLine)
}

function Set-ApiProgramForScalar {
    param(
        [string]$ProgramPath,
        [string]$ProjectName
    )

    $programContent = @"
using Microsoft.OpenApi.Models;
using Scalar.AspNetCore;

var builder = WebApplication.CreateBuilder(args);
var services = builder.Services;

services.AddControllers();

var enableApiDocs = builder.Configuration.GetValue<bool>("EnableApiDocs");
if (enableApiDocs)
{
    services.AddOpenApi("v1", options =>
    {
        options.AddDocumentTransformer((doc, _, _) =>
        {
            doc.Info = new OpenApiInfo
            {
                Version = "v1",
                Title = "$ProjectName API",
                Description = "API description."
            };
            return Task.CompletedTask;
        });
    });
}

var app = builder.Build();

if (app.Environment.IsDevelopment() && enableApiDocs)
{
    app.MapOpenApi("/openapi/v1.json");
    app.MapScalarApiReference();
}

app.UseHttpsRedirection();

app.UseAuthorization();

app.MapControllers();

app.Run();
"@

    Set-Content -LiteralPath $ProgramPath -Value $programContent -Encoding UTF8
}

function Remove-PackageReferenceIfPresent {
    param(
        [string]$CsprojPath,
        [string]$PackageName,
        [string]$WorkingDirectory
    )

    if (-not (Test-Path -LiteralPath $CsprojPath)) {
        return
    }

    $content = Get-Content -LiteralPath $CsprojPath -Raw
    $packagePattern = '<PackageReference\s+Include="' + [regex]::Escape($PackageName) + '"'
    if ($content -match $packagePattern) {
        Invoke-DotnetCommandChecked -WorkingDirectory $WorkingDirectory -Arguments @("remove", $CsprojPath, "package", $PackageName)
    }
}

function Ensure-ReadmeFile {
    param(
        [string]$DirectoryPath,
        [string]$ProjectName,
        [string]$TemplateKind
    )

    $readmePath = Join-Path $DirectoryPath "README.md"
    if (Test-Path -LiteralPath $readmePath) {
        return
    }

    $content = @"
# $ProjectName

Generated by manage.ps1 new $TemplateKind.
"@
    Set-Content -LiteralPath $readmePath -Value $content -Encoding UTF8
}

function Get-OrCreateSolutionFileName {
    param(
        [string]$BasePath,
        [string]$ProjectName
    )

    $slnPath = Join-Path $BasePath "$ProjectName.sln"
    if (Test-Path -LiteralPath $slnPath) {
        return "$ProjectName.sln"
    }

    $slnxPath = Join-Path $BasePath "$ProjectName.slnx"
    if (Test-Path -LiteralPath $slnxPath) {
        return "$ProjectName.slnx"
    }

    Invoke-DotnetCommandChecked -WorkingDirectory $BasePath -Arguments @("new", "sln", "-n", $ProjectName) | Out-Null

    if (Test-Path -LiteralPath $slnPath) {
        return "$ProjectName.sln"
    }

    if (Test-Path -LiteralPath $slnxPath) {
        return "$ProjectName.slnx"
    }

    throw "Unable to locate solution file after 'dotnet new sln' in $BasePath"
}

function Add-ProjectToSolutionIfMissing {
    param(
        [string]$BasePath,
        [string]$SolutionFileName,
        [string]$ProjectRelativePath
    )

    $listOutput = Invoke-DotnetCommandChecked -WorkingDirectory $BasePath -Arguments @("sln", $SolutionFileName, "list")
    $normalizedPath = ($ProjectRelativePath -replace '/', '\\')

    foreach ($line in $listOutput) {
        $text = [string]$line
        if ($text.Trim().EndsWith($normalizedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }

    Invoke-DotnetCommandChecked -WorkingDirectory $BasePath -Arguments @("sln", $SolutionFileName, "add", $ProjectRelativePath) | Out-Null
}

function Resolve-ScaffoldRootPath {
    param(
        [string]$BasePath,
        [string]$ProjectName,
        [bool]$NoParent
    )

    if ($NoParent) {
        return $BasePath
    }

    return (Join-Path $BasePath $ProjectName)
}

function Get-ManageYamlRelativePath {
    param([string]$AbsolutePath)

    $fullRoot = [System.IO.Path]::GetFullPath($RootDir)
    $fullTarget = [System.IO.Path]::GetFullPath($AbsolutePath)
    if (-not $fullTarget.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    $relative = $fullTarget.Substring($fullRoot.Length).TrimStart([char[]]@([char]92, [char]47))
    return ($relative -replace "\\", "/")
}

function Test-ManageYamlHasPath {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Path
    )

    $needle = $Path.Trim()
    foreach ($line in $Lines) {
        if ($line.Trim() -eq ("path: " + $needle)) {
            return $true
        }
    }

    return $false
}

function Get-NextManageYamlPort {
    param([System.Collections.Generic.List[string]]$Lines)

    $maxPort = 5100
    foreach ($line in $Lines) {
        if ($line -match '^\s*port:\s*([0-9]+)\s*$') {
            $value = [int]$Matches[1]
            if ($value -gt $maxPort) {
                $maxPort = $value
            }
        }
    }

    return ($maxPort + 1)
}

function Get-UniqueManageYamlName {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$BaseName
    )

    $existing = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $Lines) {
        if ($line -match '^\s*-\s*name:\s*(.+)$') {
            [void]$existing.Add((Remove-SurroundingQuotes -Text $Matches[1]))
        }
    }

    $candidate = $BaseName
    $suffix = 2
    while ($existing.Contains($candidate)) {
        $candidate = "$BaseName-$suffix"
        $suffix++
    }

    return $candidate
}

function Update-ManageYamlForScaffold {
    param(
        [string]$TemplateKind,
        [string]$ProjectName,
        [string]$ScaffoldRootPath,
        [bool]$WithClient
    )

    if (-not (Test-Path -LiteralPath $StackFile)) {
        return
    }

    $rawLines = @(Get-Content -LiteralPath $StackFile)
    $firstContentLine = $null
    foreach ($line in $rawLines) {
        $trimmed = $line.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed) -and -not $trimmed.StartsWith("#")) {
            $firstContentLine = $trimmed
            break
        }
    }

    if (($firstContentLine -ne "apis:") -and ($firstContentLine -ne "projects:")) {
        Write-Host "Skipping manage.yaml update: only YAML stack files with an 'apis:' root are supported."
        return
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $rawLines) {
        $lines.Add($line) | Out-Null
    }

    $updated = $false

    if ($TemplateKind -eq "api") {
        $apiCsproj = Join-Path (Join-Path $ScaffoldRootPath "$ProjectName.API") "$ProjectName.API.csproj"
        $apiRelPath = Get-ManageYamlRelativePath -AbsolutePath $apiCsproj
        if ($null -eq $apiRelPath) {
            Write-Host "Skipping API stack registration: project path is outside repository root."
        } elseif (-not (Test-ManageYamlHasPath -Lines $lines -Path $apiRelPath)) {
            $projectAlias = Get-UniqueManageYamlName -Lines $lines -BaseName (Convert-ToSlug -Text $ProjectName)
            $nextPort = Get-NextManageYamlPort -Lines $lines
            $clientsIndex = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i].Trim() -eq "clients:") {
                    $clientsIndex = $i
                    break
                }
            }

            $insertAt = if ($clientsIndex -ge 0) { $clientsIndex } else { $lines.Count }
            $block = @(
                "  - name: $projectAlias",
                "    path: $apiRelPath",
                "    port: $nextPort",
                "    depends_on: []",
                "    groups: []",
                "    default_branch: develop",
                ""
            )

            $lines.InsertRange($insertAt, [string[]]$block)
            $updated = $true
        }
    }

    $shouldAddClient = ($TemplateKind -eq "client") -or (($TemplateKind -eq "api") -and $WithClient)
    if ($shouldAddClient) {
        $clientCsproj = Join-Path (Join-Path $ScaffoldRootPath "$ProjectName.Client") "$ProjectName.Client.csproj"
        $clientRelPath = Get-ManageYamlRelativePath -AbsolutePath $clientCsproj
        if ($null -eq $clientRelPath) {
            Write-Host "Skipping client stack registration: project path is outside repository root."
        } elseif (-not (Test-ManageYamlHasPath -Lines $lines -Path $clientRelPath)) {
            $clientsIndex = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i].Trim() -eq "clients:") {
                    $clientsIndex = $i
                    break
                }
            }

            if ($clientsIndex -lt 0) {
                if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
                    $lines.Add("") | Out-Null
                }
                $lines.Add("clients:") | Out-Null
                $clientsIndex = $lines.Count - 1
            }

            $clientAlias = Get-UniqueManageYamlName -Lines $lines -BaseName (Convert-ToSlug -Text "$ProjectName-client")
            $entry = @(
                "  - name: $clientAlias",
                "    path: $clientRelPath",
                "    default_branch: develop",
                ""
            )
            $lines.InsertRange($lines.Count, [string[]]$entry)
            $updated = $true
        }
    }

    if ($updated) {
        Set-Content -LiteralPath $StackFile -Value $lines -Encoding UTF8
        Write-Host "Updated stack file: $StackFile"
    }
}

function Get-NewCommandOptions {
    param(
        [string]$TemplateKind,
        [string[]]$RawArgs
    )

    $projectName = ""
    $withClient = $false
    $basePath = (Get-Location).Path
    $noParent = $false

    for ($i = 0; $i -lt $RawArgs.Count; $i++) {
        $token = [string]$RawArgs[$i]
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }

        if ($token -eq "--with-client") {
            if ($TemplateKind -ne "api") {
                throw "--with-client is only supported for 'new api'."
            }
            $withClient = $true
            continue
        }

        if ($token -eq "--no-parent") {
            $noParent = $true
            continue
        }

        if ($token -eq "--path") {
            if (($i + 1) -ge $RawArgs.Count) {
                throw "Missing value for --path"
            }

            $i++
            $basePath = [string]$RawArgs[$i]
            continue
        }

        if ($token.StartsWith("-")) {
            throw "Unknown option: $token"
        }

        if ([string]::IsNullOrWhiteSpace($projectName)) {
            $projectName = $token
        } else {
            throw "Unexpected argument: $token"
        }
    }

    if ([string]::IsNullOrWhiteSpace($projectName)) {
        throw "Project name is required."
    }

    if ($projectName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "Invalid project name: $projectName"
    }

    $resolvedBasePath = ""
    if ([System.IO.Path]::IsPathRooted($basePath)) {
        $resolvedBasePath = [System.IO.Path]::GetFullPath($basePath)
    } else {
        $resolvedBasePath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $basePath))
    }

    [pscustomobject]@{
        ProjectName = $projectName
        WithClient = $withClient
        BasePath = $resolvedBasePath
        NoParent = $noParent
    }
}

function Invoke-NewApiTemplate {
    param(
        [string]$ProjectName,
        [bool]$WithClient,
        [string]$BasePath,
        [bool]$NoParent
    )

    Validate-DotnetForStart

    if (-not (Test-Path -LiteralPath $BasePath)) {
        New-Item -ItemType Directory -Path $BasePath | Out-Null
    }

    $scaffoldRootPath = Resolve-ScaffoldRootPath -BasePath $BasePath -ProjectName $ProjectName -NoParent $NoParent
    if (-not (Test-Path -LiteralPath $scaffoldRootPath)) {
        New-Item -ItemType Directory -Path $scaffoldRootPath | Out-Null
    }

    $projectFolders = @(
        "$ProjectName.API",
        "$ProjectName.API.Data",
        "$ProjectName.API.Test",
        "$ProjectName.API.Data.Test"
    )

    Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("new", "webapi", "-o", "$ProjectName.API")
    Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("new", "classlib", "-o", "$ProjectName.API.Data")
    Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("new", "nunit", "-o", "$ProjectName.API.Test")
    Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("new", "nunit", "-o", "$ProjectName.API.Data.Test")

    Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("add", "$ProjectName.API/$ProjectName.API.csproj", "reference", "$ProjectName.API.Data/$ProjectName.API.Data.csproj")
    Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("add", "$ProjectName.API.Test/$ProjectName.API.Test.csproj", "reference", "$ProjectName.API/$ProjectName.API.csproj")
    Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("add", "$ProjectName.API.Data.Test/$ProjectName.API.Data.Test.csproj", "reference", "$ProjectName.API.Data/$ProjectName.API.Data.csproj")

    if ($WithClient) {
        $projectFolders += @(
            "$ProjectName.Client",
            "$ProjectName.Contracts",
            "$ProjectName.Client.Test",
            "$ProjectName.Contracts.Test"
        )

        Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("new", "classlib", "-o", "$ProjectName.Client")
        Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("new", "classlib", "-o", "$ProjectName.Contracts")
        Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("new", "nunit", "-o", "$ProjectName.Client.Test")
        Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("new", "nunit", "-o", "$ProjectName.Contracts.Test")

        Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("add", "$ProjectName.API/$ProjectName.API.csproj", "reference", "$ProjectName.Contracts/$ProjectName.Contracts.csproj")
        Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("add", "$ProjectName.API.Data/$ProjectName.API.Data.csproj", "reference", "$ProjectName.Contracts/$ProjectName.Contracts.csproj")
        Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("add", "$ProjectName.Client/$ProjectName.Client.csproj", "reference", "$ProjectName.Contracts/$ProjectName.Contracts.csproj")
        Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("add", "$ProjectName.Client.Test/$ProjectName.Client.Test.csproj", "reference", "$ProjectName.Client/$ProjectName.Client.csproj")
        Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("add", "$ProjectName.Contracts.Test/$ProjectName.Contracts.Test.csproj", "reference", "$ProjectName.Contracts/$ProjectName.Contracts.csproj")
    }

    Remove-DefaultScaffoldFiles -ScaffoldRootPath $scaffoldRootPath -ProjectFolders $projectFolders
    Create-ApiDataScaffoldingFiles -ProjectName $ProjectName -ScaffoldRootPath $scaffoldRootPath
    Create-ApiScaffoldingFiles -ProjectName $ProjectName -ScaffoldRootPath $scaffoldRootPath
    if ($WithClient) {
        Create-ClientScaffoldingFiles -ProjectName $ProjectName -ScaffoldRootPath $scaffoldRootPath
    }

    foreach ($folder in $projectFolders) {
        $csprojPath = Join-Path (Join-Path $scaffoldRootPath $folder) ("$folder.csproj")
        $isClientProject = $folder.EndsWith(".Client", [System.StringComparison]::OrdinalIgnoreCase)
        Add-StandardCsprojPropertyGroups -CsprojPath $csprojPath -ProjectName $ProjectName -IsClientProject:$isClientProject
    }

    $apiCsprojPath = Join-Path (Join-Path $scaffoldRootPath "$ProjectName.API") ("$ProjectName.API.csproj")
    Remove-PackageReferenceIfPresent -CsprojPath $apiCsprojPath -PackageName "Swashbuckle.AspNetCore" -WorkingDirectory $scaffoldRootPath
    Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("add", "$ProjectName.API/$ProjectName.API.csproj", "package", "Scalar.AspNetCore")

    Set-ApiProgramForScalar -ProgramPath (Join-Path (Join-Path $scaffoldRootPath "$ProjectName.API") "Program.cs") -ProjectName $ProjectName
    Set-EnableApiDocsInAppSettings -AppSettingsPath (Join-Path (Join-Path $scaffoldRootPath "$ProjectName.API") "appsettings.Development.json") -Enabled $true
    Set-EnableApiDocsInAppSettings -AppSettingsPath (Join-Path (Join-Path $scaffoldRootPath "$ProjectName.API") "appsettings.json") -Enabled $false

    $solutionFileName = Get-OrCreateSolutionFileName -BasePath $scaffoldRootPath -ProjectName $ProjectName

    foreach ($folder in $projectFolders) {
        Add-ProjectToSolutionIfMissing -BasePath $scaffoldRootPath -SolutionFileName $solutionFileName -ProjectRelativePath "$folder/$folder.csproj"
    }

    if (-not (Test-Path -LiteralPath (Join-Path $scaffoldRootPath ".gitignore"))) {
        Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("new", "gitignore")
    }

    Ensure-ReadmeFile -DirectoryPath $scaffoldRootPath -ProjectName $ProjectName -TemplateKind "api"
    Update-ManageYamlForScaffold -TemplateKind "api" -ProjectName $ProjectName -ScaffoldRootPath $scaffoldRootPath -WithClient $WithClient
    Write-Host "Created API solution for $ProjectName at $scaffoldRootPath"
}

function Invoke-NewClientTemplate {
    param(
        [string]$ProjectName,
        [string]$BasePath,
        [bool]$NoParent
    )

    Validate-DotnetForStart

    if (-not (Test-Path -LiteralPath $BasePath)) {
        New-Item -ItemType Directory -Path $BasePath | Out-Null
    }

    $scaffoldRootPath = Resolve-ScaffoldRootPath -BasePath $BasePath -ProjectName $ProjectName -NoParent $NoParent
    if (-not (Test-Path -LiteralPath $scaffoldRootPath)) {
        New-Item -ItemType Directory -Path $scaffoldRootPath | Out-Null
    }

    $projectFolders = @(
        "$ProjectName.Client",
        "$ProjectName.Client.Test"
    )

    Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("new", "classlib", "-o", "$ProjectName.Client")
    Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("new", "nunit", "-o", "$ProjectName.Client.Test")
    Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("add", "$ProjectName.Client.Test/$ProjectName.Client.Test.csproj", "reference", "$ProjectName.Client/$ProjectName.Client.csproj")

    Remove-DefaultScaffoldFiles -ScaffoldRootPath $scaffoldRootPath -ProjectFolders $projectFolders
    Create-ClientScaffoldingFiles -ProjectName $ProjectName -ScaffoldRootPath $scaffoldRootPath

    foreach ($folder in $projectFolders) {
        $csprojPath = Join-Path (Join-Path $scaffoldRootPath $folder) ("$folder.csproj")
        $isClientProject = $folder.EndsWith(".Client", [System.StringComparison]::OrdinalIgnoreCase)
        Add-StandardCsprojPropertyGroups -CsprojPath $csprojPath -ProjectName $ProjectName -IsClientProject:$isClientProject
    }

    $solutionFileName = Get-OrCreateSolutionFileName -BasePath $scaffoldRootPath -ProjectName $ProjectName

    foreach ($folder in $projectFolders) {
        Add-ProjectToSolutionIfMissing -BasePath $scaffoldRootPath -SolutionFileName $solutionFileName -ProjectRelativePath "$folder/$folder.csproj"
    }

    if (-not (Test-Path -LiteralPath (Join-Path $scaffoldRootPath ".gitignore"))) {
        Invoke-DotnetCommandChecked -WorkingDirectory $scaffoldRootPath -Arguments @("new", "gitignore")
    }

    Ensure-ReadmeFile -DirectoryPath $scaffoldRootPath -ProjectName $ProjectName -TemplateKind "client"
    Update-ManageYamlForScaffold -TemplateKind "client" -ProjectName $ProjectName -ScaffoldRootPath $scaffoldRootPath -WithClient:$false
    Write-Host "Created client solution for $ProjectName at $scaffoldRootPath"
}

function Invoke-NewProjectCommand {
    param(
        [string]$TemplateKind,
        [string[]]$RawArgs
    )

    $options = Get-NewCommandOptions -TemplateKind $TemplateKind -RawArgs $RawArgs

    if ($TemplateKind -eq "api") {
        Invoke-NewApiTemplate -ProjectName $options.ProjectName -WithClient $options.WithClient -BasePath $options.BasePath -NoParent $options.NoParent
        return
    }

    if ($TemplateKind -eq "client") {
        Invoke-NewClientTemplate -ProjectName $options.ProjectName -BasePath $options.BasePath -NoParent $options.NoParent
        return
    }

    throw "Unknown new subcommand: $TemplateKind (expected 'api' or 'client')"
}

function Get-Project {
    param([string]$Name)
    return $Projects | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Get-Group {
    param([string]$Name)
    return $Groups | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Get-ProjectGroups {
    param([string]$ProjectName)

    $groupNames = @()
    foreach ($group in $Groups) {
        if ($group.Members -contains $ProjectName) {
            $groupNames += $group.Name
        }
    }

    if ($groupNames.Count -eq 0) {
        return ""
    }

    return ($groupNames -join ", ")
}

function Show-ProjectTable {
    $rows = foreach ($project in $Projects) {
        [void](Sync-ProjectTracking -ProjectName $project.Name -Quiet)
        $pidFile = Join-Path $PidDir "$($project.Name).pid"
        $portFile = Join-Path $PidDir "$($project.Name).port"
        $trackedPort = "-"
        $status = "stopped"
        $pidText = ""
        $targetPid = $null

        if (Test-Path -LiteralPath $pidFile) {
            $pidText = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
        }

        if (Test-Path -LiteralPath $portFile) {
            $value = (Get-Content -LiteralPath $portFile -Raw -ErrorAction SilentlyContinue).Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $trackedPort = $value
            }
        }

        $trackedPortListening = $false
        if ($trackedPort -ne "-") {
            $trackedPortNumber = 0
            if ([int]::TryParse($trackedPort, [ref]$trackedPortNumber)) {
                $trackedPortListening = Test-PortInUse -Port $trackedPortNumber
            }
        }

        if ($trackedPortListening) {
            $status = "running"
        } elseif (-not [string]::IsNullOrWhiteSpace($pidText)) {
            try {
                $targetPid = [int]$pidText
                $proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue

                if ($null -eq $proc) {
                    $status = "stale-pid"
                } else {
                    if ($trackedPort -eq "-") {
                        $status = "running-untracked"
                    } else {
                        $status = "running-no-listener"
                    }
                }
            } catch {
                $status = "stale-pid"
            }
        }

        [pscustomobject]@{
            App = $project.Name
            BasePort = $project.BasePort
            TrackedPort = $trackedPort
            Status = $status
            Groups = (Get-ProjectGroups -ProjectName $project.Name)
        }
    }

    $rows | Format-Table -AutoSize -Wrap
}

function Test-PortInUse {
    param([int]$Port)

    try {
        $listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
        return ($null -ne $listener)
    } catch {
        return $false
    }
}

function Get-ListeningPidForPort {
    param([int]$Port)

    try {
        $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $conn) {
            return [int]$conn.OwningProcess
        }
    } catch {
    }

    return $null
}

function Find-AvailablePort {
    param([int]$BasePort)

    $startPort = $BasePort + $DevPortOffset
    for ($i = 0; $i -le $PortSearchLimit; $i++) {
        $candidate = $startPort + $i

        if ($AllocatedPorts.Contains($candidate)) {
            continue
        }

        if (Test-PortInUse -Port $candidate) {
            continue
        }

        [void]$AllocatedPorts.Add($candidate)
        return $candidate
    }

    throw "Unable to find an available port for base $BasePort (offset $DevPortOffset, search limit $PortSearchLimit)."
}

function Validate-DotnetForStart {
    $dotnetExists = $null -ne (Get-Command $DotnetCmd -ErrorAction SilentlyContinue)
    if (-not $dotnetExists) {
        throw "dotnet CLI was not found on PATH."
    }

    $script:ActiveDotnetVersion = (& $DotnetCmd --version).Trim()
    if (-not [string]::IsNullOrWhiteSpace($DotnetVersionRequired) -and -not $script:ActiveDotnetVersion.StartsWith($DotnetVersionRequired)) {
        throw "Requested DOTNET_VERSION=$DotnetVersionRequired, but active version is $script:ActiveDotnetVersion. Use a matching dotnet executable via DOTNET_CMD or configure global.json for SDK pinning."
    }
}

function Start-Project {
    param(
        [string]$Name,
        [string]$RelPath,
        [int]$BasePort,
        [switch]$Clean,
        [switch]$Restore
    )

    $projectPath = Join-Path $RootDir $RelPath
    $pidFile = Join-Path $PidDir "$Name.pid"
    $portFile = Join-Path $PidDir "$Name.port"
    $logFile = Join-Path $LogDir "$Name.log"
    $errorLogFile = Join-Path $LogDir "$Name.err.log"

    if (-not (Test-Path -LiteralPath $projectPath)) {
        throw "Skipping ${Name}: project not found at $projectPath"
    }

    Ensure-LocalNugetConfig -RelPath $RelPath

    # Build associated clients before starting the project
    # For each dependency, build its client NuGet package
    $projectDeps = $script:ProjectDependencies[$Name]
    if ($null -ne $projectDeps -and $projectDeps.Count -gt 0) {
        Write-Host "Building client NuGet packages for dependencies..."
        foreach ($depName in $projectDeps) {
            try {
                Build-NugetPackages -TargetName $depName
            } catch {
                Write-Host "Warning: Failed to build client package for '$depName'. Continuing with service startup..."
            }
        }
    }

    [void](Sync-ProjectTracking -ProjectName $Name -Quiet)

    if (Test-Path -LiteralPath $pidFile) {
        $existingPid = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
        if (-not [string]::IsNullOrWhiteSpace($existingPid)) {
            $existingProcess = Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue
            if ($null -ne $existingProcess) {
                $existingPort = ""
                if (Test-Path -LiteralPath $portFile) {
                    $existingPort = (Get-Content -LiteralPath $portFile -Raw -ErrorAction SilentlyContinue).Trim()
                }

                if ([string]::IsNullOrWhiteSpace($existingPort)) {
                    Write-Host "Skipping ${Name}: already running (pid $existingPid)."
                    return [pscustomobject]@{
                        Name = $Name
                        Url = ""
                    }
                } else {
                    $existingPortNumber = 0
                    if ([int]::TryParse($existingPort, [ref]$existingPortNumber)) {
                        $runtimePid = Get-ListeningPidForPort -Port $existingPortNumber
                        if ($null -ne $runtimePid -and $runtimePid -ne [int]$existingPid) {
                            Set-Content -LiteralPath $pidFile -Value $runtimePid -NoNewline
                            $existingPid = [string]$runtimePid
                        }
                    }
                    Write-Host "Skipping ${Name}: already running (pid $existingPid, url http://localhost:$existingPort)."
                    return [pscustomobject]@{
                        Name = $Name
                        Url = ("http://localhost:{0}" -f $existingPort)
                    }
                }
            }
        }

        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }

    if (Test-PortInUse -Port $BasePort) {
        $runtimePid = Get-ListeningPidForPort -Port $BasePort
        Set-Content -LiteralPath $portFile -Value $BasePort -NoNewline

        if ($null -ne $runtimePid) {
            Set-Content -LiteralPath $pidFile -Value $runtimePid -NoNewline
            Write-Host "Skipping ${Name}: detected existing listener on http://localhost:$BasePort (pid $runtimePid)."
        } else {
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
            Write-Host "Skipping ${Name}: detected existing listener on http://localhost:$BasePort."
        }

        return [pscustomobject]@{
            Name = $Name
            Url = ("http://localhost:{0}" -f $BasePort)
        }
    }

    $port = Find-AvailablePort -BasePort $BasePort
    $urls = "http://localhost:$port"
    $projectDir = Split-Path -Parent $projectPath

    if ($Clean) {
        Write-Host "Pre-start clean for $Name..."
        Invoke-DotnetCommandChecked -WorkingDirectory $projectDir -Arguments @("clean", $projectPath, "--configuration", $BuildConfiguration)
    }

    if ($Restore) {
        Write-Host "Pre-start restore for $Name..."
        Invoke-DotnetCommandChecked -WorkingDirectory $projectDir -Arguments @("restore", $projectPath)
    }

    # Reset startup log for this run so old exceptions do not leak into health checks.
    Set-Content -LiteralPath $logFile -Value "" -Encoding UTF8
    Set-Content -LiteralPath $errorLogFile -Value "" -Encoding UTF8

    Write-Host "Starting $Name..."

    $previousAspNetCoreEnvironment = $env:ASPNETCORE_ENVIRONMENT
    $previousDotnetEnvironment = $env:DOTNET_ENVIRONMENT
    $previousAspNetCoreUrls = $env:ASPNETCORE_URLS

    $env:ASPNETCORE_ENVIRONMENT = $AspNetCoreEnvironment
    $env:DOTNET_ENVIRONMENT = $AspNetCoreEnvironment
    $env:ASPNETCORE_URLS = $urls

    try {
        $runArgs = @("run", "--project", $projectPath, "--configuration", $BuildConfiguration, "--no-launch-profile", "--no-restore")
        $process = Start-Process -FilePath $DotnetCmd -ArgumentList $runArgs -WorkingDirectory $projectDir -WindowStyle Hidden -PassThru -RedirectStandardOutput $logFile -RedirectStandardError $errorLogFile
    } finally {
        $env:ASPNETCORE_ENVIRONMENT = $previousAspNetCoreEnvironment
        $env:DOTNET_ENVIRONMENT = $previousDotnetEnvironment
        $env:ASPNETCORE_URLS = $previousAspNetCoreUrls
    }

    Set-Content -LiteralPath $pidFile -Value $process.Id -NoNewline
    Set-Content -LiteralPath $portFile -Value $port -NoNewline

    try {
        Wait-ForProjectStartup -Name $Name -ProcessId $process.Id -Port $port -LogFile $logFile -ErrorLogFile $errorLogFile
        $runtimePid = Get-ListeningPidForPort -Port $port
        if ($null -ne $runtimePid) {
            Set-Content -LiteralPath $pidFile -Value $runtimePid -NoNewline
        }
    } catch {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        } catch {
        }

        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $portFile -Force -ErrorAction SilentlyContinue
        throw
    }

    Write-Host "  url: $urls"
    Write-Host "  log: $logFile"
    Write-Host "  err: $errorLogFile"
    Write-Host "  pid: $($process.Id)"

    return [pscustomobject]@{
        Name = $Name
        Url = $urls
    }
}

function Stop-Project {
    param([string]$Name)

    [void](Sync-ProjectTracking -ProjectName $Name -Quiet)

    $pidFile = Join-Path $PidDir "$Name.pid"
    $portFile = Join-Path $PidDir "$Name.port"
    $trackedPort = ""
    $basePort = $null
    $stopPort = $null
    $targetPid = $null

    $project = Get-Project -Name $Name
    if ($null -ne $project) {
        $basePort = [int]$project.BasePort
    }

    if (Test-Path -LiteralPath $portFile) {
        $trackedPort = (Get-Content -LiteralPath $portFile -Raw -ErrorAction SilentlyContinue).Trim()
    }

    $trackedPortNumber = 0
    if ([int]::TryParse($trackedPort, [ref]$trackedPortNumber)) {
        $stopPort = $trackedPortNumber
    } elseif ($null -ne $basePort) {
        $stopPort = $basePort
    }

    if ($null -ne $stopPort -and (Test-PortInUse -Port $stopPort)) {
        $listenerPid = Get-ListeningPidForPort -Port $stopPort
        if ($null -ne $listenerPid) {
            $targetPid = [int]$listenerPid
            Set-Content -LiteralPath $pidFile -Value $targetPid -NoNewline
            Set-Content -LiteralPath $portFile -Value $stopPort -NoNewline
        }
    }

    if ($null -eq $targetPid -and -not (Test-Path -LiteralPath $pidFile)) {
        Write-Host "Skipping ${Name}: no PID file found."
        return
    }

    if ($null -eq $targetPid) {
        $pidText = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
        if (-not [string]::IsNullOrWhiteSpace($pidText)) {
            $candidatePid = 0
            if ([int]::TryParse($pidText, [ref]$candidatePid)) {
                $targetPid = $candidatePid
            }
        }
    }

    if ($null -eq $targetPid) {
        Write-Host "Skipping ${Name}: PID file is empty."
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        if ($null -eq $stopPort -or -not (Test-PortInUse -Port $stopPort)) {
            Remove-Item -LiteralPath $portFile -Force -ErrorAction SilentlyContinue
        }
        return
    }

    $portDescriptor = if ($null -ne $stopPort) { ", port $stopPort" } else { "" }
    Write-Host "Stopping $Name (pid $targetPid$portDescriptor)..."

    try {
        Stop-Process -Id $targetPid -ErrorAction SilentlyContinue
    } catch {
    }

    for ($i = 0; $i -lt 5; $i++) {
        if ($null -ne $stopPort -and (Test-PortInUse -Port $stopPort)) {
            $currentListenerPid = Get-ListeningPidForPort -Port $stopPort
            if ($null -ne $currentListenerPid -and [int]$currentListenerPid -ne $targetPid) {
                $targetPid = [int]$currentListenerPid
                try {
                    Stop-Process -Id $targetPid -ErrorAction SilentlyContinue
                } catch {
                }
            }
        } else {
            break
        }

        Start-Sleep -Seconds 1
    }

    if ($null -ne $stopPort -and (Test-PortInUse -Port $stopPort)) {
        $currentListenerPid = Get-ListeningPidForPort -Port $stopPort
        if ($null -ne $currentListenerPid) {
            Write-Host "  forcing stop for $Name (pid $currentListenerPid, port $stopPort)..."
            try {
                Stop-Process -Id ([int]$currentListenerPid) -Force -ErrorAction SilentlyContinue
            } catch {
            }
            Start-Sleep -Seconds 1
        }
    }

    if ($null -ne $stopPort -and (Test-PortInUse -Port $stopPort)) {
        $remainingPid = Get-ListeningPidForPort -Port $stopPort
        if ($null -ne $remainingPid) {
            Set-Content -LiteralPath $pidFile -Value ([int]$remainingPid) -NoNewline
        }

        Write-Host "Failed to stop ${Name}: port $stopPort is still listening."
        return
    }

    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $portFile -Force -ErrorAction SilentlyContinue

    Write-Host "  stopped $Name"
}

function Start-All {
    param(
        [switch]$Launch,
        [switch]$Clean,
        [switch]$Restore
    )

    Validate-DotnetForStart
    $allProjectNames = @($Projects | ForEach-Object { $_.Name })
    $startOrder = @(Resolve-StartOrder -Roots $allProjectNames)
    $startResults = New-Object 'System.Collections.Generic.List[object]'

    Write-Host "Using dotnet command: $DotnetCmd"
    Write-Host "Using dotnet version: $ActiveDotnetVersion"
    Write-Host "Using BUILD_CONFIGURATION=$BuildConfiguration"
    Write-Host "Using ASPNETCORE_ENVIRONMENT=$AspNetCoreEnvironment"
    Write-Host "Using DEV_PORT_OFFSET=$DevPortOffset"
    Write-Host "Starting projects in dependency order: $($startOrder -join ', ')"

    for ($i = 0; $i -lt $startOrder.Count; $i++) {
        $project = Get-Project -Name $startOrder[$i]
        if ($null -eq $project) {
            throw "Unknown project in start order: $($startOrder[$i])"
        }

        $startResult = Start-Project -Name $project.Name -RelPath $project.RelPath -BasePort $project.BasePort -Clean:$Clean -Restore:$Restore
        if ($null -ne $startResult) {
            $startResults.Add($startResult) | Out-Null
        }

        if ($i -lt ($startOrder.Count - 1)) {
            Start-Sleep -Seconds $StartDelaySeconds
        }
    }

    Invoke-LaunchScalarBrowsers -StartResults $startResults.ToArray() -Launch:$Launch

    Write-Host "All start commands have been issued."
    Write-Host "Tail logs with: .\\manage.ps1 logs <project> -Tail"
}

function Start-One {
    param(
        [string]$ProjectName,
        [switch]$Launch,
        [switch]$Clean,
        [switch]$Restore
    )

    Validate-DotnetForStart

    $project = Get-Project -Name $ProjectName
    if ($null -eq $project) {
        throw "Unknown project: $ProjectName"
    }

    Write-Host "Using dotnet command: $DotnetCmd"
    Write-Host "Using dotnet version: $ActiveDotnetVersion"
    Write-Host "Using BUILD_CONFIGURATION=$BuildConfiguration"
    Write-Host "Using ASPNETCORE_ENVIRONMENT=$AspNetCoreEnvironment"
    Write-Host "Using DEV_PORT_OFFSET=$DevPortOffset"

    $startOrder = @(Resolve-StartOrder -Roots @($ProjectName))
    Write-Host "Starting projects in dependency order: $($startOrder -join ', ')"
    $startResults = New-Object 'System.Collections.Generic.List[object]'

    for ($i = 0; $i -lt $startOrder.Count; $i++) {
        $resolvedProject = Get-Project -Name $startOrder[$i]
        if ($null -eq $resolvedProject) {
            throw "Unknown project in start order: $($startOrder[$i])"
        }

        $startResult = Start-Project -Name $resolvedProject.Name -RelPath $resolvedProject.RelPath -BasePort $resolvedProject.BasePort -Clean:$Clean -Restore:$Restore
        if ($null -ne $startResult) {
            $startResults.Add($startResult) | Out-Null
        }

        if ($i -lt ($startOrder.Count - 1)) {
            Start-Sleep -Seconds $StartDelaySeconds
        }
    }

    Invoke-LaunchScalarBrowsers -StartResults $startResults.ToArray() -Launch:$Launch
}

function Stop-All {
    Write-Host "Stopping projects in loaded order: $(Get-ProjectNamesCsv)"

    foreach ($project in $Projects) {
        Stop-Project -Name $project.Name
    }

    Write-Host "Stop command completed."
}

function Stop-One {
    param([string]$ProjectName)

    $project = Get-Project -Name $ProjectName
    if ($null -eq $project) {
        throw "Unknown project: $ProjectName"
    }

    Stop-Project -Name $ProjectName
}

function Sync-ProjectTracking {
    param(
        [string]$ProjectName,
        [switch]$Quiet
    )

    $project = Get-Project -Name $ProjectName
    if ($null -eq $project) {
        return $false
    }

    $pidFile = Join-Path $PidDir "$ProjectName.pid"
    $portFile = Join-Path $PidDir "$ProjectName.port"
    $trackedPort = ""
    $candidatePort = $null

    if (Test-Path -LiteralPath $portFile) {
        $trackedPort = (Get-Content -LiteralPath $portFile -Raw -ErrorAction SilentlyContinue).Trim()
    }

    $trackedPortNumber = 0
    if ([int]::TryParse($trackedPort, [ref]$trackedPortNumber) -and (Test-PortInUse -Port $trackedPortNumber)) {
        $candidatePort = $trackedPortNumber
    } elseif (Test-PortInUse -Port $project.BasePort) {
        $candidatePort = [int]$project.BasePort
    }

    if ($null -ne $candidatePort) {
        Set-Content -LiteralPath $portFile -Value $candidatePort -NoNewline
        $runtimePid = Get-ListeningPidForPort -Port $candidatePort
        if ($null -ne $runtimePid) {
            Set-Content -LiteralPath $pidFile -Value ([int]$runtimePid) -NoNewline
            if (-not $Quiet) {
                Write-Host "Reconciled ${ProjectName}: pid $runtimePid, port $candidatePort"
            }
        } else {
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
            if (-not $Quiet) {
                Write-Host "Reconciled ${ProjectName}: port $candidatePort is listening, pid unresolved"
            }
        }
        return $true
    }

    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $portFile -Force -ErrorAction SilentlyContinue
    if (-not $Quiet) {
        Write-Host "Reconciled ${ProjectName}: no listener found, cleared tracking"
    }
    return $false
}

function Start-Group {
    param(
        [string]$GroupName,
        [switch]$Launch,
        [switch]$Clean,
        [switch]$Restore
    )

    $group = Get-Group -Name $GroupName
    if ($null -eq $group) {
        throw "Unknown target: $GroupName"
    }

    Validate-DotnetForStart

    Write-Host "Using dotnet command: $DotnetCmd"
    Write-Host "Using dotnet version: $ActiveDotnetVersion"
    Write-Host "Using BUILD_CONFIGURATION=$BuildConfiguration"
    Write-Host "Using ASPNETCORE_ENVIRONMENT=$AspNetCoreEnvironment"
    Write-Host "Using DEV_PORT_OFFSET=$DevPortOffset"

    $startOrder = @(Resolve-StartOrder -Roots @($group.Members))
    Write-Host "Starting projects in dependency order: $($startOrder -join ', ')"
    $startResults = New-Object 'System.Collections.Generic.List[object]'

    for ($i = 0; $i -lt $startOrder.Count; $i++) {
        $project = Get-Project -Name $startOrder[$i]
        if ($null -eq $project) {
            throw "Unknown project in start order: $($startOrder[$i])"
        }

        $startResult = Start-Project -Name $project.Name -RelPath $project.RelPath -BasePort $project.BasePort -Clean:$Clean -Restore:$Restore
        if ($null -ne $startResult) {
            $startResults.Add($startResult) | Out-Null
        }

        if ($i -lt ($startOrder.Count - 1)) {
            Start-Sleep -Seconds $StartDelaySeconds
        }
    }

    Invoke-LaunchScalarBrowsers -StartResults $startResults.ToArray() -Launch:$Launch
}

function Stop-Group {
    param([string]$GroupName)

    $group = Get-Group -Name $GroupName
    if ($null -eq $group) {
        throw "Unknown target: $GroupName"
    }

    foreach ($member in $group.Members) {
        Stop-One -ProjectName $member
    }
}

$isGitConfigureCommand = (($Command.ToLowerInvariant() -eq "git") -and ($Target.ToLowerInvariant() -eq "configure"))
$isGitHelpCommand = (($Command.ToLowerInvariant() -eq "git") -and ($Target.ToLowerInvariant() -eq "help"))
$isGitBranchHelpCommand = (($Command.ToLowerInvariant() -eq "git") -and ($Target.ToLowerInvariant() -eq "branch") -and ($args.Count -ge 1) -and ($args[0].ToLowerInvariant() -eq "help"))
$isShorthandCommand = ($Command.ToLowerInvariant() -eq "shorthand")
if (($Command.ToLowerInvariant() -ne "generate") -and ($Command.ToLowerInvariant() -ne "new") -and ($Command.ToLowerInvariant() -ne "regenerate") -and (-not $isGitConfigureCommand) -and (-not $isGitHelpCommand) -and (-not $isGitBranchHelpCommand) -and (-not $isShorthandCommand)) {
    if (Test-Path -LiteralPath $StackFile) {
        Load-StackDefinition
    } elseif ($Command -in @("help", "-h", "--help")) {
        $Projects = @()
        $Groups = @()
        $Clients = @()
        $ProjectDependencies = @{}
    } else {
        throw "Stack file not found: $StackFile. Run .\manage.ps1 generate"
    }
}

try {
    switch ($Command.ToLowerInvariant()) {
        "generate" {
            Generate-StackFile -OutputPath $Target
        }
        "regenerate" {
            Generate-StackFile -OutputPath $Target
        }
        "new" {
            if ($Target -eq "all") {
                throw "Usage: .\manage.ps1 new <api|client> <projectname> [--with-client] [--path <path>] [--no-parent]"
            }

            Invoke-NewProjectCommand -TemplateKind $Target.ToLowerInvariant() -RawArgs $args
        }
        "add" {
            if ($Target -ne "instructions") {
                throw "Unknown add subcommand: $Target (expected 'instructions')"
            }

            Add-InstructionsCommand -RawArgs $args
        }
        "update" {
            if ($Target -ne "instructions") {
                throw "Unknown update subcommand: $Target (expected 'instructions')"
            }

            Update-InstructionsCommand -RawArgs $args
        }
        "run" {
            if ($Target -ne "tests") {
                throw "Unknown run subcommand: $Target (expected 'tests')"
            }

            Run-TestsCommand -RawArgs $args
        }
        "shorthand" {
            $shorthandOptions = Get-ShorthandOptions -TargetValue $Target -RawArgs @($args)
            Configure-ManageShorthand -AliasName $shorthandOptions.AliasName -Persist:$shorthandOptions.Persist
        }
        "start" {
            $startTarget = $Target
            $startRawArgs = @($args)
            if ($startTarget.StartsWith("--")) {
                $startRawArgs = @($startTarget) + $startRawArgs
                $startTarget = "all"
            }

            $startOptions = Get-StartOptions -RawArgs $startRawArgs

            if ($startTarget -eq "all") {
                Start-All -Launch:$startOptions.Launch -Clean:$startOptions.Clean -Restore:$startOptions.Restore
            } elseif ($null -ne (Get-Group -Name $startTarget)) {
                Start-Group -GroupName $startTarget -Launch:$startOptions.Launch -Clean:$startOptions.Clean -Restore:$startOptions.Restore
            } else {
                Start-One -ProjectName $startTarget -Launch:$startOptions.Launch -Clean:$startOptions.Clean -Restore:$startOptions.Restore
            }
        }
        "stop" {
            if ($Target -eq "all") {
                Stop-All
            } elseif ($null -ne (Get-Group -Name $Target)) {
                Stop-Group -GroupName $Target
            } else {
                Stop-One -ProjectName $Target
            }
        }
        "help" {
            Show-Usage
        }
        "list" {
            Show-ProjectTable
        }
        "nuget" {
            if ($Target -eq "build") {
                if ($args.Count -gt 0) {
                    Build-NugetPackages -TargetName $args[0]
                } else {
                    Build-NugetPackages -TargetName "all"
                }
            } elseif ($Target -eq "list") {
                Show-Clients
            } else {
                throw "Unknown nuget subcommand: $Target (expected 'build' or 'list')"
            }
        }
        "logs" {
            Show-Logs -ProjectName $Target -Tail:$Tail
        }
        "logging" {
            if ($Target -eq "stream") {
                Invoke-LoggingStreamCommand -RawArgs @($args)
            } else {
                throw "Unknown logging subcommand: $Target (expected 'stream')"
            }
        }
        "-h" {
            Show-Usage
        }
        "--help" {
            Show-Usage
        }
        "upgrade" {
            if ($args.Count -ge 2) {
                Upgrade-DotnetProject -DotnetVersion $args[0] -ProjectName $args[1]
            } else {
                throw "Usage: upgrade <version> <project>"
            }
        }
        "git" {
            if ($Target -eq "sync") {
                if ($args.Count -ge 1 -and ($args[0] -in @("--help", "-h", "help"))) {
                    Write-Host "Usage: .\\manage.ps1 git sync [branch]"
                    break
                }

                $branch = if ($args.Count -ge 1 -and -not [string]::IsNullOrWhiteSpace($args[0])) { [string]$args[0] } else { "" }
                Sync-GitRepositories -Branch $branch
            } elseif ($Target -eq "configure") {
                if ($args.Count -ge 1 -and ($args[0] -in @("--help", "-h", "help"))) {
                    Write-Host "Usage: .\\manage.ps1 git configure"
                    break
                }

                Configure-GitHubAuthentication
            } elseif ($Target -eq "branch") {
                Invoke-GitBranchCommand -RawArgs @($args)
            } elseif ($Target -eq "help") {
                Show-GitHelp
            } else {
                throw "Unknown git subcommand: $Target (expected 'sync', 'configure', 'branch', or 'help')"
            }
        }
        default {
            throw "Unknown command: $Command"
        }
    }
} catch {
    Write-Host $_.Exception.Message
    Show-Usage
    exit 1
}
