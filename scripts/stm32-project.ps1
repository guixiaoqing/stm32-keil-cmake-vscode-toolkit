[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('uv2cmake', 'cmake2uv', 'install', 'generate', 'configure', 'build', 'flash', 'doctor')]
    [string]$Action = 'doctor',

    [string]$Uvprojx,
    [string]$ProjectRoot,
    [string]$CMakeProjectDir = 'CMake-GCC',
    [string]$ChipConfig,
    [ValidateSet('Debug', 'Release')]
    [string]$Config = 'Debug',
    [string]$TargetName,
    [ValidateSet('O0', 'O1', 'O2', 'O3', 'Og', 'Os', 'Ofast')]
    [string]$DebugOptimization,
    [ValidateSet('O0', 'O1', 'O2', 'O3', 'Og', 'Os', 'Ofast')]
    [string]$ReleaseOptimization,
    [ValidateSet('armcc5', 'armclang6')]
    [string]$KeilCompiler = 'armcc5',
    [ValidateSet('auto', 'cubemx', 'parser')]
    [string]$ConversionBackend = 'auto',
    [string[]]$ExtraDefines,
    [string[]]$Defines
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$ToolRoot = Split-Path -Parent $PSScriptRoot
$ExtraDefinesSpecified = $PSBoundParameters.ContainsKey('ExtraDefines')
$DefinesSpecified = $PSBoundParameters.ContainsKey('Defines')

function Resolve-FullPath([string]$Path, [string]$Base = (Get-Location).Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $Base $Path))
}

function Get-RelativePath([string]$Base, [string]$Path) {
    $baseUri = [Uri]((Resolve-FullPath $Base).TrimEnd('\') + '\')
    $pathUri = [Uri](Resolve-FullPath $Path)
    return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString()).Replace('\', '/')
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Content.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}

function Convert-HexToInt([string]$Value) {
    if ($Value -match '^0[xX]([0-9a-fA-F]+)$') { return [Convert]::ToInt64($Matches[1], 16) }
    return [Convert]::ToInt64($Value)
}

function Format-Hex([long]$Value) { return ('0x{0:X8}' -f $Value) }

function Invoke-NativeCapture([string]$FilePath, [string[]]$Arguments) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = $standardOutput
        Error = $standardError
        Lines = @($standardOutput -split '\r?\n')
    }
}

function Normalize-MemoryAddresses($Manifest) {
    $policy = if (($Manifest.PSObject.Properties.Name -contains 'addressPolicy') -and $Manifest.addressPolicy) {
        [string]$Manifest.addressPolicy
    } else {
        'unified'
    }
    if ($policy -notin @('unified', 'independent')) {
        throw "Unsupported addressPolicy '$policy'. Allowed: unified, independent."
    }
    $Manifest | Add-Member -NotePropertyName addressPolicy -NotePropertyValue $policy -Force
    if ($policy -eq 'independent') { return $Manifest }

    $flashOrigin = Convert-HexToInt ([string]$Manifest.memory.flash.origin)
    $flashLength = Convert-HexToInt ([string]$Manifest.memory.flash.length)
    if (-not ($Manifest.PSObject.Properties.Name -contains 'defaultLinkAddress') -or -not $Manifest.defaultLinkAddress) {
        $Manifest | Add-Member -NotePropertyName defaultLinkAddress -NotePropertyValue (Format-Hex $flashOrigin) -Force
    }
    $linkAddress = if (($Manifest.PSObject.Properties.Name -contains 'loadAddress') -and $Manifest.loadAddress) {
        Convert-HexToInt ([string]$Manifest.loadAddress)
    } else {
        $flashOrigin
    }

    if ($linkAddress -ne $flashOrigin) {
        $flashEnd = $flashOrigin + $flashLength
        if ($linkAddress -lt $flashOrigin -or $linkAddress -ge $flashEnd) {
            throw ("Configured loadAddress {0} is outside FLASH range {1}..{2}. " +
                "Set memory.flash to the physical region or use addressPolicy 'independent'." -f
                (Format-Hex $linkAddress), (Format-Hex $flashOrigin), (Format-Hex ($flashEnd - 1)))
        }
        $Manifest.memory.flash.origin = Format-Hex $linkAddress
        $Manifest.memory.flash.length = Format-Hex ($flashEnd - $linkAddress)
    }

    $unifiedAddress = [string]$Manifest.memory.flash.origin
    $Manifest.loadAddress = $unifiedAddress
    $Manifest.debugAddress = $unifiedAddress
    return $Manifest
}

function Select-LinkerScript($Manifest) {
    $provider = if ($Manifest.PSObject.Properties.Name -contains 'linkerScriptProvider') {
        [string]$Manifest.linkerScriptProvider
    } else {
        'generated'
    }
    if (-not ($Manifest.PSObject.Properties.Name -contains 'linkerScriptBase') -or -not $Manifest.linkerScriptBase) {
        $baseScript = if ($provider -eq 'cubemx') { [string]$Manifest.linkerScript } else { 'cmake/stm32-linker.ld' }
        $Manifest | Add-Member -NotePropertyName linkerScriptBase -NotePropertyValue $baseScript -Force
    }

    $linkAddress = Convert-HexToInt ([string]$Manifest.memory.flash.origin)
    $defaultAddress = Convert-HexToInt ([string]$Manifest.defaultLinkAddress)
    $effectiveScript = if ($linkAddress -eq $defaultAddress) {
        'cmake/stm32-linker.ld'
    } else {
        'cmake/stm32-linker-{0:X8}.ld' -f $linkAddress
    }
    $Manifest.linkerScript = $effectiveScript
    return $Manifest
}

function Find-Executable([string]$Name, [string[]]$Candidates) {
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return (Resolve-FullPath $candidate) }
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return ''
}

function Get-EnvironmentToolPath([string]$VariableName, [string]$RelativePath = '') {
    $base = [Environment]::GetEnvironmentVariable($VariableName)
    if (-not $base) { return '' }
    if (Test-Path -LiteralPath $base -PathType Leaf) {
        if (-not $RelativePath -or (Split-Path -Leaf $base) -ieq (Split-Path -Leaf $RelativePath)) {
            return (Resolve-FullPath $base)
        }
        return ''
    }
    $candidate = if ($RelativePath) { Join-Path $base $RelativePath } else { $base }
    if (Test-Path -LiteralPath $candidate) { return (Resolve-FullPath $candidate) }
    return ''
}

function Find-ToolchainRoot {
    if ($env:STM32_GCC_ROOT -and (Test-Path (Join-Path $env:STM32_GCC_ROOT 'bin/arm-none-eabi-gcc.exe'))) {
        return (Resolve-FullPath $env:STM32_GCC_ROOT)
    }
    $gcc = Find-Executable 'arm-none-eabi-gcc' @(
        (Get-EnvironmentToolPath 'ARM_GNU_TOOLCHAIN_ROOT' 'bin/arm-none-eabi-gcc.exe'),
        (Get-EnvironmentToolPath 'STM32_CUBE_CLT_ROOT' 'GNU-tools-for-STM32/bin/arm-none-eabi-gcc.exe')
    )
    if ($gcc) { return (Split-Path -Parent (Split-Path -Parent $gcc)) }
    return ''
}

function Find-CubeMxInstall {
    $programFilesCubeMx = ''
    if ($env:ProgramFiles) {
        $programFilesCubeMx = Join-Path $env:ProgramFiles 'STMicroelectronics/STM32Cube/STM32CubeMX/STM32CubeMX.exe'
    }
    $cubeMx = Find-Executable 'STM32CubeMX.exe' @(
        (Get-EnvironmentToolPath 'STM32_CUBEMX_ROOT' 'STM32CubeMX.exe'),
        $programFilesCubeMx
    )
    if (-not $cubeMx) { return $null }
    $installRoot = Split-Path -Parent $cubeMx
    $java = Join-Path $installRoot 'jre/bin/java.exe'
    if (-not (Test-Path -LiteralPath $java)) { return $null }
    return [pscustomobject]@{ executable=$cubeMx; installRoot=$installRoot; java=$java }
}

function Find-JLinkGdbServer {
    $candidates = [Collections.Generic.List[string]]::new()
    $configured = Get-EnvironmentToolPath 'JLINK_ROOT' 'JLinkGDBServerCL.exe'
    if ($configured) { $candidates.Add($configured) }

    foreach ($programRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not $programRoot) { continue }
        $seggerRoot = Join-Path $programRoot 'SEGGER'
        if (-not (Test-Path -LiteralPath $seggerRoot)) { continue }
        Get-ChildItem -LiteralPath $seggerRoot -Directory -Filter 'JLink*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | ForEach-Object {
                $candidates.Add((Join-Path $_.FullName 'JLinkGDBServerCL.exe'))
            }
    }

    return (Find-Executable 'JLinkGDBServerCL.exe' @($candidates))
}

function Add-CubeMxSupport($Manifest, [string]$Root, [string]$Backend) {
    if ($Backend -eq 'parser') { return $Manifest }
    $ioc = Get-ChildItem -LiteralPath $Root -File -Filter '*.ioc' -ErrorAction SilentlyContinue |
        Sort-Object @{Expression={if($_.BaseName -ieq [string]$Manifest.name){0}else{1}}}, Name | Select-Object -First 1
    $cubeMx = Find-CubeMxInstall
    if (-not $ioc -or -not $cubeMx) {
        $reason = if (-not $ioc) { 'no .ioc file was found' } else { 'STM32CubeMX was not found' }
        if ($Backend -eq 'cubemx') { throw "CubeMX conversion was requested, but $reason." }
        Write-Warning "CubeMX support generation skipped: $reason. Using parser/chip templates."
        return $Manifest
    }

    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $stagingRoot = Join-Path $temporaryBase ('stm32-portable-cubemx-' + [Guid]::NewGuid().ToString('N'))
    $generatedName = 'stm32_portable'
    $generatedRoot = Join-Path $stagingRoot $generatedName
    try {
        New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
        $scriptPath = Join-Path $stagingRoot 'generate.script'
        $scriptText = @"
config load "$($ioc.FullName)"
project toolchain CMake
project compiler GCC
project name $generatedName
project path "$stagingRoot"
project generate
exit
"@
        Write-Utf8NoBom $scriptPath $scriptText
        Write-Host "Generating STM32 GCC support files with CubeMX: $($ioc.Name)" -ForegroundColor Cyan
        $cubeOutput = @(& $cubeMx.java '--add-opens=java.desktop/java.awt=ALL-UNNAMED' '--add-exports=java.desktop/sun.awt=ALL-UNNAMED' '-Djavax.net.ssl.trustStoreType=WINDOWS-ROOT' -jar $cubeMx.executable -q $scriptPath 2>&1)
        $cubeExitCode = $LASTEXITCODE
        if ($cubeExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $generatedRoot 'CMakeLists.txt'))) {
            $tail = ($cubeOutput | Select-Object -Last 20) -join "`n"
            throw "CubeMX generation failed (exit code $cubeExitCode).`n$tail"
        }

        $configDir = Get-ProjectConfigDir $Root
        $supportDir = Join-Path $configDir 'cubemx'
        New-Item -ItemType Directory -Force -Path $supportDir | Out-Null
        $startup = Get-ChildItem -LiteralPath $generatedRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)^startup_[^.]+\.(s|S)$' } | Select-Object -First 1
        $linker = Get-ChildItem -LiteralPath $generatedRoot -Recurse -File -Filter '*.ld' -ErrorAction SilentlyContinue |
            Sort-Object @{Expression={if($_.Name -match '(?i)FLASH'){0}else{1}}}, FullName | Select-Object -First 1
        if (-not $startup -or -not $linker) { throw 'CubeMX did not generate a GNU startup file and linker script.' }

        $startupDestination = Join-Path $supportDir $startup.Name
        Copy-Item -LiteralPath $startup.FullName -Destination $startupDestination -Force
        $Manifest | Add-Member -NotePropertyName gccStartupTemplate -NotePropertyValue $startupDestination.Replace('\','/') -Force

        $linkerDestination = Join-Path $supportDir $linker.Name
        Copy-Item -LiteralPath $linker.FullName -Destination $linkerDestination -Force
        $Manifest.linkerScript = Get-RelativePath $configDir $linkerDestination
        $Manifest | Add-Member -NotePropertyName linkerScriptProvider -NotePropertyValue 'cubemx' -Force

        foreach ($supportName in @('syscalls.c', 'sysmem.c')) {
            if (@($Manifest.sources | Where-Object { (Split-Path -Leaf $_) -ieq $supportName }).Count -gt 0) { continue }
            $supportSource = Get-ChildItem -LiteralPath $generatedRoot -Recurse -File -Filter $supportName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($supportSource) {
                $destination = Join-Path $supportDir $supportName
                Copy-Item -LiteralPath $supportSource.FullName -Destination $destination -Force
                $Manifest.sources = @(@($Manifest.sources) + (Get-RelativePath $Root $destination) | Sort-Object -Unique)
            }
        }
        $Manifest | Add-Member -NotePropertyName cubeMxGenerated -NotePropertyValue ([pscustomobject][ordered]@{
            ioc=(Get-RelativePath $Root $ioc.FullName); toolchain='CMake'; compiler='GCC'; generatedSupportDirectory=(Get-RelativePath $Root $supportDir)
        }) -Force
        Write-Host "CubeMX support files imported into $supportDir" -ForegroundColor Green
        return $Manifest
    } catch {
        if ($Backend -eq 'cubemx') { throw }
        Write-Warning "CubeMX generation failed; using parser/chip templates. $($_.Exception.Message)"
        return $Manifest
    } finally {
        $fullStagingRoot = [IO.Path]::GetFullPath($stagingRoot)
        if ($fullStagingRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullStagingRoot)) {
            Remove-Item -LiteralPath $fullStagingRoot -Recurse -Force
        }
    }
}

function New-KeilProjectFromManifest($Manifest, [string]$UvPath, [string]$Target) {
    $uvision = Find-Executable 'uVision.com' @(
        (Get-EnvironmentToolPath 'KEIL_ROOT' 'UV4/uVision.com')
    )
    if (-not $uvision) {
        $uvision = Find-Executable 'UV4.exe' @(
            (Get-EnvironmentToolPath 'KEIL_ROOT' 'UV4/UV4.exe')
        )
    }
    if (-not $uvision) {
        throw "Keil project does not exist and uVision.com/UV4.exe was not found. Install Keil MDK or create the .uvprojx once: $UvPath"
    }
    $keilDevice = if (($Manifest.PSObject.Properties.Name -contains 'keilDevice') -and $Manifest.keilDevice) {
        [string]$Manifest.keilDevice
    } else {
        [string]$Manifest.device
    }
    $parent = Split-Path -Parent $UvPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Write-Host "Keil project does not exist; creating it with uVision ($keilDevice): $UvPath" -ForegroundColor Yellow
    & $uvision $UvPath -j0 -n $keilDevice -t $Target
    if ($LASTEXITCODE -or -not (Test-Path -LiteralPath $UvPath)) {
        throw "uVision failed to create Keil project '$UvPath' (exit code $LASTEXITCODE). Check that device '$keilDevice' is installed in Keil."
    }
}

function Get-ProjectConfigDir([string]$Root) {
    $fullRoot = Resolve-FullPath $Root
    if ([IO.Path]::IsPathRooted($CMakeProjectDir)) { return (Resolve-FullPath $CMakeProjectDir) }
    return (Resolve-FullPath $CMakeProjectDir $fullRoot)
}

function Get-Manifest([string]$Root) {
    $path = Join-Path (Get-ProjectConfigDir $Root) 'stm32-project.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing manifest: $path. Run uv2cmake first." }
    return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
}

function Initialize-DefineLayers($Manifest, [string]$Root) {
    if (-not ($Manifest.PSObject.Properties.Name -contains 'baseDefines')) {
        $baseDefines = @($Manifest.defines | ForEach-Object { [string]$_ })
        if (($Manifest.PSObject.Properties.Name -contains 'uvprojx') -and $Manifest.uvprojx) {
            $uvPath = Resolve-FullPath ([string]$Manifest.uvprojx) $Root
            if (Test-Path -LiteralPath $uvPath) {
                [xml]$uvXml = Get-Content -Raw -LiteralPath $uvPath
                $uvTargets = @($uvXml.Project.Targets.Target)
                $uvTargetName = if (($Manifest.PSObject.Properties.Name -contains 'uvTarget') -and $Manifest.uvTarget) { [string]$Manifest.uvTarget } else { '' }
                $uvTarget = if ($uvTargetName) { $uvTargets | Where-Object TargetName -eq $uvTargetName | Select-Object -First 1 } else { $uvTargets | Select-Object -First 1 }
                if ($uvTarget) {
                    $baseDefines = @(([string]$uvTarget.TargetOption.TargetArmAds.Cads.VariousControls.Define) -split '[,; ]+' | Where-Object { $_ })
                }
            }
        }
        $Manifest | Add-Member -NotePropertyName baseDefines -NotePropertyValue @($baseDefines) -Force
    }
    if (-not ($Manifest.PSObject.Properties.Name -contains 'chipDefines')) {
        $Manifest | Add-Member -NotePropertyName chipDefines -NotePropertyValue @() -Force
    }
    if (-not ($Manifest.PSObject.Properties.Name -contains 'extraDefines')) {
        $Manifest | Add-Member -NotePropertyName extraDefines -NotePropertyValue @() -Force
    }
    return $Manifest
}

function Update-EffectiveDefines($Manifest, [string]$Root) {
    $Manifest = Initialize-DefineLayers $Manifest $Root
    $Manifest.defines = @(
        @($Manifest.baseDefines) + @($Manifest.chipDefines) + @($Manifest.extraDefines) |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
    return $Manifest
}

function Apply-ChipConfig($Manifest, [string]$ConfigPath, [string]$Root) {
    if (-not $ConfigPath) { return $Manifest }
    $path = Resolve-FullPath $ConfigPath
    if (-not (Test-Path -LiteralPath $path)) { throw "Chip config not found: $path" }
    $chip = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    foreach ($key in @('device', 'loadAddress', 'debugAddress', 'defaultLinkAddress', 'addressPolicy')) {
        if ($chip.PSObject.Properties.Name -contains $key) {
            if ($Manifest.PSObject.Properties.Name -contains $key) { $Manifest.$key = $chip.$key }
            else { $Manifest | Add-Member -NotePropertyName $key -NotePropertyValue $chip.$key }
        }
    }
    if ($chip.PSObject.Properties.Name -contains 'keilDevice') {
        $Manifest | Add-Member -NotePropertyName keilDevice -NotePropertyValue ([string]$chip.keilDevice) -Force
    }
    if ($chip.PSObject.Properties.Name -contains 'keilStartupTemplate') {
        $startupTemplate = Resolve-FullPath ([string]$chip.keilStartupTemplate) (Split-Path -Parent $path)
        $Manifest | Add-Member -NotePropertyName keilStartupTemplate -NotePropertyValue $startupTemplate.Replace('\','/') -Force
    }
    if ($chip.PSObject.Properties.Name -contains 'gccStartupTemplate') {
        $gccStartupTemplate = Resolve-FullPath ([string]$chip.gccStartupTemplate) (Split-Path -Parent $path)
        $Manifest | Add-Member -NotePropertyName gccStartupTemplate -NotePropertyValue $gccStartupTemplate.Replace('\','/') -Force
    }
    if ($chip.PSObject.Properties.Name -contains 'arch') {
        foreach ($key in @('cpu', 'fpu', 'floatAbi')) {
            if ($chip.arch.PSObject.Properties.Name -contains $key) { $Manifest.arch.$key = $chip.arch.$key }
        }
    }
    if ($chip.PSObject.Properties.Name -contains 'memory') {
        foreach ($region in @('flash', 'ram')) {
            if ($chip.memory.PSObject.Properties.Name -contains $region) {
                foreach ($key in @('origin', 'length')) {
                    if ($chip.memory.$region.PSObject.Properties.Name -contains $key) { $Manifest.memory.$region.$key = $chip.memory.$region.$key }
                }
            }
        }
    }
    if ($chip.PSObject.Properties.Name -contains 'debug') {
        foreach ($key in @('probe', 'interface', 'speedKhz', 'serialNumber', 'serverArgs', 'openocdConfigFiles', 'svdFile', 'runToEntryPoint')) {
            if ($chip.debug.PSObject.Properties.Name -contains $key) {
                if ($Manifest.debug.PSObject.Properties.Name -contains $key) { $Manifest.debug.$key = $chip.debug.$key }
                else { $Manifest.debug | Add-Member -NotePropertyName $key -NotePropertyValue $chip.debug.$key }
            }
        }
    }
    $Manifest = Initialize-DefineLayers $Manifest $Root
    $Manifest.chipDefines = if ($chip.PSObject.Properties.Name -contains 'definesAppend') { @($chip.definesAppend | ForEach-Object { [string]$_ }) } else { @() }
    $Manifest = Update-EffectiveDefines $Manifest $Root
    $Manifest | Add-Member -NotePropertyName chipConfig -NotePropertyValue (Get-RelativePath $Root $path) -Force
    return (Normalize-MemoryAddresses $Manifest)
}

function Get-CpuOptions([string]$CpuText, [string]$Device) {
    $cpu = 'cortex-m3'; $fpu = ''; $floatAbi = 'soft'
    if ($CpuText -match 'Cortex-M0\+') { $cpu = 'cortex-m0plus' }
    elseif ($CpuText -match 'Cortex-M0') { $cpu = 'cortex-m0' }
    elseif ($CpuText -match 'Cortex-M7') { $cpu = 'cortex-m7'; $fpu = 'fpv5-d16'; $floatAbi = 'hard' }
    elseif ($CpuText -match 'Cortex-M4' -or $Device -match '^STM32(F3|F4|G4|L4|WB|WL)') {
        $cpu = 'cortex-m4'; $fpu = 'fpv4-sp-d16'; $floatAbi = 'hard'
    }
    elseif ($CpuText -match 'Cortex-M33') { $cpu = 'cortex-m33'; $fpu = 'fpv5-sp-d16'; $floatAbi = 'hard' }
    return [ordered]@{ cpu = $cpu; fpu = $fpu; floatAbi = $floatAbi }
}

function Apply-OptimizationOptions($Manifest) {
    $debugValue = 'Og'
    $releaseValue = 'Os'
    $debugInfo = 'g3'
    $releaseDebugInfo = 'g1'
    if ($Manifest.PSObject.Properties.Name -contains 'optimization') {
        if ($Manifest.optimization.debug) { $debugValue = [string]$Manifest.optimization.debug }
        if ($Manifest.optimization.release) { $releaseValue = [string]$Manifest.optimization.release }
        if ($Manifest.optimization.debugInfo) { $debugInfo = [string]$Manifest.optimization.debugInfo }
        if ($Manifest.optimization.releaseDebugInfo) { $releaseDebugInfo = [string]$Manifest.optimization.releaseDebugInfo }
    }
    if ($DebugOptimization) { $debugValue = $DebugOptimization }
    if ($ReleaseOptimization) { $releaseValue = $ReleaseOptimization }
    $allowed = @('O0', 'O1', 'O2', 'O3', 'Og', 'Os', 'Ofast')
    if ($debugValue -notin $allowed) { throw "Unsupported Debug optimization '$debugValue'. Allowed: $($allowed -join ', ')" }
    if ($releaseValue -notin $allowed) { throw "Unsupported Release optimization '$releaseValue'. Allowed: $($allowed -join ', ')" }
    $debugLevels = @('g0', 'g1', 'g2', 'g3')
    if ($debugInfo -notin $debugLevels -or $releaseDebugInfo -notin $debugLevels) { throw "Debug information level must be one of: $($debugLevels -join ', ')" }
    $value = [pscustomobject][ordered]@{ debug = $debugValue; release = $releaseValue; debugInfo = $debugInfo; releaseDebugInfo = $releaseDebugInfo }
    $Manifest | Add-Member -NotePropertyName optimization -NotePropertyValue $value -Force
    return $Manifest
}

function Initialize-BuildOptions($Manifest) {
    if (-not ($Manifest.PSObject.Properties.Name -contains 'compiler')) {
        $Manifest | Add-Member -NotePropertyName compiler -NotePropertyValue ([pscustomobject][ordered]@{})
    }
    $compilerDefaults = [ordered]@{
        cStandard=11; cExtensions=$true; cppStandard=17; cppExtensions=$true
        warnings='default'; warningsAsErrors=$false; signedChar=$false
        shortEnums=$false; shortWchar=$false; lto=$false
        functionSections=$true; dataSections=$true; strictAnsi=$false
        ropi=$false; rwpi=$false; executeOnly=$false; splitLoadStore=$false
        noAutoIncludes=$false; optimizationGoal='size'; commonOptions=@(); debugOptions=@(); releaseOptions=@(); undefines=@(); keilMiscControls=''
    }
    foreach ($entry in $compilerDefaults.GetEnumerator()) {
        if (-not ($Manifest.compiler.PSObject.Properties.Name -contains $entry.Key)) {
            $Manifest.compiler | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
        }
    }
    if (-not ($Manifest.PSObject.Properties.Name -contains 'assembler')) {
        $Manifest | Add-Member -NotePropertyName assembler -NotePropertyValue ([pscustomobject][ordered]@{})
    }
    $assemblerDefaults = [ordered]@{ defines=@(); includeDirectories=@(); options=@(); keilMiscControls='' }
    foreach ($entry in $assemblerDefaults.GetEnumerator()) {
        if (-not ($Manifest.assembler.PSObject.Properties.Name -contains $entry.Key)) {
            $Manifest.assembler | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
        }
    }
    if (-not ($Manifest.PSObject.Properties.Name -contains 'linker')) {
        $Manifest | Add-Member -NotePropertyName linker -NotePropertyValue ([pscustomobject][ordered]@{})
    }
    $linkerDefaults = [ordered]@{ gcSections=$true; mapFile=$true; lto=$false; noStandardLibraries=$false; libraries=@(); libraryDirectories=@(); options=@(); scatterFile=''; keilMiscControls=''; disabledWarnings='' }
    foreach ($entry in $linkerDefaults.GetEnumerator()) {
        if (-not ($Manifest.linker.PSObject.Properties.Name -contains $entry.Key)) {
            $Manifest.linker | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
        }
    }
    if (-not ($Manifest.PSObject.Properties.Name -contains 'output')) {
        $Manifest | Add-Member -NotePropertyName output -NotePropertyValue ([pscustomobject][ordered]@{})
    }
    $outputDefaults = [ordered]@{ artifactType='executable'; hex=$true; bin=$true; debugInformation=$true; browseInformation=$true; outputDirectory=''; listingPath='' }
    foreach ($entry in $outputDefaults.GetEnumerator()) {
        if (-not ($Manifest.output.PSObject.Properties.Name -contains $entry.Key)) {
            $Manifest.output | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
        }
    }
    if (-not ($Manifest.PSObject.Properties.Name -contains 'sourceOptions')) {
        $Manifest | Add-Member -NotePropertyName sourceOptions -NotePropertyValue @()
    }
    return $Manifest
}

function ConvertTo-CMakeItems($Items) {
    return (@($Items) | ForEach-Object { '  "' + ([string]$_).Replace('\','/').Replace('"','\"') + '"' }) -join "`n"
}

function ConvertTo-CMakeBool($Value) { if ([bool]$Value) { return 'ON' } else { return 'OFF' } }

function Convert-KeilOptimization([int]$Value) {
    switch ($Value) { 1 {'O0'} 2 {'O1'} 3 {'O2'} 4 {'O3'} default {'O2'} }
}

function Apply-ExtraDefines($Manifest) {
    $rootForDefines = if (($Manifest.PSObject.Properties.Name -contains 'sourceRoot') -and $Manifest.sourceRoot) { [string]$Manifest.sourceRoot } elseif ($ProjectRoot) { [string]$ProjectRoot } else { (Get-Location).Path }
    $Manifest = Initialize-DefineLayers $Manifest $rootForDefines
    if ($DefinesSpecified) {
        $Manifest.baseDefines = @($Defines | ForEach-Object { [string]$_ })
    }
    if ($ExtraDefinesSpecified) {
        $Manifest.extraDefines = @($ExtraDefines | ForEach-Object { [string]$_ })
    }
    return (Update-EffectiveDefines $Manifest $rootForDefines)
}

function Remove-KeilOnlySources($Manifest, [string]$Root) {
    $Root = Resolve-FullPath $Root
    $isNativeCMake = $Manifest.PSObject.Properties.Name -contains 'nativeCMake'
    $uvPath = if ($Manifest.uvprojx) { Resolve-FullPath ([string]$Manifest.uvprojx) $Root } else { '' }
    $uvDirectory = if ($uvPath) { (Split-Path -Parent $uvPath).TrimEnd('\') + '\' } else { '' }
    $filtered = [Collections.Generic.List[string]]::new()
    $startupNamesToReplace = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($sourceEntry in @($Manifest.sources)) {
        $source = [string]$sourceEntry
        $fullSource = Resolve-FullPath $source $Root
        $insideUvDirectory = $uvDirectory -and $fullSource.StartsWith($uvDirectory, [StringComparison]::OrdinalIgnoreCase)
        $isStartup = (Split-Path -Leaf $source) -match '(?i)^startup_[^.]+\.(s|S)$'
        $isArmAsm = $false
        if ($isStartup -and (Test-Path -LiteralPath $fullSource)) {
            $startupText = Get-Content -Raw -LiteralPath $fullSource
            $isArmAsm = $startupText -match '(?im)^\s*(AREA|EXPORT|IMPORT|DCD|PRESERVE8|PROC|ENDP)\b'
        }
        if (($isNativeCMake -and $insideUvDirectory) -or ($isStartup -and ($insideUvDirectory -or $isArmAsm))) {
            if ($isStartup) { [void]$startupNamesToReplace.Add((Split-Path -Leaf $source)) }
            continue
        }
        $filtered.Add($source)
    }
    foreach ($startupName in $startupNamesToReplace) {
        if ($filtered | Where-Object { (Split-Path -Leaf $_) -ieq $startupName }) { continue }
        $candidates = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $startupName -ErrorAction SilentlyContinue |
            Where-Object {
                (-not $uvDirectory -or -not $_.FullName.StartsWith($uvDirectory, [StringComparison]::OrdinalIgnoreCase)) -and
                $_.FullName -notmatch '[\\/]CMake-GCC[\\/]'
            })
        $gccStartup = $candidates | Where-Object {
            (Get-Content -Raw -LiteralPath $_.FullName) -notmatch '(?im)^\s*(AREA|EXPORT|IMPORT|DCD|PRESERVE8|PROC|ENDP)\b'
        } | Sort-Object @{Expression={if($_.FullName -match '(?i)[\\/]Templates[\\/]gcc[\\/]'){0}else{1}}}, FullName | Select-Object -First 1
        if (-not $gccStartup -and ($Manifest.PSObject.Properties.Name -contains 'gccStartupTemplate') -and (Test-Path -LiteralPath $Manifest.gccStartupTemplate)) {
            $gccStartup = Get-Item -LiteralPath $Manifest.gccStartupTemplate
        }
        if (-not $gccStartup) {
            throw "GNU startup '$startupName' was not found outside the Keil project directory. Add gccStartupTemplate to the chip config."
        }
        $filtered.Add((Get-RelativePath $Root $gccStartup.FullName))
    }
    $Manifest.sources = @($filtered | Sort-Object -Unique)
    return $Manifest
}

function Write-KeilScatterFile($Manifest, [string]$UvDirectory, [string]$Target) {
    $path = Join-Path $UvDirectory ($Target + '.sct')
    $content = @"
; Auto-generated from the native CMake memory configuration.
LR_FLASH $($Manifest.memory.flash.origin) $($Manifest.memory.flash.length) {
  ER_FLASH $($Manifest.memory.flash.origin) $($Manifest.memory.flash.length) {
    *.o (.isr_vector, +First)
    *(InRoot`$`$Sections)
    .ANY (+RO)
    .ANY (+XO)
  }
  RW_RAM $($Manifest.memory.ram.origin) $($Manifest.memory.ram.length) {
    .ANY (+RW +ZI)
  }
}
"@
    Write-Utf8NoBom $path $content
    return $path
}

function New-LinkerScript($Manifest, [string]$Root) {
    $flashOrigin = $Manifest.memory.flash.origin
    $flashLength = $Manifest.memory.flash.length
    $ramOrigin = $Manifest.memory.ram.origin
    $ramLength = $Manifest.memory.ram.length
    $content = @"
/* Auto-generated from stm32-project.json. Edit the manifest, then rerun uv2cmake. */
ENTRY(Reset_Handler)

_estack = ORIGIN(RAM) + LENGTH(RAM);
_Min_Heap_Size = 0x200;
_Min_Stack_Size = 0x400;

MEMORY
{
  FLASH (rx)  : ORIGIN = $flashOrigin, LENGTH = $flashLength
  RAM   (xrw) : ORIGIN = $ramOrigin,   LENGTH = $ramLength
}

SECTIONS
{
  .isr_vector : { . = ALIGN(4); KEEP(*(.isr_vector)) . = ALIGN(4); } >FLASH
  .text :
  {
    . = ALIGN(4); *(.text) *(.text*) *(.glue_7) *(.glue_7t) *(.eh_frame)
    KEEP(*(.init)) KEEP(*(.fini)) . = ALIGN(4); _etext = .;
  } >FLASH
  .rodata : { . = ALIGN(4); *(.rodata) *(.rodata*) . = ALIGN(4); } >FLASH
  .ARM.extab : { *(.ARM.extab* .gnu.linkonce.armextab.*) } >FLASH
  .ARM :
  {
    __exidx_start = .; *(.ARM.exidx*) __exidx_end = .;
  } >FLASH
  .preinit_array : { PROVIDE_HIDDEN(__preinit_array_start = .); KEEP(*(.preinit_array*)) PROVIDE_HIDDEN(__preinit_array_end = .); } >FLASH
  .init_array : { PROVIDE_HIDDEN(__init_array_start = .); KEEP(*(SORT(.init_array.*))) KEEP(*(.init_array*)) PROVIDE_HIDDEN(__init_array_end = .); } >FLASH
  .fini_array : { PROVIDE_HIDDEN(__fini_array_start = .); KEEP(*(SORT(.fini_array.*))) KEEP(*(.fini_array*)) PROVIDE_HIDDEN(__fini_array_end = .); } >FLASH
  _sidata = LOADADDR(.data);
  .data :
  {
    . = ALIGN(4); _sdata = .; *(.data) *(.data*) . = ALIGN(4); _edata = .;
  } >RAM AT> FLASH
  .bss :
  {
    . = ALIGN(4); _sbss = .; __bss_start__ = _sbss; *(.bss) *(.bss*) *(COMMON)
    . = ALIGN(4); _ebss = .; __bss_end__ = _ebss;
  } >RAM
  ._user_heap_stack :
  {
    . = ALIGN(8); PROVIDE(end = .); PROVIDE(_end = .);
    . = . + _Min_Heap_Size; . = . + _Min_Stack_Size; . = ALIGN(8);
  } >RAM
  /DISCARD/ : { libc.a(*) libm.a(*) libgcc.a(*) }
  .ARM.attributes 0 : { *(.ARM.attributes) }
}
"@
    Write-Utf8NoBom (Join-Path $Root $Manifest.linkerScript) $content
}

function Update-LinkerScriptMemory($Manifest, [string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Linker script is missing: $Path" }
    $content = Get-Content -Raw -LiteralPath $Path

    function Set-MemoryRegion([string]$Text, [string[]]$RegionPatterns, [string]$Origin, [string]$Length, [string]$Kind) {
        foreach ($regionPattern in $RegionPatterns) {
            $pattern = "(?im)^(\s*$regionPattern\s*(?:\([^)]*\))?\s*:\s*ORIGIN\s*=\s*)[^,\r\n]+(\s*,\s*LENGTH\s*=\s*)[^\s,/\r\n]+"
            $regex = [regex]::new($pattern)
            if ($regex.IsMatch($Text)) {
                return $regex.Replace($Text, { param($match)
                    $match.Groups[1].Value + $Origin + $match.Groups[2].Value + $Length
                }, 1)
            }
        }
        throw "Could not locate the $Kind MEMORY region in linker script: $Path"
    }

    $content = Set-MemoryRegion $content @('FLASH', 'FLASH[A-Za-z0-9_]*') ([string]$Manifest.memory.flash.origin) ([string]$Manifest.memory.flash.length) 'FLASH'
    $content = Set-MemoryRegion $content @('RAM', 'RAM_D1', 'RAM[A-Za-z0-9_]*') ([string]$Manifest.memory.ram.origin) ([string]$Manifest.memory.ram.length) 'RAM'
    Write-Utf8NoBom $Path $content
}

function Write-GeneratedProject($Manifest, [string]$Root) {
    $Root = Resolve-FullPath $Root
    $Manifest = Normalize-MemoryAddresses $Manifest
    $Manifest = Select-LinkerScript $Manifest
    $Manifest = Remove-KeilOnlySources $Manifest $Root
    $Manifest = Apply-OptimizationOptions $Manifest
    $Manifest = Initialize-BuildOptions $Manifest
    $Manifest = Apply-ExtraDefines $Manifest
    $configDir = Get-ProjectConfigDir $Root
    Write-Utf8NoBom (Join-Path $configDir 'stm32-project.json') ($Manifest | ConvertTo-Json -Depth 20)
    $cmakeSources = ($Manifest.sources | ForEach-Object { '  "' + (Resolve-FullPath $_ $Root).Replace('\','/') + '"' }) -join "`n"
    $cmakeIncludes = ($Manifest.includeDirectories | ForEach-Object { '  "' + (Resolve-FullPath $_ $Root).Replace('\','/') + '"' }) -join "`n"
    $cmakeDefines = ($Manifest.defines | ForEach-Object { '  "' + $_ + '"' }) -join "`n"
    $cpuFlags = "-mcpu=$($Manifest.arch.cpu);-mthumb"
    if ($Manifest.arch.fpu) { $cpuFlags += ";-mfpu=$($Manifest.arch.fpu);-mfloat-abi=$($Manifest.arch.floatAbi)" }

    $cOptions = [Collections.Generic.List[string]]::new()
    if ($Manifest.compiler.functionSections) { $cOptions.Add('-ffunction-sections') }
    if ($Manifest.compiler.dataSections) { $cOptions.Add('-fdata-sections') }
    switch ([string]$Manifest.compiler.warnings) {
        'none' { $cOptions.Add('-w') }
        'all' { $cOptions.Add('-Wall') }
        'extra' { $cOptions.Add('-Wall'); $cOptions.Add('-Wextra') }
    }
    if ($Manifest.compiler.warningsAsErrors) { $cOptions.Add('-Werror') }
    if ($Manifest.compiler.signedChar) { $cOptions.Add('-fsigned-char') }
    if ($Manifest.compiler.shortEnums) { $cOptions.Add('-fshort-enums') }
    if ($Manifest.compiler.shortWchar) { $cOptions.Add('-fshort-wchar') }
    if ($Manifest.compiler.strictAnsi) { $cOptions.Add('-pedantic') }
    if ($Manifest.compiler.lto) { $cOptions.Add('-flto') }
    foreach ($item in @($Manifest.compiler.undefines)) { $cOptions.Add("-U$item") }
    foreach ($item in @($Manifest.compiler.commonOptions)) { $cOptions.Add([string]$item) }
    $asmOptions = @($Manifest.assembler.options)
    $asmIncludes = @($Manifest.assembler.includeDirectories | ForEach-Object { (Resolve-FullPath $_ $Root).Replace('\','/') })
    $linkOptions = [Collections.Generic.List[string]]::new()
    if ($Manifest.linker.gcSections) { $linkOptions.Add('-Wl,--gc-sections') }
    if ($Manifest.linker.mapFile) { $linkOptions.Add("-Wl,-Map=$($Manifest.name).map") }
    if ($Manifest.linker.noStandardLibraries) { $linkOptions.Add('-nostdlib') }
    if ($Manifest.compiler.lto -or $Manifest.linker.lto) { $linkOptions.Add('-flto') }
    foreach ($item in @($Manifest.linker.options)) { $linkOptions.Add([string]$item) }
    $libraryDirs = @($Manifest.linker.libraryDirectories | ForEach-Object { (Resolve-FullPath $_ $Root).Replace('\','/') })
    $sourceOptionLines = [Collections.Generic.List[string]]::new()
    foreach ($entry in @($Manifest.sourceOptions)) {
        if (-not $entry.path) { continue }
        $sourcePath = (Resolve-FullPath $entry.path $Root).Replace('\','/')
        if ($entry.compileOptions) { $sourceOptionLines.Add('set_property(SOURCE "' + $sourcePath + '" APPEND PROPERTY COMPILE_OPTIONS "' + (@($entry.compileOptions) -join ';') + '")') }
        if ($entry.defines) { $sourceOptionLines.Add('set_property(SOURCE "' + $sourcePath + '" APPEND PROPERTY COMPILE_DEFINITIONS "' + (@($entry.defines) -join ';') + '")') }
        if ($entry.includeDirectories) {
            $sourceIncludes = @($entry.includeDirectories | ForEach-Object { (Resolve-FullPath $_ $Root).Replace('\','/') })
            $sourceOptionLines.Add('set_property(SOURCE "' + $sourcePath + '" APPEND PROPERTY INCLUDE_DIRECTORIES "' + ($sourceIncludes -join ';') + '")')
        }
    }

    $metadata = @"
# Generated by stm32-keil-cmake-vscode-toolkit. stm32-project.json is the editable source of truth.
set(STM32_PROJECT_NAME "$($Manifest.name)")
set(STM32_DEVICE "$($Manifest.device)")
set(STM32_CPU_FLAGS "$cpuFlags")
set(STM32_DEBUG_OPTIMIZATION "-$($Manifest.optimization.debug)")
set(STM32_RELEASE_OPTIMIZATION "-$($Manifest.optimization.release)")
set(STM32_DEBUG_INFORMATION "-$($Manifest.optimization.debugInfo)")
set(STM32_RELEASE_DEBUG_INFORMATION "-$($Manifest.optimization.releaseDebugInfo)")
set(STM32_C_STANDARD "$($Manifest.compiler.cStandard)")
set(STM32_C_EXTENSIONS "$(ConvertTo-CMakeBool $Manifest.compiler.cExtensions)")
set(STM32_CXX_STANDARD "$($Manifest.compiler.cppStandard)")
set(STM32_CXX_EXTENSIONS "$(ConvertTo-CMakeBool $Manifest.compiler.cppExtensions)")
set(STM32_ARTIFACT_TYPE "$($Manifest.output.artifactType)")
set(STM32_CREATE_HEX "$(ConvertTo-CMakeBool $Manifest.output.hex)")
set(STM32_CREATE_BIN "$(ConvertTo-CMakeBool $Manifest.output.bin)")
set(STM32_LINKER_SCRIPT "`${CMAKE_CURRENT_LIST_DIR}/../$($Manifest.linkerScript)")
set(STM32_C_COMPILE_OPTIONS
$(ConvertTo-CMakeItems $cOptions)
)
set(STM32_ASM_OPTIONS
$(ConvertTo-CMakeItems $asmOptions)
)
set(STM32_ASM_DEFINES
$(ConvertTo-CMakeItems @($Manifest.assembler.defines))
)
set(STM32_ASM_INCLUDE_DIRS
$(ConvertTo-CMakeItems $asmIncludes)
)
set(STM32_DEBUG_OPTIONS
$(ConvertTo-CMakeItems @($Manifest.compiler.debugOptions))
)
set(STM32_RELEASE_OPTIONS
$(ConvertTo-CMakeItems @($Manifest.compiler.releaseOptions))
)
set(STM32_LINK_OPTIONS
$(ConvertTo-CMakeItems $linkOptions)
)
set(STM32_LIBRARIES
$(ConvertTo-CMakeItems @($Manifest.linker.libraries))
)
set(STM32_LIBRARY_DIRECTORIES
$(ConvertTo-CMakeItems $libraryDirs)
)
set(STM32_SOURCES
$cmakeSources
)
set(STM32_INCLUDE_DIRS
$cmakeIncludes
)
set(STM32_DEFINES
$cmakeDefines
)
$($sourceOptionLines -join "`n")
"@
    Write-Utf8NoBom (Join-Path $configDir 'cmake/stm32-project.cmake') $metadata

    $toolchain = @'
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

if(WIN32)
  set(_tool_suffix ".exe")
else()
  set(_tool_suffix "")
endif()

if(DEFINED ENV{STM32_GCC_ROOT} AND EXISTS "$ENV{STM32_GCC_ROOT}/bin/arm-none-eabi-gcc${_tool_suffix}")
  set(_configured_gcc_bin "$ENV{STM32_GCC_ROOT}/bin")
  set(CMAKE_C_COMPILER "${_configured_gcc_bin}/arm-none-eabi-gcc${_tool_suffix}" CACHE FILEPATH "" FORCE)
  set(CMAKE_CXX_COMPILER "${_configured_gcc_bin}/arm-none-eabi-g++${_tool_suffix}" CACHE FILEPATH "" FORCE)
  set(CMAKE_ASM_COMPILER "${_configured_gcc_bin}/arm-none-eabi-gcc${_tool_suffix}" CACHE FILEPATH "" FORCE)
  set(CMAKE_OBJCOPY "${_configured_gcc_bin}/arm-none-eabi-objcopy${_tool_suffix}" CACHE FILEPATH "" FORCE)
  set(CMAKE_SIZE "${_configured_gcc_bin}/arm-none-eabi-size${_tool_suffix}" CACHE FILEPATH "" FORCE)
else()
  set(_gcc_hints
    "$ENV{ARM_GNU_TOOLCHAIN_ROOT}/bin"
    "$ENV{STM32_CUBE_CLT_ROOT}/GNU-tools-for-STM32/bin")
  find_program(CMAKE_C_COMPILER arm-none-eabi-gcc HINTS ${_gcc_hints} REQUIRED)
  find_program(CMAKE_CXX_COMPILER arm-none-eabi-g++ HINTS ${_gcc_hints} REQUIRED)
  find_program(CMAKE_ASM_COMPILER arm-none-eabi-gcc HINTS ${_gcc_hints} REQUIRED)
  find_program(CMAKE_OBJCOPY arm-none-eabi-objcopy HINTS ${_gcc_hints} REQUIRED)
  find_program(CMAKE_SIZE arm-none-eabi-size HINTS ${_gcc_hints} REQUIRED)
endif()
set(CMAKE_EXECUTABLE_SUFFIX ".elf")
'@
    Write-Utf8NoBom (Join-Path $configDir 'cmake/arm-none-eabi-gcc.cmake') $toolchain

    $cmakeLists = @'
cmake_minimum_required(VERSION 3.20)
include(cmake/stm32-project.cmake)
project(${STM32_PROJECT_NAME} LANGUAGES C CXX ASM)

if(STM32_ARTIFACT_TYPE STREQUAL "staticLibrary")
  add_library(${PROJECT_NAME} STATIC ${STM32_SOURCES})
else()
  add_executable(${PROJECT_NAME} ${STM32_SOURCES})
endif()
target_include_directories(${PROJECT_NAME} PRIVATE
  ${STM32_INCLUDE_DIRS}
  $<$<COMPILE_LANGUAGE:ASM>:${STM32_ASM_INCLUDE_DIRS}>)
target_compile_definitions(${PROJECT_NAME} PRIVATE
  ${STM32_DEFINES}
  $<$<COMPILE_LANGUAGE:ASM>:${STM32_ASM_DEFINES}>)
target_compile_options(${PROJECT_NAME} PRIVATE
  ${STM32_CPU_FLAGS}
  $<$<COMPILE_LANGUAGE:C,CXX>:${STM32_C_COMPILE_OPTIONS}>
  $<$<COMPILE_LANGUAGE:ASM>:${STM32_ASM_OPTIONS}>
  $<$<CONFIG:Debug>:${STM32_DEBUG_OPTIMIZATION};${STM32_DEBUG_INFORMATION};${STM32_DEBUG_OPTIONS}>
  $<$<CONFIG:Release>:${STM32_RELEASE_OPTIMIZATION};${STM32_RELEASE_DEBUG_INFORMATION};${STM32_RELEASE_OPTIONS}>)
set_target_properties(${PROJECT_NAME} PROPERTIES
  C_STANDARD ${STM32_C_STANDARD} C_EXTENSIONS ${STM32_C_EXTENSIONS}
  CXX_STANDARD ${STM32_CXX_STANDARD} CXX_EXTENSIONS ${STM32_CXX_EXTENSIONS})

if(NOT STM32_ARTIFACT_TYPE STREQUAL "staticLibrary")
  target_link_directories(${PROJECT_NAME} PRIVATE ${STM32_LIBRARY_DIRECTORIES})
  target_link_libraries(${PROJECT_NAME} PRIVATE ${STM32_LIBRARIES})
  target_link_options(${PROJECT_NAME} PRIVATE
    ${STM32_CPU_FLAGS} -T${STM32_LINKER_SCRIPT} ${STM32_LINK_OPTIONS}
    --specs=nano.specs --specs=nosys.specs)
  set_target_properties(${PROJECT_NAME} PROPERTIES SUFFIX ".elf")
  if(STM32_CREATE_HEX)
    add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
      COMMAND ${CMAKE_OBJCOPY} -O ihex $<TARGET_FILE:${PROJECT_NAME}> ${PROJECT_NAME}.hex)
  endif()
  if(STM32_CREATE_BIN)
    add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
      COMMAND ${CMAKE_OBJCOPY} -O binary $<TARGET_FILE:${PROJECT_NAME}> ${PROJECT_NAME}.bin)
  endif()
  add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
    COMMAND ${CMAKE_SIZE} $<TARGET_FILE:${PROJECT_NAME}>)
endif()
'@
    Write-Utf8NoBom (Join-Path $configDir 'CMakeLists.txt') $cmakeLists

    $presets = @{
        version = 6
        configurePresets = @(
            @{ name='debug'; displayName='STM32 Debug'; generator='Ninja'; binaryDir='${sourceDir}/build/debug'; toolchainFile='${sourceDir}/cmake/arm-none-eabi-gcc.cmake'; cacheVariables=@{ CMAKE_BUILD_TYPE='Debug'; CMAKE_EXPORT_COMPILE_COMMANDS='ON' } },
            @{ name='release'; displayName='STM32 Release'; generator='Ninja'; binaryDir='${sourceDir}/build/release'; toolchainFile='${sourceDir}/cmake/arm-none-eabi-gcc.cmake'; cacheVariables=@{ CMAKE_BUILD_TYPE='Release'; CMAKE_EXPORT_COMPILE_COMMANDS='ON' } }
        )
        buildPresets = @(@{name='debug';configurePreset='debug'}, @{name='release';configurePreset='release'})
    } | ConvertTo-Json -Depth 10
    Write-Utf8NoBom (Join-Path $configDir 'CMakePresets.json') $presets

    if (($Manifest.PSObject.Properties.Name -contains 'linkerScriptProvider') -and [string]$Manifest.linkerScriptProvider -eq 'cubemx') {
        $cubeMxLinker = Join-Path $configDir ([string]$Manifest.linkerScriptBase)
        $effectiveLinker = Join-Path $configDir ([string]$Manifest.linkerScript)
        $effectiveParent = Split-Path -Parent $effectiveLinker
        if (-not (Test-Path -LiteralPath $effectiveParent)) { New-Item -ItemType Directory -Force -Path $effectiveParent | Out-Null }
        Copy-Item -LiteralPath $cubeMxLinker -Destination $effectiveLinker -Force
        Update-LinkerScriptMemory $Manifest $effectiveLinker
    } else {
        New-LinkerScript $Manifest $configDir
    }
    Write-VscodeFiles $Manifest $Root
}

function Write-VscodeFiles($Manifest, [string]$Root) {
    $configDir = Get-ProjectConfigDir $Root
    $debugOutputDir = (Join-Path $configDir 'build/debug').Replace('\','/')
    $llvm = Find-Executable 'clangd' @((Get-EnvironmentToolPath 'LLVM_ROOT' 'bin/clangd.exe'))
    $gccRoot = Find-ToolchainRoot
    $gccBin = if ($gccRoot) { (Join-Path $gccRoot 'bin').Replace('\','/') } else { '' }
    $clangdArgs = @("--compile-commands-dir=$debugOutputDir",'--background-index','--clang-tidy','--completion-style=detailed')
    if ($gccBin) { $clangdArgs += "--query-driver=$gccBin/arm-none-eabi-*" }
    $programmer = Find-Executable 'STM32_Programmer_CLI' @((Get-EnvironmentToolPath 'STM32_CUBE_CLT_ROOT' 'STM32CubeProgrammer/bin/STM32_Programmer_CLI.exe'))
    $probe = if ($Manifest.debug.probe) { [string]$Manifest.debug.probe } else { 'openocd' }
    $debugProperties = @($Manifest.debug.PSObject.Properties.Name)
    $debugInterface = if ($debugProperties -contains 'interface') { [string]$Manifest.debug.interface } else { 'swd' }
    $debugSpeed = if ($debugProperties -contains 'speedKhz') { [int]$Manifest.debug.speedKhz } else { 4000 }
    $debugSerial = if ($debugProperties -contains 'serialNumber') { [string]$Manifest.debug.serialNumber } else { '' }
    $runToEntryPoint = if (($debugProperties -contains 'runToEntryPoint') -and $Manifest.debug.runToEntryPoint) { [string]$Manifest.debug.runToEntryPoint } else { 'main' }
    $extraServerArgs = if ($debugProperties -contains 'serverArgs') { @($Manifest.debug.serverArgs) } else { @() }
    $serverPath = if ($probe -eq 'stlink') {
        Find-Executable 'ST-LINK_gdbserver' @((Get-EnvironmentToolPath 'STM32_CUBE_CLT_ROOT' 'STLink-gdb-server/bin/ST-LINK_gdbserver.exe'))
    } elseif ($probe -eq 'openocd') {
        Find-Executable 'openocd' @((Get-EnvironmentToolPath 'STM32_CUBE_CLT_ROOT' 'OpenOCD/bin/openocd.exe'))
    } elseif ($probe -eq 'jlink') {
        Find-JLinkGdbServer
    } else { '' }
    if (-not $serverPath -and $probe -eq 'stlink') { $serverPath = 'ST-LINK_gdbserver.exe' }
    $gdbPath = if ($gccBin) { "$gccBin/arm-none-eabi-gdb.exe" } else { 'arm-none-eabi-gdb' }

    $settings = [ordered]@{
        'cmake.useCMakePresets'='always'
        'cmake.sourceDirectory'=$configDir.Replace('\','/')
        'cmake.configureOnOpen'= $true
        'cmake.copyCompileCommands'='${workspaceFolder}/compile_commands.json'
        'clangd.path'= $llvm.Replace('\','/')
        'clangd.arguments'=$clangdArgs
        'C_Cpp.intelliSenseEngine'='disabled'
        'stm32.gccBinPath'=$gccBin
        'stm32.programmerPath'=$programmer.Replace('\','/')
        'stm32.debugServerPath'=$serverPath.Replace('\','/')
        'stm32.gdbPath'=$gdbPath
        'stm32.svdFile'=$Manifest.debug.svdFile
    } | ConvertTo-Json -Depth 10
    Write-Utf8NoBom (Join-Path $Root '.vscode/settings.json') $settings

    $programmerPort = if ($probe -eq 'jlink') { 'JLINK' } else { 'SWD' }
    $portableEntry = (Join-Path $ToolRoot 'stm32.ps1').Replace('\','/')
    $projectPath = (Resolve-FullPath $Root).Replace('\','/')
    $tasks = @"
{
  "version": "2.0.0",
  "tasks": [
    { "label": "STM32: Configure Debug", "type": "shell", "command": "pwsh", "args": ["-NoProfile", "-File", "$portableEntry", "configure", "-ProjectRoot", "$projectPath", "-Config", "Debug"], "problemMatcher": [] },
    { "label": "STM32: Build Debug", "type": "shell", "command": "pwsh", "args": ["-NoProfile", "-File", "$portableEntry", "build", "-ProjectRoot", "$projectPath", "-Config", "Debug"], "group": { "kind": "build", "isDefault": true }, "problemMatcher": ["`$gcc"] },
    { "label": "STM32: Build Release", "type": "shell", "command": "pwsh", "args": ["-NoProfile", "-File", "$portableEntry", "build", "-ProjectRoot", "$projectPath", "-Config", "Release"], "problemMatcher": ["`$gcc"] },
    { "label": "STM32: Flash at configured address", "type": "shell", "dependsOn": "STM32: Build Debug", "command": "`${config:stm32.programmerPath}", "args": ["-c", "port=$programmerPort", "-d", "$debugOutputDir/$($Manifest.name).bin", "$($Manifest.loadAddress)", "-v", "-rst"], "problemMatcher": [] }
  ]
}
"@
    Write-Utf8NoBom (Join-Path $Root '.vscode/tasks.json') $tasks

    $configFiles = ($Manifest.debug.openocdConfigFiles | ForEach-Object { '"' + $_ + '"' }) -join ', '
    $svdLine = if ($Manifest.debug.svdFile) { '      "svdFile": "${workspaceFolder}/' + $Manifest.debug.svdFile + '",' } else { '' }
    $backendArgs = if ($probe -eq 'jlink') { @('-speed', [string]$debugSpeed) }
        elseif ($probe -eq 'stlink') { @('--frequency', [string]$debugSpeed) }
        elseif ($probe -eq 'openocd') { @('-c', "adapter speed $debugSpeed") }
        else { @() }
    $allServerArgs = @($backendArgs + $extraServerArgs)
    $serverArgsJson = ConvertTo-Json -InputObject $allServerArgs -Compress
    $serialLine = if ($debugSerial) { '      "serialNumber": "' + $debugSerial + '",' } else { '' }
    $serverPathLine = if ($serverPath) { '      "serverpath": "${config:stm32.debugServerPath}",' } else { '' }
    $vectorBase = Format-Hex (Convert-HexToInt ([string]$Manifest.debugAddress))
    $resetVectorAddress = Format-Hex ((Convert-HexToInt $vectorBase) + 4)
    $vectorStartCommands = @(
        "set {unsigned int}0xE000ED08 = $vectorBase",
        "set `$sp = *(unsigned int*)$vectorBase",
        "set `$pc = *(unsigned int*)$resetVectorAddress"
    )
    $vectorStartCommandsJson = ConvertTo-Json -InputObject $vectorStartCommands -Compress
    $serverSpecific = if ($probe -eq 'openocd') {
        '      "interface": "' + $debugInterface + '",' + "`n" + '      "serverArgs": ' + $serverArgsJson + ',' + "`n" + '      "configFiles": [' + $configFiles + '],'
    } elseif ($probe -eq 'stlink') {
        '      "interface": "' + $debugInterface + '",' + "`n" + '      "serverArgs": ' + $serverArgsJson + ',' + "`n" + '      "stm32cubeprogrammer": "' + (Split-Path -Parent $programmer).Replace('\','/') + '",' 
    } elseif ($probe -eq 'jlink') {
        '      "interface": "' + $debugInterface + '",' + "`n" + '      "serverArgs": ' + $serverArgsJson + ','
    } else { '' }
    $launch = @"
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "STM32: Download and debug",
      "cwd": "`${workspaceFolder}",
      "executable": "$debugOutputDir/$($Manifest.name).elf",
      "request": "launch",
      "type": "cortex-debug",
      "servertype": "$probe",
$serverPathLine
      "gdbPath": "`${config:stm32.gdbPath}",
      "armToolchainPath": "`${config:stm32.gccBinPath}",
      "device": "$($Manifest.device)",
$serverSpecific
$serialLine
$svdLine
      "postLaunchCommands": $vectorStartCommandsJson,
      "postResetCommands": $vectorStartCommandsJson,
      "runToEntryPoint": "$runToEntryPoint",
      "preLaunchTask": "STM32: Build Debug",
      "showDevDebugOutput": "none"
    },
    {
      "name": "STM32: Attach at configured vector table",
      "cwd": "`${workspaceFolder}",
      "executable": "$debugOutputDir/$($Manifest.name).elf",
      "request": "attach",
      "type": "cortex-debug",
      "servertype": "$probe",
$serverPathLine
      "gdbPath": "`${config:stm32.gdbPath}",
      "armToolchainPath": "`${config:stm32.gccBinPath}",
      "device": "$($Manifest.device)",
$serverSpecific
$serialLine
$svdLine
      "postAttachCommands": $vectorStartCommandsJson
    }
  ]
}
"@
    Write-Utf8NoBom (Join-Path $Root '.vscode/launch.json') $launch

    $extensions = '{"recommendations":["llvm-vs-code-extensions.vscode-clangd","ms-vscode.cmake-tools","marus25.cortex-debug"],"unwantedRecommendations":["STMicroelectronics.stm32cube-ide-clangd"]}'
    Write-Utf8NoBom (Join-Path $Root '.vscode/extensions.json') $extensions
}

function Convert-LittleEndianHexWord([string]$HexWord) {
    if ($HexWord -notmatch '^[0-9A-Fa-f]{8}$') { throw "Invalid 32-bit vector word: $HexWord" }
    $bytes = @()
    for ($index = 0; $index -lt 8; $index += 2) { $bytes += $HexWord.Substring($index, 2) }
    [array]::Reverse($bytes)
    return [Convert]::ToInt64(($bytes -join ''), 16)
}

function Test-Stm32BuildOutput($Manifest, [string]$Root, [string]$Cfg) {
    if ([string]$Manifest.output.artifactType -eq 'staticLibrary') { return }

    $configDir = Get-ProjectConfigDir $Root
    $elf = Join-Path $configDir ("build/{0}/{1}.elf" -f $Cfg.ToLowerInvariant(), $Manifest.name)
    if (-not (Test-Path -LiteralPath $elf)) { throw "Build completed but ELF was not generated: $elf" }

    $gccRoot = Find-ToolchainRoot
    $objdump = Find-Executable 'arm-none-eabi-objdump' @(
        $(if ($gccRoot) { Join-Path $gccRoot 'bin/arm-none-eabi-objdump.exe' } else { '' })
    )
    $nm = Find-Executable 'arm-none-eabi-nm' @(
        $(if ($gccRoot) { Join-Path $gccRoot 'bin/arm-none-eabi-nm.exe' } else { '' })
    )
    if (-not $objdump -or -not $nm) {
        throw 'Build verification requires arm-none-eabi-objdump and arm-none-eabi-nm beside the configured GCC toolchain.'
    }

    $sectionResult = Invoke-NativeCapture $objdump @('-h', $elf)
    if ($sectionResult.ExitCode) { throw "Unable to inspect ELF sections with $objdump. $($sectionResult.Error.Trim())" }
    $vectorSection = $sectionResult.Lines | Where-Object { $_ -match '^\s*\d+\s+\.isr_vector\s+[0-9A-Fa-f]+\s+([0-9A-Fa-f]+)' } | Select-Object -First 1
    if (-not $vectorSection) { throw 'ELF does not contain an .isr_vector section.' }
    [void]($vectorSection -match '^\s*\d+\s+\.isr_vector\s+[0-9A-Fa-f]+\s+([0-9A-Fa-f]+)')
    $vectorAddress = [Convert]::ToInt64($Matches[1], 16)
    $expectedVectorAddress = Convert-HexToInt ([string]$Manifest.debugAddress)
    if ($vectorAddress -ne $expectedVectorAddress) {
        throw ("ELF vector table is at {0}, but debugAddress is {1}. Check loadAddress/addressPolicy/linker configuration." -f (Format-Hex $vectorAddress), (Format-Hex $expectedVectorAddress))
    }

    $vectorResult = Invoke-NativeCapture $objdump @('-s', '-j', '.isr_vector', $elf)
    if ($vectorResult.ExitCode) { throw "Unable to read the ELF vector table with $objdump. $($vectorResult.Error.Trim())" }
    $vectorData = $vectorResult.Lines | Where-Object { $_ -match '^\s*[0-9A-Fa-f]+\s+([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})' } | Select-Object -First 1
    if (-not $vectorData) { throw 'ELF .isr_vector section is empty or unreadable.' }
    [void]($vectorData -match '^\s*[0-9A-Fa-f]+\s+([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})')
    $initialSp = Convert-LittleEndianHexWord $Matches[1]
    $resetVector = Convert-LittleEndianHexWord $Matches[2]

    $ramOrigin = Convert-HexToInt ([string]$Manifest.memory.ram.origin)
    $ramEnd = $ramOrigin + (Convert-HexToInt ([string]$Manifest.memory.ram.length))
    if ($initialSp -lt $ramOrigin -or $initialSp -gt $ramEnd) {
        throw ("Initial MSP {0} is outside configured RAM {1}..{2}." -f (Format-Hex $initialSp), (Format-Hex $ramOrigin), (Format-Hex $ramEnd))
    }
    if (($resetVector -band 1) -eq 0) { throw ("Reset vector {0} is not a Thumb address." -f (Format-Hex $resetVector)) }

    $flashOrigin = Convert-HexToInt ([string]$Manifest.memory.flash.origin)
    $flashEnd = $flashOrigin + (Convert-HexToInt ([string]$Manifest.memory.flash.length))
    $resetCodeAddress = $resetVector -band (-bnot 1)
    if ($resetCodeAddress -lt $flashOrigin -or $resetCodeAddress -ge $flashEnd) {
        throw ("Reset vector {0} is outside configured FLASH {1}..{2}." -f (Format-Hex $resetVector), (Format-Hex $flashOrigin), (Format-Hex ($flashEnd - 1)))
    }

    $entryPoint = if (($Manifest.debug.PSObject.Properties.Name -contains 'runToEntryPoint') -and $Manifest.debug.runToEntryPoint) { [string]$Manifest.debug.runToEntryPoint } else { 'main' }
    $symbolResult = Invoke-NativeCapture $nm @('-n', $elf)
    if ($symbolResult.ExitCode) { throw "Unable to inspect ELF symbols with $nm. $($symbolResult.Error.Trim())" }
    $entrySymbol = $symbolResult.Lines | Where-Object { $_ -match ('^\s*([0-9A-Fa-f]+)\s+\w\s+' + [regex]::Escape($entryPoint) + '$') } | Select-Object -First 1
    if (-not $entrySymbol) { throw "Configured runToEntryPoint symbol '$entryPoint' was not found in the ELF." }
    [void]($entrySymbol -match '^\s*([0-9A-Fa-f]+)')
    $entryAddress = [Convert]::ToInt64($Matches[1], 16)

    $launchPath = Join-Path $Root '.vscode/launch.json'
    $launchJson = Get-Content -Raw -LiteralPath $launchPath | ConvertFrom-Json
    $launchConfig = $launchJson.configurations | Where-Object { $_.request -eq 'launch' } | Select-Object -First 1
    if (-not $launchConfig -or [string]$launchConfig.runToEntryPoint -ne $entryPoint) {
        throw "Generated launch.json does not target '$entryPoint'."
    }
    $expectedCommands = @(
        "set {unsigned int}0xE000ED08 = $(Format-Hex $expectedVectorAddress)",
        "set `$sp = *(unsigned int*)$(Format-Hex $expectedVectorAddress)",
        "set `$pc = *(unsigned int*)$(Format-Hex ($expectedVectorAddress + 4))"
    )
    if ((@($launchConfig.postLaunchCommands) -join "`n") -ne ($expectedCommands -join "`n")) {
        throw 'Generated launch.json vector-table initialization does not match debugAddress.'
    }

    $debugServer = [string]$launchConfig.serverpath
    $settingsPath = Join-Path $Root '.vscode/settings.json'
    $settingsJson = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
    $resolvedDebugServer = [string]$settingsJson.'stm32.debugServerPath'
    if ($debugServer -and (-not $resolvedDebugServer -or -not (Test-Path -LiteralPath $resolvedDebugServer))) {
        Write-Warning "Debug server for '$($Manifest.debug.probe)' was not found. Build output is valid, but VS Code debugging requires its GDB server. Configure tools.jlinkRoot/tools.cubeCltRoot as appropriate."
    }

    Write-Host ''
    Write-Host 'STM32 build verification PASSED' -ForegroundColor Green
    Write-Host ("  ELF          : {0}" -f $elf)
    Write-Host ("  Vector table : {0}" -f (Format-Hex $vectorAddress))
    Write-Host ("  Initial MSP  : {0}" -f (Format-Hex $initialSp))
    Write-Host ("  Reset vector : {0}" -f (Format-Hex $resetVector))
    Write-Host ("  Entry {0,-6}: {1}" -f $entryPoint, (Format-Hex $entryAddress))
    Write-Host ("  Debug probe  : {0}" -f $Manifest.debug.probe)
    Write-Host ("  Debug server : {0}" -f $(if ($resolvedDebugServer) { $resolvedDebugServer } else { 'NOT FOUND' }))
}

function Import-NativeCMakeProject([string]$Root, [string]$RequestedTarget, [string]$UvPath, [string]$SelectedChipConfig) {
    $Root = Resolve-FullPath $Root
    $cmakeListsPath = Join-Path $Root 'CMakeLists.txt'
    if (-not (Test-Path -LiteralPath $cmakeListsPath)) { throw "Native CMake project not found: $cmakeListsPath" }

    $presetName = $Config
    $presetsPath = Join-Path $Root 'CMakePresets.json'
    if (Test-Path -LiteralPath $presetsPath) {
        $presets = Get-Content -Raw -LiteralPath $presetsPath | ConvertFrom-Json
        $availablePresets = @($presets.configurePresets | Where-Object { -not ($_.PSObject.Properties.Name -contains 'hidden') -or -not $_.hidden })
        $matchedPreset = $availablePresets | Where-Object { [string]$_.name -ieq $Config } | Select-Object -First 1
        if (-not $matchedPreset) { $matchedPreset = $availablePresets | Select-Object -First 1 }
        if ($matchedPreset) { $presetName = [string]$matchedPreset.name }
    }

    Write-Host "Reading native CMake project with preset '$presetName': $Root" -ForegroundColor Cyan
    Push-Location $Root
    try {
        & cmake --preset $presetName -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
        if ($LASTEXITCODE) { throw "Native CMake configure failed ($LASTEXITCODE)" }
    } finally { Pop-Location }

    $rootCompileDatabase = Join-Path $Root 'compile_commands.json'
    $compileDatabase = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'compile_commands.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/]CMake-GCC[\\/]' -and $_.FullName -ne $rootCompileDatabase } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $compileDatabase) { throw "CMake did not generate compile_commands.json below $Root" }
    $commands = @(Get-Content -Raw -LiteralPath $compileDatabase.FullName | ConvertFrom-Json)
    if ($commands.Count -eq 0) { throw "Compile database is empty: $($compileDatabase.FullName)" }

    $sources = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $includes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $defines = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $allCommandText = [Collections.Generic.List[string]]::new()
    $uvDirectory = (Split-Path -Parent (Resolve-FullPath $UvPath $Root)).TrimEnd('\') + '\'
    foreach ($entry in $commands) {
        $source = Resolve-FullPath ([string]$entry.file) ([string]$entry.directory)
        if ((Test-Path -LiteralPath $source) -and $source.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) -and -not $source.StartsWith($uvDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            [void]$sources.Add((Get-RelativePath $Root $source))
        }
        $commandText = if ($entry.command) { [string]$entry.command } else { (@($entry.arguments) -join ' ') }
        $allCommandText.Add($commandText)
        foreach ($match in [regex]::Matches($commandText, '(?:^|\s)-I(?:"([^"]+)"|([^\s"]+))')) {
            $value = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
            $fullInclude = Resolve-FullPath $value ([string]$entry.directory)
            if (Test-Path -LiteralPath $fullInclude) { [void]$includes.Add((Get-RelativePath $Root $fullInclude)) }
        }
        foreach ($match in [regex]::Matches($commandText, '(?:^|\s)-D(?:"([^"]+)"|([^\s"]+))')) {
            $value = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
            if ($value -and $value -notmatch '^DEBUG$') { [void]$defines.Add($value) }
        }
    }
    $combinedCommands = $allCommandText -join "`n"
    $cpu = if ($combinedCommands -match '-mcpu=([^\s]+)') { $Matches[1] } else { 'cortex-m3' }
    $fpu = if ($combinedCommands -match '-mfpu=([^\s]+)') { $Matches[1] } else { '' }
    $floatAbi = if ($combinedCommands -match '-mfloat-abi=([^\s]+)') { $Matches[1] } else { 'soft' }
    $optimizationMatches = [regex]::Matches($combinedCommands, '(?<!\S)-O(0|1|2|3|g|s|fast)(?!\S)')
    $detectedOptimization = if ($optimizationMatches.Count) { 'O' + $optimizationMatches[$optimizationMatches.Count - 1].Groups[1].Value } else { 'Og' }
    $standardMatch = [regex]::Match($combinedCommands, '-std=(gnu)?c(90|99|11|17|23)')
    $cStandard = if ($standardMatch.Success) { [int]$standardMatch.Groups[2].Value } else { 11 }
    $cExtensions = $standardMatch.Success -and $standardMatch.Groups[1].Success

    $linkerScriptFile = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.ld' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](build|CMake-GCC)[\\/]' } |
        Sort-Object @{Expression={if($_.Name -match 'FLASH'){0}else{1}}}, FullName | Select-Object -First 1
    $flashOrigin='0x08000000'; $flashLength='0x00040000'; $ramOrigin='0x20000000'; $ramLength='0x00020000'
    if ($linkerScriptFile) {
        $linkerText = Get-Content -Raw -LiteralPath $linkerScriptFile.FullName
        $flashMatch = [regex]::Match($linkerText, '(?im)^\s*FLASH[^:]*:\s*ORIGIN\s*=\s*([^,\s]+)\s*,\s*LENGTH\s*=\s*([^\s/]+)')
        $ramMatch = [regex]::Match($linkerText, '(?im)^\s*RAM[^:]*:\s*ORIGIN\s*=\s*([^,\s]+)\s*,\s*LENGTH\s*=\s*([^\s/]+)')
        if ($flashMatch.Success) { $flashOrigin=$flashMatch.Groups[1].Value; $flashLength=$flashMatch.Groups[2].Value }
        if ($ramMatch.Success) { $ramOrigin=$ramMatch.Groups[1].Value; $ramLength=$ramMatch.Groups[2].Value }
    }
    $deviceDefine = @($defines) | Where-Object { $_ -match '^STM32[A-Z0-9]+x[A-Z0-9]+$' } | Select-Object -First 1
    $targetName = if ($RequestedTarget) { $RequestedTarget } else { Split-Path $Root -Leaf }
    $uvFullPath = Resolve-FullPath $UvPath $Root
    $manifest = [pscustomobject][ordered]@{
        schemaVersion=1; sourceRoot=$Root.Replace('\','/'); name=$targetName; device=if($deviceDefine){$deviceDefine}else{'STM32'}
        uvprojx=Get-RelativePath $Root $uvFullPath; uvTarget=$targetName
        arch=[ordered]@{cpu=$cpu;fpu=$fpu;floatAbi=$floatAbi}
        memory=[ordered]@{flash=[ordered]@{origin=$flashOrigin;length=$flashLength};ram=[ordered]@{origin=$ramOrigin;length=$ramLength}}
        loadAddress=$flashOrigin; debugAddress=$flashOrigin; linkerScript='cmake/stm32-linker.ld'
        optimization=[ordered]@{debug=$detectedOptimization;release=$detectedOptimization;debugInfo='g3';releaseDebugInfo='g1'}
        compiler=[ordered]@{cStandard=$cStandard;cExtensions=$cExtensions;cppStandard=17;cppExtensions=$true;warnings='default';warningsAsErrors=$false;signedChar=$false;shortEnums=$false;shortWchar=$false;lto=$false;functionSections=$true;dataSections=$true;strictAnsi=$false;ropi=$false;rwpi=$false;executeOnly=$false;splitLoadStore=$false;noAutoIncludes=$false;optimizationGoal='speed';commonOptions=@();debugOptions=@();releaseOptions=@();undefines=@();keilMiscControls=''}
        assembler=[ordered]@{defines=@();includeDirectories=@();options=@();keilMiscControls=''}
        linker=[ordered]@{gcSections=$true;mapFile=$true;lto=$false;noStandardLibraries=$false;libraries=@();libraryDirectories=@();options=@();scatterFile='';keilMiscControls='';disabledWarnings=''}
        output=[ordered]@{artifactType='executable';hex=$true;bin=$true;debugInformation=$true;browseInformation=$true;outputDirectory='';listingPath=''}
        buildSteps=[ordered]@{importedKeilCommandsEnabled=$false;beforeCompile=@();beforeBuild=@();afterBuild=@()}
        nativeCMake=[ordered]@{sourceDirectory=$Root.Replace('\','/');preset=$presetName;compileCommands=$compileDatabase.FullName.Replace('\','/');linkerScript=if($linkerScriptFile){(Get-RelativePath $Root $linkerScriptFile.FullName)}else{''}}
        keilCompiler=$KeilCompiler
        sources=@($sources | Sort-Object);includeDirectories=@($includes | Sort-Object)
        baseDefines=@($defines | Sort-Object);chipDefines=@();extraDefines=@();defines=@($defines | Sort-Object);sourceOptions=@()
        debug=[ordered]@{probe='stlink';openocdConfigFiles=@('interface/stlink.cfg','target/stm32f4x.cfg');svdFile=''}
    }
    $manifest = Apply-ChipConfig $manifest $SelectedChipConfig $Root
    $manifest = Apply-OptimizationOptions $manifest
    $manifest = Apply-ExtraDefines $manifest
    $manifest = Remove-KeilOnlySources $manifest $Root
    $configDir = Get-ProjectConfigDir $Root
    Write-Utf8NoBom (Join-Path $configDir 'stm32-project.json') ($manifest | ConvertTo-Json -Depth 20)
    Write-GeneratedProject $manifest $Root
    Write-Host "Imported native CMake project: $($compileDatabase.FullName)" -ForegroundColor Green
    return $manifest
}

function Import-Uvprojx([string]$Path, [string]$Root, [string]$RequestedTarget, [string]$SelectedChipConfig) {
    $uv = Resolve-FullPath $Path
    if (-not (Test-Path -LiteralPath $uv)) { throw "uvprojx not found: $uv" }
    if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $uv) }
    $Root = Resolve-FullPath $Root
    [xml]$xml = Get-Content -Raw -LiteralPath $uv
    $targets = @($xml.Project.Targets.Target)
    $target = if ($RequestedTarget) { $targets | Where-Object TargetName -eq $RequestedTarget | Select-Object -First 1 } else { $targets[0] }
    if (-not $target) { throw "Target '$RequestedTarget' not found." }
    $uvDir = Split-Path -Parent $uv
    $common = $target.TargetOption.TargetCommonOption
    $arm = $target.TargetOption.TargetArmAds
    $irom = $arm.ArmAdsMisc.OnChipMemories.IROM
    $iram = $arm.ArmAdsMisc.OnChipMemories.IRAM
    $cpuOptions = Get-CpuOptions $common.Cpu $common.Device

    $sources = [Collections.Generic.List[string]]::new()
    foreach ($group in @($target.Groups.Group)) {
        if (-not ($group.PSObject.Properties.Name -contains 'Files') -or -not ($group.Files.PSObject.Properties.Name -contains 'File')) { continue }
        foreach ($file in @($group.Files.File)) {
            if (($file.PSObject.Properties.Name -contains 'FileOption') -and [string]$file.FileOption.CommonProperty.IncludeInBuild -eq '0') { continue }
            $source = Resolve-FullPath ([string]$file.FilePath) $uvDir
            if ($file.FileType -eq '2' -and (Split-Path -Leaf $source) -match '^startup_') {
                $gccStartup = Get-ChildItem $Root -Recurse -File -Filter (Split-Path -Leaf $source) -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName.Replace('\','/') -match '/Templates/gcc/' } | Select-Object -First 1
                if ($gccStartup) { $source = $gccStartup.FullName }
            }
            if (Test-Path -LiteralPath $source) { $sources.Add((Get-RelativePath $Root $source)) }
            else { Write-Warning "Source does not exist and was skipped: $source" }
        }
    }
    $includes = @(([string]$arm.Cads.VariousControls.IncludePath) -split ';' | Where-Object { $_ } | ForEach-Object { Get-RelativePath $Root (Resolve-FullPath $_ $uvDir) })
    $defines = @(([string]$arm.Cads.VariousControls.Define) -split '[,; ]+' | Where-Object { $_ })
    $undefines = @(([string]$arm.Cads.VariousControls.Undefine) -split '[,; ]+' | Where-Object { $_ })
    $asmIncludes = @(([string]$arm.Aads.VariousControls.IncludePath) -split ';' | Where-Object { $_ } | ForEach-Object { Get-RelativePath $Root (Resolve-FullPath $_ $uvDir) })
    $asmDefines = @(([string]$arm.Aads.VariousControls.Define) -split '[,; ]+' | Where-Object { $_ })
    $keilOptimization = Convert-KeilOptimization ([int]$arm.Cads.Optim)
    $warningMode = switch ([string]$arm.Cads.wLevel) { '1' {'none'} '2' {'all'} default {'default'} }
    $artifactType = if ([string]$common.CreateLib -eq '1') { 'staticLibrary' } else { 'executable' }
    $libraries = @((([string]$arm.LDads.IncludeLibs), ([string]$arm.LDads.LinkerInputFile)) -join ';' -split '[;,]' | ForEach-Object Trim | Where-Object { $_ })
    $libraryDirectories = @(([string]$arm.LDads.IncludeLibsPath) -split ';' | Where-Object { $_ } | ForEach-Object { Get-RelativePath $Root (Resolve-FullPath $_ $uvDir) })
    $flashOrigin = Format-Hex (Convert-HexToInt ([string]$irom.StartAddress))
    $flashSize = Format-Hex (Convert-HexToInt ([string]$irom.Size))
    $ramOrigin = Format-Hex (Convert-HexToInt ([string]$iram.StartAddress))
    $ramSize = Format-Hex (Convert-HexToInt ([string]$iram.Size))
    $manifest = [ordered]@{
        schemaVersion = 1
        sourceRoot = $Root.Replace('\','/')
        name = [string]$target.TargetName
        device = [string]$common.Device
        uvprojx = Get-RelativePath $Root $uv
        uvTarget = [string]$target.TargetName
        arch = $cpuOptions
        memory = [ordered]@{ flash=[ordered]@{origin=$flashOrigin;length=$flashSize}; ram=[ordered]@{origin=$ramOrigin;length=$ramSize} }
        loadAddress = $flashOrigin
        debugAddress = $flashOrigin
        linkerScript = 'cmake/stm32-linker.ld'
        optimization = [ordered]@{ debug=$keilOptimization; release=$keilOptimization; debugInfo='g3'; releaseDebugInfo='g1' }
        compiler = [ordered]@{
            cStandard=if ([string]$arm.Cads.uC99 -eq '1') {99} else {90}
            cExtensions=([string]$arm.Cads.uGnu -eq '1')
            cppStandard=17; cppExtensions=$true
            warnings=$warningMode; warningsAsErrors=([string]$arm.Cads.v6WtE -eq '1')
            signedChar=([string]$arm.Cads.PlainCh -eq '1')
            shortEnums=([string]$arm.Cads.EnumInt -ne '1')
            shortWchar=([string]$target.uAC6 -eq '1' -and [string]$arm.Cads.vShortWch -eq '1')
            lto=([string]$target.uAC6 -eq '1' -and [string]$arm.Cads.v6Lto -eq '1')
            functionSections=([string]$arm.Cads.OneElfS -eq '1')
            dataSections=$true
            strictAnsi=([string]$arm.Cads.Strict -eq '1')
            ropi=([string]$arm.Cads.Ropi -eq '1')
            rwpi=([string]$arm.Cads.Rwpi -eq '1')
            executeOnly=([string]$arm.Cads.useXO -eq '1')
            splitLoadStore=([string]$arm.Cads.SplitLS -eq '1')
            noAutoIncludes=([string]$arm.Cads.uSurpInc -eq '1')
            optimizationGoal=if ([string]$arm.Cads.oTime -eq '1') {'speed'} else {'size'}
            commonOptions=@(); debugOptions=@(); releaseOptions=@(); undefines=$undefines
            keilMiscControls=[string]$arm.Cads.VariousControls.MiscControls
        }
        assembler = [ordered]@{ defines=$asmDefines; includeDirectories=$asmIncludes; options=@(); keilMiscControls=[string]$arm.Aads.VariousControls.MiscControls }
        linker = [ordered]@{
            gcSections=$true; mapFile=([string]$arm.ArmAdsMisc.AdsLmap -eq '1'); lto=([string]$arm.ArmAdsMisc.uLtcg -eq '1')
            noStandardLibraries=([string]$arm.LDads.noStLib -eq '1'); libraries=$libraries; libraryDirectories=$libraryDirectories; options=@()
            scatterFile=[string]$arm.LDads.ScatterFile; keilMiscControls=[string]$arm.LDads.Misc; disabledWarnings=[string]$arm.LDads.DisabledWarnings
        }
        output = [ordered]@{
            artifactType=$artifactType; hex=([string]$common.CreateHexFile -eq '1'); bin=([string]$common.AfterMake.RunUserProg1 -eq '1' -and [string]$common.AfterMake.UserProg1Name -match 'fromelf.*--bin')
            debugInformation=([string]$common.DebugInformation -eq '1'); browseInformation=([string]$common.BrowseInformation -eq '1')
            outputDirectory=[string]$common.OutputDirectory; listingPath=[string]$common.ListingPath
        }
        buildSteps = [ordered]@{
            importedKeilCommandsEnabled=$false
            beforeCompile=@([ordered]@{enabled=([string]$common.BeforeCompile.RunUserProg1 -eq '1'); command=[string]$common.BeforeCompile.UserProg1Name}, [ordered]@{enabled=([string]$common.BeforeCompile.RunUserProg2 -eq '1'); command=[string]$common.BeforeCompile.UserProg2Name})
            beforeBuild=@([ordered]@{enabled=([string]$common.BeforeMake.RunUserProg1 -eq '1'); command=[string]$common.BeforeMake.UserProg1Name}, [ordered]@{enabled=([string]$common.BeforeMake.RunUserProg2 -eq '1'); command=[string]$common.BeforeMake.UserProg2Name})
            afterBuild=@([ordered]@{enabled=([string]$common.AfterMake.RunUserProg1 -eq '1'); command=[string]$common.AfterMake.UserProg1Name}, [ordered]@{enabled=([string]$common.AfterMake.RunUserProg2 -eq '1'); command=[string]$common.AfterMake.UserProg2Name})
        }
        keilCompatibility = [ordered]@{
            toolset=[string]$target.ToolsetName; compiler=[string]$target.pCCUsed; useArmCompiler6=([string]$target.uAC6 -eq '1')
            optimizationCode=[int]$arm.Cads.Optim; optimizeForTime=([string]$arm.Cads.oTime -eq '1'); warningLevelCode=[int]$arm.Cads.wLevel
            interworking=([string]$arm.Cads.interw -eq '1'); microLib=([string]$arm.ArmAdsMisc.useUlib -eq '1'); bigEndian=([string]$arm.ArmAdsMisc.BigEnd -eq '1')
            ropiSupportedByGcc=$false; rwpiSupportedByGcc=$false; executeOnlySupportedByGcc=$false; splitLoadStoreSupportedByGcc=$false
        }
        sources = @($sources | Sort-Object -Unique)
        includeDirectories = @($includes | Sort-Object -Unique)
        baseDefines = @($defines | Sort-Object -Unique)
        chipDefines = @()
        extraDefines = @()
        defines = @($defines | Sort-Object -Unique)
        sourceOptions = @()
        debug = [ordered]@{ probe='stlink'; openocdConfigFiles=@('interface/stlink.cfg','target/stm32f4x.cfg'); svdFile='' }
    }
    $manifestObject = [pscustomobject]$manifest
    $manifestObject = Apply-ChipConfig $manifestObject $SelectedChipConfig $Root
    $manifestObject = Apply-OptimizationOptions $manifestObject
    $manifestObject = Apply-ExtraDefines $manifestObject
    $manifestObject = Add-CubeMxSupport $manifestObject $Root $ConversionBackend
    $manifestObject = Remove-KeilOnlySources $manifestObject $Root
    $configDir = Get-ProjectConfigDir $Root
    Write-Utf8NoBom (Join-Path $configDir 'stm32-project.json') ($manifestObject | ConvertTo-Json -Depth 20)
    Write-GeneratedProject $manifestObject $Root
    Write-Host "Generated CMake/VS Code project at $Root" -ForegroundColor Green
}

function Export-Uvprojx([string]$Root, [string]$RequestedTarget, [string]$UvprojxOverride) {
    $Root = Resolve-FullPath $Root
    $m = Get-Manifest $Root
    $uv = if ($UvprojxOverride) { Resolve-FullPath $UvprojxOverride $Root } else { Resolve-FullPath $m.uvprojx $Root }
    $name = if ($RequestedTarget) { $RequestedTarget } elseif ($m.uvTarget) { $m.uvTarget } else { $m.name }
    $createdNewProject = -not (Test-Path -LiteralPath $uv)
    if ($createdNewProject) { New-KeilProjectFromManifest $m $uv $name }
    [xml]$xml = Get-Content -Raw -LiteralPath $uv
    $targets = @($xml.Project.Targets.Target)
    $target = $targets | Where-Object TargetName -eq $name | Select-Object -First 1
    if (-not $target) { throw "Target '$name' not found in $uv" }
    $uvDir = Split-Path -Parent $uv
    $m = Apply-OptimizationOptions $m
    $m = Initialize-BuildOptions $m
    $isNativeCMake = $m.PSObject.Properties.Name -contains 'nativeCMake'
    $selectedKeilCompiler = if ($KeilCompiler) { $KeilCompiler } elseif ($m.PSObject.Properties.Name -contains 'keilCompiler') { [string]$m.keilCompiler } else { 'armcc5' }
    if ($isNativeCMake) {
        $target.uAC6 = if ($selectedKeilCompiler -eq 'armclang6') { '1' } else { '0' }
        if ($target.PSObject.Properties.Name -contains 'pCCUsed') {
            $target.pCCUsed = if ($selectedKeilCompiler -eq 'armclang6') { '6240000::V6.24::ARMCLANG' } else { '5060960::V5.06 update 7 (build 960)::./ARMCC' }
        }
    }
    $target.TargetOption.TargetCommonOption.Device = if (($m.PSObject.Properties.Name -contains 'keilDevice') -and $m.keilDevice) { [string]$m.keilDevice } else { [string]$m.device }
    $target.TargetOption.TargetArmAds.Cads.VariousControls.Define = ($m.defines -join ',')
    $target.TargetOption.TargetArmAds.Cads.VariousControls.IncludePath = (($m.includeDirectories | ForEach-Object { Get-RelativePath $uvDir (Resolve-FullPath $_ $Root) }) -join ';')
    $target.TargetOption.TargetArmAds.Cads.VariousControls.Undefine = (@($m.compiler.undefines) -join ',')
    $selectedOptimization = if ($Config -eq 'Release') { [string]$m.optimization.release } else { [string]$m.optimization.debug }
    $keilOptimizationCode = switch ($selectedOptimization) { 'O0' {'1'} 'O1' {'2'} 'Og' {'2'} 'O2' {'3'} 'Os' {'3'} 'O3' {'4'} 'Ofast' {'4'} default {'0'} }
    $target.TargetOption.TargetArmAds.Cads.Optim = $keilOptimizationCode
    $target.TargetOption.TargetArmAds.Cads.oTime = if ([string]$m.compiler.optimizationGoal -eq 'speed') {'1'} else {'0'}
    $target.TargetOption.TargetArmAds.Cads.OneElfS = if ($m.compiler.functionSections) {'1'} else {'0'}
    $target.TargetOption.TargetArmAds.Cads.SplitLS = if ($m.compiler.splitLoadStore) {'1'} else {'0'}
    $target.TargetOption.TargetArmAds.Cads.Strict = if ($m.compiler.strictAnsi) {'1'} else {'0'}
    $target.TargetOption.TargetArmAds.Cads.EnumInt = if ($m.compiler.shortEnums) {'0'} else {'1'}
    $target.TargetOption.TargetArmAds.Cads.PlainCh = if ($m.compiler.signedChar) {'1'} else {'0'}
    $target.TargetOption.TargetArmAds.Cads.Ropi = if ($m.compiler.ropi) {'1'} else {'0'}
    $target.TargetOption.TargetArmAds.Cads.Rwpi = if ($m.compiler.rwpi) {'1'} else {'0'}
    $target.TargetOption.TargetArmAds.Cads.uSurpInc = if ($m.compiler.noAutoIncludes) {'1'} else {'0'}
    $target.TargetOption.TargetArmAds.Cads.uC99 = if ([int]$m.compiler.cStandard -eq 90) {'0'} else {'1'}
    $target.TargetOption.TargetArmAds.Cads.uGnu = if ($m.compiler.cExtensions) {'1'} else {'0'}
    $target.TargetOption.TargetArmAds.Cads.useXO = if ($m.compiler.executeOnly) {'1'} else {'0'}
    $target.TargetOption.TargetArmAds.Cads.v6Lto = if ($m.compiler.lto) {'1'} else {'0'}
    $target.TargetOption.TargetArmAds.Cads.v6WtE = if ($m.compiler.warningsAsErrors) {'1'} else {'0'}
    $target.TargetOption.TargetArmAds.Cads.wLevel = switch ([string]$m.compiler.warnings) { 'none' {'1'} 'all' {'2'} 'extra' {'2'} default {'0'} }
    $target.TargetOption.TargetArmAds.Cads.VariousControls.MiscControls = [string]$m.compiler.keilMiscControls
    $target.TargetOption.TargetArmAds.Aads.VariousControls.Define = (@($m.assembler.defines) -join ',')
    $target.TargetOption.TargetArmAds.Aads.VariousControls.IncludePath = ((@($m.assembler.includeDirectories) | ForEach-Object { Get-RelativePath $uvDir (Resolve-FullPath $_ $Root) }) -join ';')
    $target.TargetOption.TargetArmAds.Aads.VariousControls.MiscControls = [string]$m.assembler.keilMiscControls
    $target.TargetOption.TargetArmAds.LDads.noStLib = if ($m.linker.noStandardLibraries) {'1'} else {'0'}
    $target.TargetOption.TargetArmAds.LDads.IncludeLibs = (@($m.linker.libraries) -join ';')
    $target.TargetOption.TargetArmAds.LDads.IncludeLibsPath = ((@($m.linker.libraryDirectories) | ForEach-Object { Get-RelativePath $uvDir (Resolve-FullPath $_ $Root) }) -join ';')
    $target.TargetOption.TargetArmAds.LDads.Misc = [string]$m.linker.keilMiscControls
    if ($isNativeCMake -and $selectedKeilCompiler -eq 'armclang6') {
        $scatterPath = Write-KeilScatterFile $m $uvDir $name
        $target.TargetOption.TargetArmAds.LDads.umfTarg = '0'
        $target.TargetOption.TargetArmAds.LDads.useFile = '1'
        $target.TargetOption.TargetArmAds.LDads.ScatterFile = Get-RelativePath $uvDir $scatterPath
        $target.TargetOption.TargetArmAds.LDads.TextAddressRange = [string]$m.memory.flash.origin
        $target.TargetOption.TargetArmAds.LDads.DataAddressRange = [string]$m.memory.ram.origin
    } elseif ($isNativeCMake) {
        $target.TargetOption.TargetArmAds.LDads.umfTarg = '1'
        $target.TargetOption.TargetArmAds.LDads.useFile = '0'
        $target.TargetOption.TargetArmAds.LDads.ScatterFile = ''
    }
    $target.TargetOption.TargetCommonOption.CreateExecutable = if ([string]$m.output.artifactType -eq 'staticLibrary') {'0'} else {'1'}
    $target.TargetOption.TargetCommonOption.CreateLib = if ([string]$m.output.artifactType -eq 'staticLibrary') {'1'} else {'0'}
    $target.TargetOption.TargetCommonOption.CreateHexFile = if ($m.output.hex) {'1'} else {'0'}
    $target.TargetOption.TargetCommonOption.DebugInformation = if ($m.output.debugInformation) {'1'} else {'0'}
    $target.TargetOption.TargetCommonOption.BrowseInformation = if ($m.output.browseInformation) {'1'} else {'0'}
    $target.TargetOption.TargetArmAds.ArmAdsMisc.OnChipMemories.IROM.StartAddress = $m.memory.flash.origin
    $target.TargetOption.TargetArmAds.ArmAdsMisc.OnChipMemories.IROM.Size = $m.memory.flash.length
    $target.TargetOption.TargetArmAds.ArmAdsMisc.OnChipMemories.IRAM.StartAddress = $m.memory.ram.origin
    $target.TargetOption.TargetArmAds.ArmAdsMisc.OnChipMemories.IRAM.Size = $m.memory.ram.length
    if (-not ($target.PSObject.Properties.Name -contains 'Groups')) {
        $groupsNode = $xml.CreateElement('Groups'); [void]$target.AppendChild($groupsNode)
    }
    $allGroups = @($target.Groups.Group)
    $generated = $allGroups | Where-Object GroupName -eq 'CMake-Sync' | Select-Object -First 1
    if (-not $generated) {
        $generated = $xml.CreateElement('Group')
        $groupName = $xml.CreateElement('GroupName'); $groupName.InnerText = 'CMake-Sync'; [void]$generated.AppendChild($groupName)
        $filesNode = $xml.CreateElement('Files'); [void]$generated.AppendChild($filesNode)
        [void]$target.Groups.AppendChild($generated)
    }
    $generatedFilesNode = $generated.SelectSingleNode('Files')
    if (-not $generatedFilesNode) {
        $generatedFilesNode = $xml.CreateElement('Files')
        [void]$generated.AppendChild($generatedFilesNode)
    }
    $keilSources = @($m.sources | Where-Object {
        -not ($isNativeCMake -and $_ -match '(?i)(^|/)(syscalls|sysmem)\.c$') -and
        -not ($isNativeCMake -and $selectedKeilCompiler -eq 'armcc5' -and $_ -match '(?i)(^|/)startup_[^/]+\.s$')
    })
    if ($isNativeCMake -and $selectedKeilCompiler -eq 'armcc5') {
        if (-not ($m.PSObject.Properties.Name -contains 'keilStartupTemplate') -or -not (Test-Path -LiteralPath $m.keilStartupTemplate)) {
            throw 'Arm Compiler 5 requires a valid keilStartupTemplate in the chip config.'
        }
        $generatedKeilDir = Join-Path $uvDir 'generated'
        if (-not (Test-Path -LiteralPath $generatedKeilDir)) { New-Item -ItemType Directory -Force -Path $generatedKeilDir | Out-Null }
        $startupDestination = Join-Path $generatedKeilDir (Split-Path -Leaf $m.keilStartupTemplate)
        Copy-Item -LiteralPath $m.keilStartupTemplate -Destination $startupDestination -Force
        $keilSources += Get-RelativePath $Root $startupDestination
    }
    $manifestSources = @{}
    foreach ($source in $keilSources) {
        if ($source -notmatch '/Templates/gcc/startup_') { $manifestSources[$source.Replace('\','/').ToLowerInvariant()] = $source }
    }
    $present = @{}
    foreach ($group in @($target.Groups.Group)) {
        if ([string]$group.GroupName -eq 'CMake-Sync') { continue }
        if (-not ($group.PSObject.Properties.Name -contains 'Files') -or -not ($group.Files.PSObject.Properties.Name -contains 'File')) { continue }
        foreach ($file in @($group.Files.File)) {
            if ([string]$file.FileType -notin @('1','2')) { continue }
            if ([string]$file.FileName -match '^startup_') { continue }
            $full = Resolve-FullPath ([string]$file.FilePath) $uvDir
            $relative = (Get-RelativePath $Root $full).ToLowerInvariant()
            if ($manifestSources.ContainsKey($relative)) { $present[$relative] = $true }
            else { [void]$group.Files.RemoveChild($file) }
        }
    }
    $generatedFilesNode.RemoveAll()
    foreach ($source in $keilSources) {
        if (-not $createdNewProject -and $source -match '/Templates/gcc/startup_') { continue }
        if ($present.ContainsKey($source.Replace('\','/').ToLowerInvariant())) { continue }
        $file = $xml.CreateElement('File')
        $fileName = $xml.CreateElement('FileName'); $fileName.InnerText = Split-Path -Leaf $source; [void]$file.AppendChild($fileName)
        $fileType = $xml.CreateElement('FileType'); $fileType.InnerText = if ($source -match '\.(s|S)$') {'2'} else {'1'}; [void]$file.AppendChild($fileType)
        $filePath = $xml.CreateElement('FilePath'); $filePath.InnerText = Get-RelativePath $uvDir (Resolve-FullPath $source $Root); [void]$file.AppendChild($filePath)
        [void]$generatedFilesNode.AppendChild($file)
    }
    $backup = "$uv.bak"
    Copy-Item -LiteralPath $uv -Destination $backup -Force
    $settings = [Xml.XmlWriterSettings]::new(); $settings.Indent = $true; $settings.Encoding = [Text.UTF8Encoding]::new($false)
    $writer = [Xml.XmlWriter]::Create($uv, $settings); $xml.Save($writer); $writer.Close()
    Write-Host "Updated $uv (backup: $backup)" -ForegroundColor Green
}

function Invoke-CMake([string]$Root, [string]$Cfg, [switch]$Build) {
    $Root = Resolve-FullPath $Root
    $manifest = Get-Manifest $Root
    if ($ChipConfig) { $manifest = Apply-ChipConfig $manifest $ChipConfig $Root }
    $manifest = Apply-OptimizationOptions $manifest
    $manifest = Apply-ExtraDefines $manifest
    $manifest = Remove-KeilOnlySources $manifest $Root
    if ($ChipConfig -or $DebugOptimization -or $ReleaseOptimization -or $ExtraDefines) {
        Write-Utf8NoBom (Join-Path (Get-ProjectConfigDir $Root) 'stm32-project.json') ($manifest | ConvertTo-Json -Depth 20)
    }
    Write-GeneratedProject $manifest $Root
    $preset = $Cfg.ToLowerInvariant()
    $configDir = Get-ProjectConfigDir $Root
    Push-Location $configDir
    try {
        & cmake --preset $preset
        if ($LASTEXITCODE) { throw "CMake configure failed ($LASTEXITCODE)" }
        if ($Build) {
            & cmake --build --preset $preset
            if ($LASTEXITCODE) { throw "CMake build failed ($LASTEXITCODE)" }
        }
    } finally { Pop-Location }
    if ($Build) {
        $generatedManifest = Get-Manifest $Root
        Test-Stm32BuildOutput $generatedManifest $Root $Cfg
    }
}

function Invoke-Flash([string]$Root, [string]$Cfg) {
    $Root = Resolve-FullPath $Root
    $m = Get-Manifest $Root
    Invoke-CMake $Root $Cfg -Build
    $programmer = Find-Executable 'STM32_Programmer_CLI' @((Get-EnvironmentToolPath 'STM32_CUBE_CLT_ROOT' 'STM32CubeProgrammer/bin/STM32_Programmer_CLI.exe'))
    if (-not $programmer) { throw 'STM32_Programmer_CLI not found. Add it to PATH or edit .vscode/settings.json.' }
    $bin = Join-Path (Get-ProjectConfigDir $Root) ("build/{0}/{1}.bin" -f $Cfg.ToLowerInvariant(), $m.name)
    $port = if ($m.debug.probe -eq 'jlink') { 'JLINK' } else { 'SWD' }
    & $programmer -c "port=$port" -d $bin $m.loadAddress -v -rst
    if ($LASTEXITCODE) { throw "Flash failed ($LASTEXITCODE)" }
}

function Show-Doctor {
    $gccRoot = Find-ToolchainRoot
    $cubeMx = Find-CubeMxInstall
    $tools = [ordered]@{
        CMake = Find-Executable 'cmake' @()
        Ninja = Find-Executable 'ninja' @()
        'GNU Arm root' = $gccRoot
        Clangd = Find-Executable 'clangd' @((Get-EnvironmentToolPath 'LLVM_ROOT' 'bin/clangd.exe'))
        STM32CubeMX = if ($cubeMx) { $cubeMx.executable } else { '' }
        'STM32 Programmer' = Find-Executable 'STM32_Programmer_CLI' @((Get-EnvironmentToolPath 'STM32_CUBE_CLT_ROOT' 'STM32CubeProgrammer/bin/STM32_Programmer_CLI.exe'))
        OpenOCD = Find-Executable 'openocd' @((Get-EnvironmentToolPath 'STM32_CUBE_CLT_ROOT' 'OpenOCD/bin/openocd.exe'))
        'J-Link GDB Server' = Find-JLinkGdbServer
    }
    $tools.GetEnumerator() | ForEach-Object { [pscustomobject]@{Tool=$_.Key; Path=if ($_.Value) {$_.Value} else {'NOT FOUND'}} } | Format-Table -AutoSize
}

function Install-PortableKit([string]$Root) {
    $Root = Resolve-FullPath $Root
    $source = $ToolRoot
    $destination = Join-Path $Root 'tools/stm32-vscode-kit'
    if ((Resolve-FullPath $source) -eq (Resolve-FullPath $destination)) {
        Write-Host "Portable kit is already installed at $destination" -ForegroundColor Green
        return
    }
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Copy-Item -LiteralPath (Join-Path $source 'scripts/stm32-project.ps1') -Destination $destination -Force
    Copy-Item -LiteralPath (Join-Path $source 'docs/README.md') -Destination $destination -Force
    Copy-Item -LiteralPath (Join-Path $source 'chips') -Destination $destination -Recurse -Force
    $launcher = @'
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Action = 'doctor',
    [string]$Uvprojx,
    [string]$ChipConfig,
    [ValidateSet('Debug', 'Release')][string]$Config = 'Debug',
    [string]$TargetName
)
& "$PSScriptRoot/tools/stm32-vscode-kit/stm32-project.ps1" -Action $Action -Uvprojx $Uvprojx -ProjectRoot $PSScriptRoot -ChipConfig $ChipConfig -Config $Config -TargetName $TargetName
exit $LASTEXITCODE
'@
    Write-Utf8NoBom (Join-Path $Root 'stm32.ps1') $launcher
    Write-Host "Installed portable kit at $destination" -ForegroundColor Green
    Write-Host "Use: pwsh ./stm32.ps1 build -Config Debug"
}

if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).Path }
switch ($Action) {
    'uv2cmake' { if (-not $Uvprojx) { throw '-Uvprojx is required.' }; Import-Uvprojx $Uvprojx $ProjectRoot $TargetName $ChipConfig }
    'cmake2uv' {
        $root = Resolve-FullPath $ProjectRoot
        $manifestPath = Join-Path (Get-ProjectConfigDir $root) 'stm32-project.json'
        $importNative = -not (Test-Path -LiteralPath $manifestPath)
        if (-not $importNative) {
            $existingManifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
            $importNative = $existingManifest.PSObject.Properties.Name -contains 'nativeCMake'
        }
        if ($importNative) {
            if (-not $Uvprojx) { throw 'CMake to Keil conversion requires the uvprojx output path in stm32.config.json.' }
            [void](Import-NativeCMakeProject $root $TargetName $Uvprojx $ChipConfig)
        }
        Export-Uvprojx $root $TargetName $Uvprojx
    }
    'install' { throw 'Centralized mode does not copy build scripts into projects. Use generate -ProjectRoot <path>.' }
    'generate' {
        $root = Resolve-FullPath $ProjectRoot
        $manifest = Get-Manifest $root
        if ($ChipConfig) { $manifest = Apply-ChipConfig $manifest $ChipConfig $root }
        $manifest = Apply-OptimizationOptions $manifest
        $manifest = Apply-ExtraDefines $manifest
        $manifest | Add-Member -NotePropertyName sourceRoot -NotePropertyValue $root.Replace('\','/') -Force
        Write-Utf8NoBom (Join-Path (Get-ProjectConfigDir $root) 'stm32-project.json') ($manifest | ConvertTo-Json -Depth 20)
        Write-GeneratedProject $manifest $root
        Write-Host "Regenerated project files at $root" -ForegroundColor Green
    }
    'configure' { Invoke-CMake $ProjectRoot $Config }
    'build' { Invoke-CMake $ProjectRoot $Config -Build }
    'flash' { Invoke-Flash $ProjectRoot $Config }
    'doctor' { Show-Doctor }
}
