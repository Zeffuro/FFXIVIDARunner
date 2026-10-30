function Resolve-ClientStructsLayout {
    param([string]$Repository, [string]$Importer = 'srclang', [string]$Padding = 'full')

    if ($Importer -notin @('srclang', 'legacy')) { throw "client_structs.importer must be 'srclang' or 'legacy'." }
    if ($Padding -notin @('full', 'array')) { throw "client_structs.padding must be 'full' or 'array'." }
    $reworkedScript = Join-Path $Repository 'scripts\ida\full_run.py'
    $legacyScript = Join-Path $Repository 'ida\ffxiv_fullrun_ida.py'
    if (Test-Path -LiteralPath $reworkedScript -PathType Leaf) {
        if ($Importer -ne 'srclang' -or $Padding -ne 'full') {
            throw "The reworked ClientStructs layout requires client_structs.importer='srclang' and padding='full'. Legacy import and array padding are unsupported."
        }
        $layout = 'reworked'
        $scriptPath = $reworkedScript
        $baseDirectory = Join-Path $Repository 'scripts'
        foreach ($script in @('rename.py', 'struct_import.py', 'ida_wrapper.py', 'form_builder.py')) {
            Assert-LeafPath (Join-Path $baseDirectory "ida\$script") 'Required ClientStructs IDA script'
        }
        $sharedDirectory = Join-Path $baseDirectory 'shared'
        if (-not (Test-Path -LiteralPath $sharedDirectory -PathType Container)) {
            throw "ClientStructs shared scripts were not found: $sharedDirectory. Restore the complete scripts directory."
        }
        Assert-LeafPath (Join-Path $baseDirectory 'data.yml') 'ClientStructs data.yml'
    } elseif (Test-Path -LiteralPath $legacyScript -PathType Leaf) {
        if ($Importer -eq 'srclang' -and $Padding -ne 'full') {
            throw 'SrcLang always uses full padding. Choose the legacy importer for array padding.'
        }
        $layout = 'legacy'
        $scriptPath = $legacyScript
        $baseDirectory = Join-Path $Repository 'ida'
    } else {
        throw "ClientStructs entry script was not found. Expected '$reworkedScript' or '$legacyScript'. Restore or update the repository."
    }
    $structPath = Join-Path $baseDirectory 'structs.yml'
    return [pscustomobject]@{
        Layout = $layout
        ScriptPath = $scriptPath
        ConfigPath = Join-Path $baseDirectory 'idauser.cfg'
        DataPath = Join-Path $baseDirectory 'data.yml'
        StructPath = $structPath
        NeedsExport = $layout -eq 'reworked' -and -not (Test-Path -LiteralPath $structPath -PathType Leaf)
    }
}

function Test-ClientStructsDotNet {
    param([bool]$GenerateStructs)

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw 'Reworked ClientStructs requires dotnet and Microsoft.NETCore.App 10. Install the .NET 10 SDK to generate structs.yml, or the .NET 10 runtime when generation is disabled.'
    }
    $runtimes = @(& dotnet --list-runtimes)
    if ($LASTEXITCODE -ne 0 -or -not ($runtimes -match '^Microsoft\.NETCore\.App 10\.')) {
        throw 'Reworked ClientStructs requires Microsoft.NETCore.App 10 for its Python/.NET imports. Install the .NET 10 runtime or SDK.'
    }
    if ($GenerateStructs) {
        $sdks = @(& dotnet --list-sdks)
        $compatible = @($sdks | Where-Object { $_ -match '^(\d+)\.' -and [int]$Matches[1] -ge 10 })
        if ($LASTEXITCODE -ne 0 -or $compatible.Count -eq 0) {
            throw 'Generating ClientStructs structs.yml requires the .NET 10 SDK or newer. Install it, or set client_structs.generate_structs=false and supply scripts\structs.yml.'
        }
    }
}

function Test-ClientStructsPrerequisites {
    param([object]$Layout, [string]$Repository, [bool]$GenerateStructs, [string]$GameDirectory)

    if ($Layout.Layout -ne 'reworked') { return }
    Test-ClientStructsDotNet $GenerateStructs
    if ($GenerateStructs) {
        Assert-LeafPath (Join-Path $Repository 'CExporter\CExporter.csproj') 'ClientStructs CExporter project'
    } else {
        Assert-ClientStructsExport $Layout
    }
    $gameRoot = Split-Path -Parent $GameDirectory
    if ((Split-Path -Leaf $GameDirectory) -ne 'game' -or
        -not (Test-Path -LiteralPath (Join-Path $GameDirectory 'sqpack') -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $gameRoot 'boot') -PathType Container)) {
        throw "Reworked ClientStructs requires an installation containing game\sqpack and boot. The executable's directory is: $GameDirectory"
    }
    $versionPath = Join-Path $GameDirectory 'ffxivgame.ver'
    Assert-LeafPath $versionPath 'Game version file'
    $gameVersion = (Get-Content -LiteralPath $versionPath -Raw).Trim()
    $versionLines = @(Get-Content -LiteralPath $Layout.DataPath | Where-Object { $_ -match '^version\s*:' })
    if ($versionLines.Count -ne 1 -or
        $versionLines[0] -notmatch '^version\s*:\s*[''"]?(?<version>\d{4}\.\d{2}\.\d{2}\.\d{4}\.\d{4})[''"]?\s*(?:#.*)?$') {
        throw "Cannot read a single game version from ClientStructs data.yml: $($Layout.DataPath)"
    }
    $dataVersion = $Matches['version']
    if ($dataVersion -ne $gameVersion) {
        throw "ClientStructs data.yml version '$dataVersion' does not match installed game version '$gameVersion'. Update ClientStructs or use a matching game installation."
    }
}

function Assert-ClientStructsExport {
    param([object]$Layout)

    if (-not (Test-Path -LiteralPath $Layout.StructPath -PathType Leaf)) {
        throw "ClientStructs export was not found: $($Layout.StructPath). Enable client_structs.generate_structs, or run dotnet run --project ..\CExporter\CExporter.csproj --configuration Release -- --quiet from the ClientStructs scripts directory."
    }
    if ((Get-Item -LiteralPath $Layout.StructPath).Length -eq 0) {
        throw "ClientStructs export is empty: $($Layout.StructPath). Regenerate it with CExporter before running IDA."
    }
}

function Prepare-ClientStructs {
    param([object]$Layout, [string]$Repository, [bool]$GenerateStructs)

    if ($Layout.Layout -ne 'reworked') { return }
    if ($GenerateStructs) {
        Test-ClientStructsDotNet $true
        $project = Join-Path $Repository 'CExporter\CExporter.csproj'
        Assert-LeafPath $project 'ClientStructs CExporter project'
        $previousExport = $null
        Push-Location -LiteralPath (Join-Path $Repository 'scripts')
        try {
            if (Test-Path -LiteralPath $Layout.StructPath -PathType Leaf) {
                $previousExport = "$($Layout.StructPath).previous-$([guid]::NewGuid().ToString('N'))"
                Move-Item -LiteralPath $Layout.StructPath -Destination $previousExport
            }
            Invoke-Native dotnet @('run', '--project', $project, '--configuration', 'Release', '--', '--quiet')
            Assert-ClientStructsExport $Layout
        } catch {
            if ($previousExport -and (Test-Path -LiteralPath $previousExport -PathType Leaf)) {
                if (Test-Path -LiteralPath $Layout.StructPath -PathType Leaf) {
                    $failedExport = "$($Layout.StructPath).failed-$([guid]::NewGuid().ToString('N'))"
                    Move-Item -LiteralPath $Layout.StructPath -Destination $failedExport
                    Write-Warning "Preserved failed ClientStructs export: $failedExport"
                }
                Move-Item -LiteralPath $previousExport -Destination $Layout.StructPath
            }
            throw
        } finally {
            Pop-Location
        }
        if ($previousExport) { Remove-Item -LiteralPath $previousExport }
    }
    Assert-ClientStructsExport $Layout
    $Layout.NeedsExport = $false
}
