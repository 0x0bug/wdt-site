[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = [System.IO.Path]::GetFullPath($OutputPath)
$repositoryRootFull = [System.IO.Path]::GetFullPath($repositoryRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)

if ($outputRoot -eq $repositoryRootFull -or $outputRoot.StartsWith($repositoryRootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Pages artifact output must be outside the repository checkout.'
}
if (Test-Path -LiteralPath $outputRoot) {
    throw "Pages artifact output already exists: $outputRoot"
}

New-Item -ItemType Directory -Path $outputRoot | Out-Null

foreach ($relativePath in @('.nojekyll', '404.html', 'index.html', 'robots.txt', 'run.ps1', 'sitemap.xml')) {
    $sourcePath = Join-Path -Path $repositoryRoot -ChildPath $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required site file is missing: $relativePath"
    }
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $outputRoot $relativePath)
}

foreach ($relativePath in @('assets', 'cases')) {
    $sourcePath = Join-Path -Path $repositoryRoot -ChildPath $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "Required site directory is missing: $relativePath"
    }
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $outputRoot $relativePath) -Recurse
}

Write-Host "Prepared Pages artifact: $outputRoot"
