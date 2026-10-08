[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('convert', 'uv2cmake', 'cmake2uv', 'install', 'generate', 'configure', 'build', 'flash', 'doctor')]
    [string]$Action = 'doctor',
    [string]$ProjectRoot,
    [string]$CMakeProjectDir = 'CMake-GCC',
    [string]$ConfigFile,
    [string]$Project,
    [ValidateSet('keil2cmake', 'cmake2keil', '1', '2')]
    [string]$Direction,
    [string]$Uvprojx,
    [string]$ChipConfig,
    [ValidateSet('Debug', 'Release')]
    [string]$Config = 'Debug',
    [string]$TargetName,
    [ValidateSet('O0', 'O1', 'O2', 'O3', 'Og', 'Os', 'Ofast')]
    [string]$DebugOptimization,
    [ValidateSet('O0', 'O1', 'O2', 'O3', 'Og', 'Os', 'Ofast')]
    [string]$ReleaseOptimization,
    [ValidateSet('armcc5', 'armclang6')]
    [string]$KeilCompiler,
    [ValidateSet('auto', 'cubemx', 'parser')]
    [string]$ConversionBackend,
    [string[]]$ExtraDefines
)

$ErrorActionPreference = 'Stop'
$engine = Join-Path $PSScriptRoot 'scripts/stm32-project.ps1'

$effectiveConfigFile = $ConfigFile
if (-not $effectiveConfigFile) {
    $localConfig = Join-Path $PSScriptRoot 'stm32.local.json'
    $defaultConfig = Join-Path $PSScriptRoot 'stm32.config.json'
    if (Test-Path -LiteralPath $localConfig) { $effectiveConfigFile = $localConfig }
    elseif (Test-Path -LiteralPath $defaultConfig) { $effectiveConfigFile = $defaultConfig }
}

if ($effectiveConfigFile) {
    $configPath = if ([IO.Path]::IsPathRooted($effectiveConfigFile)) {
        [IO.Path]::GetFullPath($effectiveConfigFile)
    } else {
        [IO.Path]::GetFullPath((Join-Path (Get-Location) $effectiveConfigFile))
    }
    if (-not (Test-Path -LiteralPath $configPath)) { throw "Config file not found: $configPath" }
    $rootConfig = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    $configBase = Split-Path -Parent $configPath
    if ($rootConfig.PSObject.Properties.Name -contains 'tools') {
        $toolEnvironment = [ordered]@{
            gccRoot = 'STM32_GCC_ROOT'
            llvmRoot = 'LLVM_ROOT'
            cubeCltRoot = 'STM32_CUBE_CLT_ROOT'
            cubeMxRoot = 'STM32_CUBEMX_ROOT'
            keilRoot = 'KEIL_ROOT'
            jlinkRoot = 'JLINK_ROOT'
        }
        foreach ($entry in $toolEnvironment.GetEnumerator()) {
            if ($rootConfig.tools.PSObject.Properties.Name -notcontains $entry.Key) { continue }
            $configuredPath = [string]$rootConfig.tools.($entry.Key)
            if (-not $configuredPath) { continue }
            $resolvedToolPath = if ([IO.Path]::IsPathRooted($configuredPath)) {
                [IO.Path]::GetFullPath($configuredPath)
            } else {
                [IO.Path]::GetFullPath((Join-Path $configBase $configuredPath))
            }
            [Environment]::SetEnvironmentVariable($entry.Value, $resolvedToolPath, 'Process')
        }
    }
    $fileConfig = $rootConfig
    $configuredAction = if ($PSBoundParameters.ContainsKey('Action')) { $Action } elseif ($rootConfig.action) { [string]$rootConfig.action } else { $Action }
    if ($configuredAction -eq 'convert') {
        if (-not $Direction) {
            Write-Host ''
            Write-Host '请选择工程转换方向：' -ForegroundColor Cyan
            Write-Host '  [1] Keil (.uvprojx) -> CMake-GCC'
            Write-Host '  [2] CMake-GCC -> Keil (.uvprojx)'
            do {
                $directionSelection = (Read-Host '请选择转换方向').Trim()
                if ($directionSelection -in @('1', 'keil2cmake')) { $Direction = 'keil2cmake'; break }
                if ($directionSelection -in @('2', 'cmake2keil')) { $Direction = 'cmake2keil'; break }
                Write-Warning "无效选择 '$directionSelection'，请输入 1 或 2。"
            } while ($true)
        }
        $configuredAction = if ($Direction -in @('1', 'keil2cmake')) { 'uv2cmake' } else { 'cmake2uv' }
        $Action = $configuredAction
    }
    if ($rootConfig.PSObject.Properties.Name -contains 'projects') {
        $projectProperties = @($rootConfig.projects.PSObject.Properties)
        if ($projectProperties.Count -eq 0) { throw "No projects are defined in $configPath" }
        $projectProperty = $null

        if ($ProjectRoot) {
            $requestedRoot = [IO.Path]::GetFullPath((Join-Path (Get-Location) $ProjectRoot))
            $projectProperty = $projectProperties | Where-Object {
                $candidate = if ([IO.Path]::IsPathRooted([string]$_.Value.projectRoot)) {
                    [IO.Path]::GetFullPath([string]$_.Value.projectRoot)
                } else {
                    [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $configPath) ([string]$_.Value.projectRoot)))
                }
                $candidate -eq $requestedRoot
            } | Select-Object -First 1
        }

        if (-not $projectProperty -and $Project) {
            if ($Project -match '^\d+$') {
                $index = [int]$Project
                if ($index -ge 1 -and $index -le $projectProperties.Count) { $projectProperty = $projectProperties[$index - 1] }
            } else {
                $projectProperty = $projectProperties | Where-Object Name -eq $Project | Select-Object -First 1
            }
            if (-not $projectProperty -and $Project -notin @('a', 'all')) { throw "Project '$Project' is not present in $configPath" }
        }

        $buildAll = $Project -in @('a', 'all')
        if (-not $projectProperty -and -not $buildAll -and -not $ProjectRoot -and $projectProperties.Count -gt 1 -and $configuredAction -ne 'doctor') {
            Write-Host ''
            Write-Host '可用的 STM32 工程：' -ForegroundColor Cyan
            for ($i = 0; $i -lt $projectProperties.Count; $i++) {
                $item = $projectProperties[$i]
                $target = if ($item.Value.targetName) { [string]$item.Value.targetName } else { $item.Name }
                Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $item.Name, $target)
            }
            Write-Host '  [a] 全部工程'
            do {
                $selection = (Read-Host '请选择要处理的工程').Trim()
                if ($selection -in @('a', 'A', 'all', 'ALL')) { $buildAll = $true; break }
                if ($selection -match '^\d+$') {
                    $index = [int]$selection
                    if ($index -ge 1 -and $index -le $projectProperties.Count) { $projectProperty = $projectProperties[$index - 1]; break }
                }
                Write-Warning "无效选择 '$selection'，请输入 1-$($projectProperties.Count) 或 a。"
            } while ($true)
        }

        if ($buildAll) {
            if ($configuredAction -notin @('build', 'configure', 'generate', 'uv2cmake', 'cmake2uv')) {
                throw "Action '$configuredAction' cannot run for all projects. Select one project instead."
            }
            foreach ($item in $projectProperties) {
                Write-Host "`n=== $configuredAction : $($item.Name) ===" -ForegroundColor Cyan
                $childArguments = @{ ConfigFile=$configPath; Project=$item.Name; Action=$configuredAction }
                foreach ($key in @('Config','DebugOptimization','ReleaseOptimization','KeilCompiler','ConversionBackend','ExtraDefines')) {
                    if ($PSBoundParameters.ContainsKey($key)) { $childArguments[$key] = $PSBoundParameters[$key] }
                }
                & $PSCommandPath @childArguments
                if ($LASTEXITCODE) { exit $LASTEXITCODE }
            }
            exit 0
        }

        if (-not $projectProperty) {
            $active = [string]$rootConfig.activeProject
            $projectProperty = $projectProperties | Where-Object Name -eq $active | Select-Object -First 1
            if (-not $projectProperty) { throw "activeProject '$active' is not present in $configPath" }
        }
        $fileConfig = $projectProperty.Value
    }
    function Resolve-ConfigPath([string]$Value) {
        if (-not $Value) { return $null }
        if ([IO.Path]::IsPathRooted($Value)) { return [IO.Path]::GetFullPath($Value) }
        return [IO.Path]::GetFullPath((Join-Path $configBase $Value))
    }
    if (-not $PSBoundParameters.ContainsKey('ProjectRoot')) { $ProjectRoot = Resolve-ConfigPath $fileConfig.projectRoot }
    if (-not $PSBoundParameters.ContainsKey('Uvprojx') -and $fileConfig.uvprojx) { $Uvprojx = Resolve-ConfigPath $fileConfig.uvprojx }
    if (-not $PSBoundParameters.ContainsKey('ChipConfig') -and $fileConfig.chipConfig) { $ChipConfig = Resolve-ConfigPath $fileConfig.chipConfig }
    if (-not $PSBoundParameters.ContainsKey('CMakeProjectDir') -and $fileConfig.cmakeProjectDir) { $CMakeProjectDir = [string]$fileConfig.cmakeProjectDir }
    if (-not $PSBoundParameters.ContainsKey('TargetName') -and $fileConfig.targetName) { $TargetName = [string]$fileConfig.targetName }
    if (-not $PSBoundParameters.ContainsKey('Config') -and $fileConfig.buildType) { $Config = [string]$fileConfig.buildType }
    if (-not $PSBoundParameters.ContainsKey('DebugOptimization') -and $fileConfig.debugOptimization) { $DebugOptimization = [string]$fileConfig.debugOptimization }
    if (-not $PSBoundParameters.ContainsKey('ReleaseOptimization') -and $fileConfig.releaseOptimization) { $ReleaseOptimization = [string]$fileConfig.releaseOptimization }
    if (-not $PSBoundParameters.ContainsKey('KeilCompiler') -and $fileConfig.keilCompiler) { $KeilCompiler = [string]$fileConfig.keilCompiler }
    if (-not $PSBoundParameters.ContainsKey('ConversionBackend') -and $fileConfig.conversionBackend) { $ConversionBackend = [string]$fileConfig.conversionBackend }
    if (-not $PSBoundParameters.ContainsKey('ExtraDefines') -and $fileConfig.extraDefines) { $ExtraDefines = @($fileConfig.extraDefines | ForEach-Object { [string]$_ }) }
    if (-not $PSBoundParameters.ContainsKey('Action') -and $rootConfig.action) { $Action = [string]$rootConfig.action }

    if ($Action -ne 'doctor' -and $ProjectRoot -and -not (Test-Path -LiteralPath $ProjectRoot)) {
        $isPublicExample = (Split-Path -Leaf $configPath) -eq 'stm32.config.json'
        $guidance = if ($isPublicExample) {
            " This appears to be the public example configuration. Copy stm32.config.json to stm32.local.json and replace MySTM32Project with your real project path."
        } else {
            ''
        }
        throw "Configured projectRoot does not exist: $ProjectRoot.$guidance"
    }
}

function Invoke-Engine([string]$Root) {
    $engineArguments = @{
        ProjectRoot = $Root
        CMakeProjectDir = $CMakeProjectDir
        Uvprojx = $Uvprojx
        ChipConfig = $ChipConfig
        Config = $Config
        TargetName = $TargetName
    }
    if ($DebugOptimization) { $engineArguments.DebugOptimization = $DebugOptimization }
    if ($ReleaseOptimization) { $engineArguments.ReleaseOptimization = $ReleaseOptimization }
    if ($KeilCompiler) { $engineArguments.KeilCompiler = $KeilCompiler }
    if ($ConversionBackend) { $engineArguments.ConversionBackend = $ConversionBackend }
    if ($ExtraDefines) { $engineArguments.ExtraDefines = $ExtraDefines }

    if ($Action -in @('generate', 'configure', 'build') -and $Uvprojx) {
        $fullRoot = [IO.Path]::GetFullPath($Root)
        $cmakeRoot = if ([IO.Path]::IsPathRooted($CMakeProjectDir)) { $CMakeProjectDir } else { Join-Path $fullRoot $CMakeProjectDir }
        $manifestPath = Join-Path $cmakeRoot 'stm32-project.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            Write-Host "No generated project found; importing $Uvprojx" -ForegroundColor Yellow
            & $engine -Action uv2cmake @engineArguments
            if ($LASTEXITCODE) { exit $LASTEXITCODE }
        }
    }
    & $engine -Action $Action @engineArguments
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}

if ($ProjectRoot) {
    Invoke-Engine $ProjectRoot
    exit 0
}

if ($Action -eq 'doctor') {
    & $engine doctor
    exit $LASTEXITCODE
}

if ($Action -eq 'uv2cmake') {
    if (-not $Uvprojx) { throw 'uv2cmake requires -Uvprojx.' }
    $uv = [IO.Path]::GetFullPath((Join-Path (Get-Location) $Uvprojx))
    $root = Split-Path -Parent (Split-Path -Parent $uv)
    Invoke-Engine $root
    exit 0
}

$projectConfigs = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'projects') -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'stm32-project.json') })
$projects = @($projectConfigs | ForEach-Object {
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $_.FullName 'stm32-project.json') | ConvertFrom-Json
    if ($manifest.sourceRoot) { Get-Item -LiteralPath $manifest.sourceRoot -ErrorAction SilentlyContinue }
})

if ($projects.Count -eq 0) {
    throw "No STM32 project found beside the tool folder. Specify -ProjectRoot <path>."
}

if ($Action -in @('flash', 'cmake2uv', 'install')) {
    $names = ($projects.Name -join ', ')
    throw "Action '$Action' requires one explicit -ProjectRoot. Detected: $names"
}

foreach ($project in $projects) {
    Write-Host "`n=== $Action : $($project.Name) ===" -ForegroundColor Cyan
    Invoke-Engine $project.FullName
}
