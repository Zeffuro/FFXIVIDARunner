[CmdletBinding()]
param(
    [string]$Config,
    [switch]$PreflightOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-Setting {
    param([object]$Object, [string]$Name, $Default)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Resolve-ConfigPathValue {
    param([string]$Value, [string]$BaseDirectory)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($Value)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $expanded))
}

function Assert-LeafPath {
    param([string]$Path, [string]$Description)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description was not found: $Path"
    }
}

function Assert-DirectoryPath {
    param([string]$Path, [string]$Description)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Description was not found: $Path"
    }
}

function Invoke-Native {
    param([string]$FilePath, [string[]]$ArgumentList)
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($ArgumentList -join ' ')"
    }
}

function Get-GitText {
    param([string]$Repository, [string[]]$ArgumentList)
    $result = & git -C $Repository @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed in $Repository`: git $($ArgumentList -join ' ')"
    }
    return ($result | Out-String).Trim()
}

function Assert-CleanTrackedWorktree {
    param([string]$Repository, [string]$Branch)
    $currentBranch = Get-GitText $Repository @('branch', '--show-current')
    if ($currentBranch -ne $Branch) {
        throw "Expected $Repository to be on '$Branch', but it is on '$currentBranch'."
    }
    $changes = Get-GitText $Repository @('status', '--porcelain', '--untracked-files=no')
    if ($changes) {
        throw "Tracked local changes make an automatic update unsafe in $Repository`n$changes"
    }
}

function Update-RepositoryFastForward {
    param([string]$Repository, [string]$Remote, [string]$Branch)
    Assert-CleanTrackedWorktree $Repository $Branch
    Invoke-Native git @('-C', $Repository, 'fetch', '--prune', $Remote, $Branch)
    Invoke-Native git @('-C', $Repository, 'merge', '--ff-only', "$Remote/$Branch")
}

function Write-JsonFile {
    param([object]$Value, [string]$Path)
    $Value | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $Path -Encoding UTF8
}

. (Join-Path $PSScriptRoot 'ClientStructs.ps1')

$selectedConfig = $Config
if ([string]::IsNullOrWhiteSpace($selectedConfig)) {
    $selectedConfig = [Environment]::GetEnvironmentVariable('FFXIV_IDA_RUNNER_CONFIG', 'Process')
}
if ([string]::IsNullOrWhiteSpace($selectedConfig)) {
    $selectedConfig = Join-Path $PSScriptRoot 'config.json'
} elseif (-not [System.IO.Path]::IsPathRooted($selectedConfig)) {
    $selectedConfig = Join-Path (Get-Location) $selectedConfig
}
$selectedConfig = [System.IO.Path]::GetFullPath($selectedConfig)
Assert-LeafPath $selectedConfig 'Config file'
$configDirectory = Split-Path -Parent $selectedConfig
$settings = Get-Content -LiteralPath $selectedConfig -Raw | ConvertFrom-Json

$paths = Get-Setting $settings 'paths' $null
$repositories = Get-Setting $settings 'repositories' $null
$stages = Get-Setting $settings 'stages' $null
$idaSettings = Get-Setting $settings 'ida' $null
$clientSettings = Get-Setting $settings 'client_structs' $null
$extraPassSettings = Get-Setting $settings 'extra_pass' $null
$backupSettings = Get-Setting $settings 'backup' $null

$gameExecutable = Resolve-ConfigPathValue (Get-Setting $paths 'game_executable' '') $configDirectory
$idaExecutable = Resolve-ConfigPathValue (Get-Setting $paths 'ida_executable' '') $configDirectory
$clientRepository = Resolve-ConfigPathValue (Get-Setting $paths 'client_structs_repository' '') $configDirectory
$commentsRepository = Resolve-ConfigPathValue (Get-Setting $paths 'comments_repository' '') $configDirectory
Assert-LeafPath $gameExecutable 'Game executable'
Assert-LeafPath $idaExecutable 'IDA executable'
$gameDirectory = Split-Path -Parent $gameExecutable

$sqpackDirectory = Resolve-ConfigPathValue (Get-Setting $paths 'sqpack_directory' '') $configDirectory
if (-not $sqpackDirectory) { $sqpackDirectory = Join-Path $gameDirectory 'sqpack' }
$databasePath = Resolve-ConfigPathValue (Get-Setting $paths 'database_output' '') $configDirectory
if (-not $databasePath) { $databasePath = "$gameExecutable.i64" }
$cOutputPath = Resolve-ConfigPathValue (Get-Setting $paths 'c_output' '') $configDirectory
if (-not $cOutputPath) { $cOutputPath = "$gameExecutable.c" }
$backupRoot = Resolve-ConfigPathValue (Get-Setting $paths 'backup_directory' '') $configDirectory
if (-not $backupRoot) { $backupRoot = Join-Path $gameDirectory 'ida-history' }
$runRoot = Resolve-ConfigPathValue (Get-Setting $paths 'run_log_directory' '') $configDirectory
if (-not $runRoot) { $runRoot = Join-Path $PSScriptRoot 'runs' }

$updateClient = [bool](Get-Setting $repositories 'update_client_structs' $true)
$clientRemote = [string](Get-Setting $repositories 'client_structs_remote' 'origin')
$clientBranch = [string](Get-Setting $repositories 'client_structs_branch' 'main')
$updateComments = [bool](Get-Setting $repositories 'update_comments' $false)
$commentsRemote = [string](Get-Setting $repositories 'comments_remote' 'origin')
$commentsBranch = [string](Get-Setting $repositories 'comments_branch' 'main')

$runExtraPass = [bool](Get-Setting $stages 'extra_pass' $true)
$runClientStructs = [bool](Get-Setting $stages 'client_structs' $true)
$generateCFile = [bool](Get-Setting $stages 'generate_c_file' $true)
$exportComments = [bool](Get-Setting $stages 'export_comments' $false)
$applyComments = [bool](Get-Setting $stages 'apply_comments' $false)
$idaVisible = [bool](Get-Setting $idaSettings 'visible' $false)
$idaUserDirectory = [string](Get-Setting $idaSettings 'user_directory' '')
if ([string]::IsNullOrWhiteSpace($idaUserDirectory)) {
    $idaUserDirectory = [Environment]::GetEnvironmentVariable('IDAUSR', 'Process')
}
$idaUserDirectories = @()
if ($idaUserDirectory) {
    $idaUserDirectories = @($idaUserDirectory -split ';' | ForEach-Object { Resolve-ConfigPathValue $_ $configDirectory })
}
$completionSound = [bool](Get-Setting $settings 'completion_sound' $false)

$imageBaseName = [string](Get-Setting $clientSettings 'image_base_name' 'ffxiv_dx11.exe')
$importer = ([string](Get-Setting $clientSettings 'importer' 'srclang')).ToLowerInvariant()
$padding = ([string](Get-Setting $clientSettings 'padding' 'full')).ToLowerInvariant()
$updateMemberTypes = [bool](Get-Setting $clientSettings 'update_member_function_types' $true)
$updateVirtualTypes = [bool](Get-Setting $clientSettings 'update_virtual_function_types' $true)
$syncIdaUserConfig = [bool](Get-Setting $clientSettings 'sync_idauser_cfg' $true)
$generateStructs = [bool](Get-Setting $clientSettings 'generate_structs' $true)
$msvcIncludeDirectory = Resolve-ConfigPathValue (Get-Setting $clientSettings 'msvc_include_directory' '') $configDirectory
if ($msvcIncludeDirectory) { Assert-LeafPath (Join-Path $msvcIncludeDirectory 'vector') 'MSVC include directory' }

$extraPassMode = ([string](Get-Setting $extraPassSettings 'mode' 'configured')).ToLowerInvariant()
$extraPassMaxRuns = [int](Get-Setting $extraPassSettings 'max_runs' 5)
$backupEnabled = [bool](Get-Setting $backupSettings 'enabled' $true)
$backupDatabase = [bool](Get-Setting $backupSettings 'include_database' $true)
$backupCFile = [bool](Get-Setting $backupSettings 'include_c_file' $true)

Write-Step 'Checking config'
$pipelineScript = Join-Path $PSScriptRoot 'ida_pipeline.py'
Assert-LeafPath $pipelineScript 'IDA pipeline'
if ($runClientStructs -or $updateClient) { Assert-DirectoryPath $clientRepository 'FFXIVClientStructs repository' }
if ($applyComments -or $exportComments -or $updateComments) { Assert-DirectoryPath $commentsRepository 'FFXIVIDAComments repository' }
if ($exportComments) { Assert-DirectoryPath $sqpackDirectory 'sqpack directory' }
if ($imageBaseName -notin @('ffxiv_dx11.exe', '__ImageBase')) { throw "client_structs.image_base_name must be 'ffxiv_dx11.exe' or '__ImageBase'." }
if ($importer -notin @('srclang', 'legacy')) { throw "client_structs.importer must be 'srclang' or 'legacy'." }
if ($padding -notin @('full', 'array')) { throw "client_structs.padding must be 'full' or 'array'." }
if ($importer -eq 'srclang' -and $padding -ne 'full') { throw "SrcLang always uses full padding. Choose the legacy importer for array padding." }
if ($extraPassMode -notin @('configured', 'interactive')) { throw "extra_pass.mode must be 'configured' or 'interactive'." }
if ($extraPassMaxRuns -lt 1 -or $extraPassMaxRuns -gt 10) { throw 'extra_pass.max_runs must be between 1 and 10.' }
if ($runExtraPass -and $extraPassMode -eq 'interactive' -and -not $idaVisible) { throw 'Interactive ExtraPass options require ida.visible to be true.' }
if ($runExtraPass) {
    $extraPassCandidates = @(
        (Join-Path (Split-Path -Parent $idaExecutable) 'plugins\IDA_ExtraPass_PlugIn.dll')
    )
    $pluginUserDirectories = if ($idaUserDirectories.Count) { $idaUserDirectories } else { @(Join-Path $env:APPDATA 'Hex-Rays\IDA Pro') }
    foreach ($userDirectory in $pluginUserDirectories) {
        $extraPassCandidates += Join-Path $userDirectory 'plugins\IDA_ExtraPass_PlugIn.dll'
    }
    if (-not ($extraPassCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)) {
        throw 'ExtraPass is enabled, but IDA_ExtraPass_PlugIn.dll was not found in the IDA or user plugin folder.'
    }
}
if ($exportComments -and -not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'FFXIVIDAComments export is enabled, but dotnet was not found.'
}

$runningIda = @(Get-Process -Name ida, idat -ErrorAction SilentlyContinue)
if ($runningIda.Count -gt 0) {
    $descriptions = $runningIda | ForEach-Object { "PID $($_.Id) '$($_.MainWindowTitle)'" }
    throw "Close all IDA instances first: $($descriptions -join ', ')"
}

if ($updateClient) { Assert-CleanTrackedWorktree $clientRepository $clientBranch }
if ($updateComments) { Assert-CleanTrackedWorktree $commentsRepository $commentsBranch }

$clientLayout = $null
if ($runClientStructs) {
    $clientLayout = Resolve-ClientStructsLayout $clientRepository $importer $padding
    if ($syncIdaUserConfig) { Assert-LeafPath $clientLayout.ConfigPath 'FFXIVClientStructs idauser.cfg' }
    if ($PreflightOnly -or -not $updateClient) {
        Test-ClientStructsPrerequisites $clientLayout $clientRepository $generateStructs $gameDirectory
    }
}

Write-Host "Config:          $selectedConfig"
Write-Host "Executable:      $gameExecutable"
Write-Host "Database output: $databasePath"
if ($generateCFile) { Write-Host "C output:        $cOutputPath" }
Write-Host "IDA visible:     $idaVisible"
Write-Host "Stages:          ExtraPass=$runExtraPass ClientStructs=$runClientStructs C=$generateCFile Comments=$applyComments"
Write-Host "Backups:         $backupEnabled"
if ($clientLayout) { Write-Host "CS scripts:      $($clientLayout.Layout)" }

if ($PreflightOnly) {
    Write-Host "`nPreflight completed successfully." -ForegroundColor Green
    return
}

$outputParents = @((Split-Path -Parent $databasePath), $runRoot)
if ($generateCFile) { $outputParents += Split-Path -Parent $cOutputPath }
foreach ($parent in $outputParents) {
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
}
$databaseDrive = Get-PSDrive -Name ([System.IO.Path]::GetPathRoot($databasePath).TrimEnd(':', '\'))
if ($databaseDrive.Free -lt 5GB) { throw 'The database drive has less than 5 GB free.' }

$exeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $gameExecutable).Hash.ToLowerInvariant()
$runId = '{0}_{1}' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'), $exeHash.Substring(0, 12)
$runDirectory = Join-Path $runRoot $runId
$rollbackDirectory = Join-Path $runDirectory 'rollback'
$failedDirectory = Join-Path $runDirectory 'failed-partial-output'
$pipelineConfigPath = Join-Path $runDirectory 'pipeline-config.json'
$statusPath = Join-Path $runDirectory 'pipeline-status.json'
$idaLogPath = Join-Path $runDirectory 'ida.log'
$metadataPath = Join-Path $runDirectory 'run.json'
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null

$datedBackupDirectory = $null
if ($backupEnabled) {
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $datedBackupDirectory = Join-Path $backupRoot (Get-Date -Format 'yyyy-MM-dd')
    if (Test-Path -LiteralPath $datedBackupDirectory) {
        $datedBackupDirectory = Join-Path $backupRoot (Get-Date -Format 'yyyy-MM-dd_HHmmss')
    }
    New-Item -ItemType Directory -Path $datedBackupDirectory -Force | Out-Null
}

$runMetadata = [ordered]@{
    run_id = $runId
    state = 'preparing'
    started_at = (Get-Date).ToString('o')
    config = $selectedConfig
    executable_path = $gameExecutable
    executable_sha256 = $exeHash
    database_path = $databasePath
    c_output_path = if ($generateCFile) { $cOutputPath } else { $null }
    backup_directory = $datedBackupDirectory
    client_structs_commit = $null
    client_structs_layout = $null
    comments_commit = $null
    ida_started_at = $null
    ida_exited_at = $null
    ida_process_elapsed_seconds = $null
    analysis_process_elapsed_seconds = $null
    analysis_log_path = $null
    ida_exit_code = $null
    post_pipeline_exit_seconds = $null
    completed_at = $null
    failed_at = $null
    error = $null
    pipeline_result = $null
}
Write-JsonFile $runMetadata $metadataPath
$artifactEntries = @()
$pipelineStarted = $false

try {
    if ($updateClient) {
        Write-Step "Updating FFXIVClientStructs from $clientRemote/$clientBranch"
        Update-RepositoryFastForward $clientRepository $clientRemote $clientBranch
    }
    if ($updateComments) {
        Write-Step "Updating FFXIVIDAComments from $commentsRemote/$commentsBranch"
        Update-RepositoryFastForward $commentsRepository $commentsRemote $commentsBranch
    }
    if ($clientRepository) { $runMetadata.client_structs_commit = Get-GitText $clientRepository @('rev-parse', 'HEAD') }
    if ($commentsRepository) { $runMetadata.comments_commit = Get-GitText $commentsRepository @('rev-parse', 'HEAD') }

    $clientStructsScript = $null
    if ($runClientStructs) {
        $clientLayout = Resolve-ClientStructsLayout $clientRepository $importer $padding
        Test-ClientStructsPrerequisites $clientLayout $clientRepository $generateStructs $gameDirectory
        Write-Step "Preparing ClientStructs ($($clientLayout.Layout))"
        Prepare-ClientStructs $clientLayout $clientRepository $generateStructs
        $clientStructsScript = $clientLayout.ScriptPath
        $runMetadata.client_structs_layout = $clientLayout.Layout
    }
    $commentsScript = if ($applyComments) { Join-Path $commentsRepository 'ffxiv_comments.py' } else { $null }
    if ($applyComments) { Assert-LeafPath $commentsScript 'FFXIV comments script' }

    if ($runClientStructs -and $syncIdaUserConfig) {
        Write-Step 'Updating idauser.cfg'
        $sourceConfig = $clientLayout.ConfigPath
        Assert-LeafPath $sourceConfig 'FFXIVClientStructs idauser.cfg'
        $userConfigDirectory = if ($idaUserDirectories.Count) { $idaUserDirectories[0] } else { Join-Path $env:APPDATA 'Hex-Rays\IDA Pro' }
        $userConfig = Join-Path $userConfigDirectory 'idauser.cfg'
        New-Item -ItemType Directory -Path $userConfigDirectory -Force | Out-Null
        if ((Test-Path -LiteralPath $userConfig) -and ((Get-FileHash $sourceConfig).Hash -ne (Get-FileHash $userConfig).Hash)) {
            Copy-Item -LiteralPath $userConfig -Destination (Join-Path $runDirectory 'idauser.cfg.previous')
        }
        Copy-Item -LiteralPath $sourceConfig -Destination $userConfig -Force
    }

    if ($exportComments) {
        Write-Step 'Exporting FFXIVIDAComments data'
        $exporterProject = Join-Path $commentsRepository 'Exporter.csproj'
        Assert-LeafPath $exporterProject 'Comments exporter project'
        Push-Location $commentsRepository
        try { Invoke-Native dotnet @('run', '--project', $exporterProject, '--', '--path', $sqpackDirectory) }
        finally { Pop-Location }
    }

    Write-Step 'Preparing output files'
    $artifactSpecs = @([pscustomobject]@{ Path = $databasePath; Keep = ($backupEnabled -and $backupDatabase) })
    if ($generateCFile) {
        $artifactSpecs += [pscustomobject]@{ Path = $cOutputPath; Keep = ($backupEnabled -and $backupCFile) }
    }
    foreach ($spec in $artifactSpecs) {
        if (Test-Path -LiteralPath $spec.Path -PathType Leaf) {
            $destinationDirectory = if ($spec.Keep) { $datedBackupDirectory } else { $rollbackDirectory }
            New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
            $destination = Join-Path $destinationDirectory ([System.IO.Path]::GetFileName($spec.Path))
            Move-Item -LiteralPath $spec.Path -Destination $destination
            $artifactEntries += [pscustomobject]@{ Source = $spec.Path; Stored = $destination; Keep = $spec.Keep }
            Write-Host "Moved: $($spec.Path)"
        }
    }

    $pipelineConfig = [ordered]@{
        status_path = $statusPath
        c_output_path = $cOutputPath
        client_structs_script = $clientStructsScript
        client_structs_layout = if ($runClientStructs) { $clientLayout.Layout } else { $null }
        game_directory = $gameDirectory
        comments_script = $commentsScript
        stages = [ordered]@{
            extra_pass = $runExtraPass
            client_structs = $runClientStructs
            generate_c_file = $generateCFile
            apply_comments = $applyComments
        }
        client_structs = [ordered]@{
            image_base_name = $imageBaseName
            importer = $importer
            padding = $padding
            update_member_function_types = $updateMemberTypes
            update_virtual_function_types = $updateVirtualTypes
            msvc_include_directory = $msvcIncludeDirectory
        }
        extra_pass = [ordered]@{
            mode = $extraPassMode
            max_runs = $extraPassMaxRuns
            convert_unknown_data = [bool](Get-Setting $extraPassSettings 'convert_unknown_data' $false)
            fix_align_blocks = [bool](Get-Setting $extraPassSettings 'fix_align_blocks' $true)
            fix_missing_code = [bool](Get-Setting $extraPassSettings 'fix_missing_code' $true)
            fix_missing_functions = [bool](Get-Setting $extraPassSettings 'fix_missing_functions' $true)
            fix_noncontiguous_functions = [bool](Get-Setting $extraPassSettings 'fix_noncontiguous_functions' $true)
            play_sound = [bool](Get-Setting $extraPassSettings 'play_sound' $false)
        }
    }
    Write-JsonFile $pipelineConfig $pipelineConfigPath
    $runMetadata.state = 'running'
    Write-JsonFile $runMetadata $metadataPath

    Write-Step 'Starting IDA'
    Write-Host "Log: $idaLogPath"
    $oldPipelineConfig = [Environment]::GetEnvironmentVariable('_FFXIV_IDA_PIPELINE_CONFIG', 'Process')
    $oldIdaUser = [Environment]::GetEnvironmentVariable('IDAUSR', 'Process')
    $pipelineStarted = $true
    $idaProcess = $null
    $pipelineStatus = $null
    $idaStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $runMetadata.ida_started_at = (Get-Date).ToString('o')
    Write-JsonFile $runMetadata $metadataPath
    try {
        [Environment]::SetEnvironmentVariable('_FFXIV_IDA_PIPELINE_CONFIG', $pipelineConfigPath, 'Process')
        if ($idaUserDirectory) {
            [Environment]::SetEnvironmentVariable('IDAUSR', ($idaUserDirectories -join ';'), 'Process')
        }
        $windowStyle = if ($idaVisible) { 'Normal' } else { 'Hidden' }
        $idaInputPath = $gameExecutable
        for ($launch = 0; $launch -lt 2; $launch++) {
            $idaArguments = @('-A', '-Opdb:off', ('-L"{0}"' -f $idaLogPath))
            if ($launch -eq 0) { $idaArguments += '-o"{0}"' -f $databasePath }
            $idaArguments += @(
                ('-S"{0}"' -f $pipelineScript),
                ('"{0}"' -f $idaInputPath)
            )
            $idaProcess = $null
            $idaProcess = Start-Process -FilePath $idaExecutable -ArgumentList $idaArguments -WorkingDirectory $runDirectory -WindowStyle $windowStyle -PassThru -Wait
            if ($idaProcess.ExitCode -ne 0) { throw "IDA exited with code $($idaProcess.ExitCode). See $idaLogPath" }
            Assert-LeafPath $statusPath 'Pipeline status'
            $pipelineStatus = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            $restartRequired = Get-Setting $pipelineStatus 'restart_required' $false
            if ($restartRequired -isnot [bool]) { throw 'Pipeline restart_required must be a JSON boolean.' }
            if (-not $restartRequired) { break }
            if ($launch -ne 0) { throw 'IDA requested more than one analysis restart.' }
            if ((Get-Setting $pipelineStatus 'state' '') -cne 'complete' -or
                (Get-Setting $pipelineStatus 'stage' '') -cne 'analysis_complete') {
                throw 'IDA returned an incomplete analysis checkpoint.'
            }
            $checkpointDatabase = [string](Get-Setting $pipelineStatus 'database_path' '')
            if (-not [System.IO.Path]::IsPathRooted($checkpointDatabase) -or
                -not [string]::Equals([System.IO.Path]::GetFullPath($checkpointDatabase), $databasePath, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The analysis checkpoint database does not match the configured output.'
            }
            Assert-LeafPath $databasePath 'Analyzed database'
            Assert-LeafPath $idaLogPath 'Analysis log'
            $runMetadata.analysis_process_elapsed_seconds = [math]::Round($idaStopwatch.Elapsed.TotalSeconds, 2)
            $runMetadata.analysis_log_path = Join-Path $runDirectory 'analysis.log'
            Move-Item -LiteralPath $idaLogPath -Destination $runMetadata.analysis_log_path
            $pipelineConfig['analysis_checkpoint'] = $pipelineStatus
            Write-JsonFile $pipelineConfig $pipelineConfigPath
            $idaInputPath = $databasePath
            Write-Step 'Reopening analyzed database'
        }
    } finally {
        [Environment]::SetEnvironmentVariable('_FFXIV_IDA_PIPELINE_CONFIG', $oldPipelineConfig, 'Process')
        [Environment]::SetEnvironmentVariable('IDAUSR', $oldIdaUser, 'Process')
        $idaStopwatch.Stop()
        $runMetadata.ida_exited_at = (Get-Date).ToString('o')
        $runMetadata.ida_process_elapsed_seconds = [math]::Round($idaStopwatch.Elapsed.TotalSeconds, 2)
        if ($null -ne $idaProcess) { $runMetadata.ida_exit_code = $idaProcess.ExitCode }
        Write-JsonFile $runMetadata $metadataPath
    }

    if ($pipelineStatus.state -ne 'complete' -or $pipelineStatus.stage -ne 'complete') {
        throw "IDA did not complete. See $idaLogPath"
    }
    $pipelineCompletedAt = [DateTimeOffset]::Parse([string]$pipelineStatus.updated_at)
    $idaExitedAt = [DateTimeOffset]::Parse([string]$runMetadata.ida_exited_at)
    $runMetadata.post_pipeline_exit_seconds = [math]::Round(
        [math]::Max(0, ($idaExitedAt - $pipelineCompletedAt).TotalSeconds),
        2
    )
    Assert-LeafPath $databasePath 'Rebuilt database'
    if ($generateCFile) { Assert-LeafPath $cOutputPath 'Generated C file' }

    foreach ($entry in @($artifactEntries | Where-Object { -not $_.Keep })) {
        if (Test-Path -LiteralPath $entry.Stored -PathType Leaf) { Remove-Item -LiteralPath $entry.Stored -Force }
    }
    if (Test-Path -LiteralPath $rollbackDirectory -PathType Container) { Remove-Item -LiteralPath $rollbackDirectory -Force }

    $runMetadata.state = 'complete'
    $runMetadata.completed_at = (Get-Date).ToString('o')
    $runMetadata.pipeline_result = $pipelineStatus
    Write-JsonFile $runMetadata $metadataPath

    Write-Host "`nDone." -ForegroundColor Green
    Write-Host "Database: $databasePath"
    if ($generateCFile) { Write-Host "C file:   $cOutputPath" }
    if ($datedBackupDirectory) { Write-Host "Backup:   $datedBackupDirectory" }
    Write-Host "Log:      $idaLogPath"
    if ($completionSound) { [System.Media.SystemSounds]::Asterisk.Play() }
} catch {
    $failure = $_
    $runMetadata.state = 'failed'
    $runMetadata.failed_at = (Get-Date).ToString('o')
    $runMetadata.error = $failure.Exception.Message

    if ($pipelineStarted) {
        New-Item -ItemType Directory -Path $failedDirectory -Force | Out-Null
        foreach ($partialPath in @($databasePath, $(if ($generateCFile) { $cOutputPath }))) {
            if ($partialPath -and (Test-Path -LiteralPath $partialPath -PathType Leaf)) {
                Move-Item -LiteralPath $partialPath -Destination (Join-Path $failedDirectory ([System.IO.Path]::GetFileName($partialPath))) -Force
            }
        }
    }
    foreach ($entry in $artifactEntries) {
        if (Test-Path -LiteralPath $entry.Stored -PathType Leaf) {
            if ($entry.Keep) { Copy-Item -LiteralPath $entry.Stored -Destination $entry.Source }
            else { Move-Item -LiteralPath $entry.Stored -Destination $entry.Source }
        }
    }
    Write-JsonFile $runMetadata $metadataPath
    Write-Host "`nFailed. Previous files were restored." -ForegroundColor Red
    throw $failure
}
