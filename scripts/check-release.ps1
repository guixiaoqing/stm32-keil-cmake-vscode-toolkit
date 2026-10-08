[CmdletBinding()]
param(
    [string[]]$ForbiddenText = @()
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$selfPath = $PSCommandPath
$textExtensions = @(
    '.bat', '.cmake', '.c', '.h', '.json', '.ld', '.md', '.ps1', '.s', '.txt', '.xml', '.yml', '.yaml'
)
$ignoredDirectories = @('.git', '.idea', '.vscode', 'build', 'CMakeFiles', 'CMake-GCC')
$issues = [System.Collections.Generic.List[string]]::new()

$files = Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File -Force | Where-Object {
    if ($_.FullName -eq $selfPath) { return $false }
    if ($_.Name -like '*.local.json' -or $_.Name -like '.env*') { return $false }
    $knownName = $_.Name -in @('.gitattributes', '.gitignore')
    if (-not $knownName -and $textExtensions -notcontains $_.Extension.ToLowerInvariant()) { return $false }
    $relative = [IO.Path]::GetRelativePath($repositoryRoot, $_.FullName)
    $segments = $relative -split '[\\/]'
    return -not ($segments | Where-Object { $ignoredDirectories -contains $_ })
}

foreach ($file in $files) {
    $relative = [IO.Path]::GetRelativePath($repositoryRoot, $file.FullName)
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        $lineNumber++
        if ($line -match '(?i)(?<![A-Za-z0-9_])[A-Z]:[\\/]') {
            $issues.Add("$relative`:$lineNumber contains an absolute drive path")
        }
        if ($line -match '(?i)[\\/]Users[\\/][^<>\\/\s]+') {
            $issues.Add("$relative`:$lineNumber contains a user profile path")
        }
        if ($line -match '"serialNumber"\s*:\s*"[^"\s]+"') {
            $issues.Add("$relative`:$lineNumber contains a probe serial number")
        }
        foreach ($term in $ForbiddenText) {
            if ($term -and $line.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $issues.Add("$relative`:$lineNumber contains forbidden text '$term'")
            }
        }
    }
}

$generatedPatterns = @('*.elf', '*.axf', '*.hex', '*.bin', '*.map', '*.o', '*.obj', '*.bak', '*.log')
foreach ($pattern in $generatedPatterns) {
    Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File -Force -Filter $pattern | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($repositoryRoot, $_.FullName)
        $issues.Add("$relative is a generated or backup file")
    }
}

if ($issues.Count -gt 0) {
    Write-Host 'Release check FAILED:' -ForegroundColor Red
    $issues | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

Write-Host "Release check PASSED: $($files.Count) text files scanned." -ForegroundColor Green
