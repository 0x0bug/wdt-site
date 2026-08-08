[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'SiteDiscovery.ps1')

$outputRoot = [System.IO.Path]::GetFullPath($OutputPath)
$repositoryRootFull = [System.IO.Path]::GetFullPath($repositoryRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)

if ($outputRoot -eq $repositoryRootFull -or $outputRoot.StartsWith($repositoryRootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Pages artifact output must be outside the repository checkout.'
}
if (Test-Path -LiteralPath $outputRoot) {
    throw "Pages artifact output already exists: $outputRoot"
}

New-Item -ItemType Directory -Path $outputRoot | Out-Null

foreach ($relativePath in @('.nojekyll', 'robots.txt', 'run.ps1')) {
    $sourcePath = Join-Path -Path $repositoryRoot -ChildPath $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required site file is missing: $relativePath"
    }
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $outputRoot $relativePath)
}

foreach ($file in @(Get-SiteHtmlCandidates -SiteRoot $repositoryRoot)) {
    $relativePath = Get-SiteRelativePath -SiteRoot $repositoryRoot -Path $file.FullName
    $destinationPath = Join-Path $outputRoot $relativePath
    $destinationDirectory = Split-Path -Parent $destinationPath
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $destinationDirectory
    }
    Copy-Item -LiteralPath $file.FullName -Destination $destinationPath
}

$assetsPath = Join-Path $repositoryRoot 'assets'
if (-not (Test-Path -LiteralPath $assetsPath -PathType Container)) {
    throw 'Required site directory is missing: assets'
}
Copy-Item -LiteralPath $assetsPath -Destination (Join-Path $outputRoot 'assets') -Recurse

$sitemapGenerator = Join-Path $PSScriptRoot 'Generate-Sitemap.ps1'
if (-not (Test-Path -LiteralPath $sitemapGenerator -PathType Leaf)) {
    throw 'Sitemap generator is missing: scripts/Generate-Sitemap.ps1'
}
& $sitemapGenerator -SiteRoot $repositoryRoot -OutputPath (Join-Path $outputRoot 'sitemap.xml')

Write-Host "Prepared Pages artifact: $outputRoot"
