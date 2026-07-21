[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-RelativePath {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Path)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return [System.IO.Path]::GetFullPath($Path).Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$prepareScript = Join-Path $repositoryRoot 'scripts\Prepare-PagesArtifact.ps1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wdt-site-assets-' + [System.Guid]::NewGuid().ToString('N'))
$artifactRoot = Join-Path $temporaryRoot 'artifact'

$requiredAssets = @(
    'assets/site.js',
    'assets/social-preview.png',
    'assets/social-preview.svg',
    'assets/style.css',
    'assets/tui-result-real.png',
    'assets/tui-wide-real.png'
)

Assert-True (Test-Path -LiteralPath $prepareScript -PathType Leaf) 'Pages artifact preparation script is missing.'

New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    & $prepareScript -OutputPath $artifactRoot

    $artifactFiles = @(Get-ChildItem -LiteralPath $artifactRoot -Recurse -File -Force)
    $artifactPaths = @($artifactFiles | ForEach-Object { Get-RelativePath -Root $artifactRoot -Path $_.FullName })
    Assert-True ($artifactFiles.Count -eq 21) "Pages artifact contains $($artifactFiles.Count) files; expected 21."

    foreach ($requiredPath in @('.nojekyll', '404.html', 'index.html', 'robots.txt', 'run.ps1', 'sitemap.xml') + $requiredAssets) {
        Assert-True ($artifactPaths -contains $requiredPath) "Pages artifact is missing: $requiredPath"
    }
    foreach ($forbiddenPath in @('.git', '.github', 'tests', 'scripts', 'README.md')) {
        Assert-True (@($artifactPaths | Where-Object { $_ -eq $forbiddenPath -or $_.StartsWith($forbiddenPath + '/', [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) "Pages artifact contains forbidden content: $forbiddenPath"
    }

    $htmlFiles = @(
        @(Get-ChildItem -LiteralPath $repositoryRoot -Filter '*.html' -File)
        @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'cases') -Filter '*.html' -File)
    )
    Assert-True ($htmlFiles.Count -eq 11) "Expected 11 HTML files; found $($htmlFiles.Count)."

    foreach ($htmlFile in $htmlFiles) {
        $html = Get-Content -LiteralPath $htmlFile.FullName -Raw
        Assert-True ($html -notmatch '(?i)\b(?:href|src)=["'']/') "Root-relative reference breaks project-site staging: $($htmlFile.FullName)"
        Assert-True ($html -notmatch '0x0bug\.github\.io/windows-diagnostics-toolkit') "Legacy project-site URL remains: $($htmlFile.FullName)"
    }

    foreach ($relativePath in $requiredAssets) {
        $asset = Get-Item -LiteralPath (Join-Path $repositoryRoot $relativePath)
        Assert-True ($asset.Length -gt 0) "Asset is empty: $relativePath"
    }

    [xml](Get-Content -LiteralPath (Join-Path $repositoryRoot 'assets\social-preview.svg') -Raw) | Out-Null
    Assert-True ((Get-Item -LiteralPath (Join-Path $repositoryRoot 'run.ps1')).Length -gt 0) 'Published run.ps1 is empty.'
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Host "Site asset and Pages artifact tests passed with PowerShell $($PSVersionTable.PSVersion)."
