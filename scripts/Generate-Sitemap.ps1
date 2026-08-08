[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$SiteRoot = (Split-Path -Parent $PSScriptRoot),

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'SiteDiscovery.ps1')

$siteRootFull = [System.IO.Path]::GetFullPath($SiteRoot)
$outputPathFull = [System.IO.Path]::GetFullPath($OutputPath)
$pages = @(Get-IndexableSitePages -SiteRoot $siteRootFull)
if ($pages.Count -eq 0) {
    throw 'No indexable public HTML pages were discovered.'
}
if ('https://wdt.digital/' -notin @($pages.Canonical)) {
    throw 'The canonical homepage was not discovered.'
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('<?xml version="1.0" encoding="UTF-8"?>')
$lines.Add('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">')
foreach ($page in $pages) {
    $lastModified = Get-GitPageLastModified -SiteRoot $siteRootFull -RelativePath $page.RelativePath
    $escapedCanonical = [System.Security.SecurityElement]::Escape($page.Canonical)
    $lines.Add('  <url>')
    $lines.Add("    <loc>$escapedCanonical</loc>")
    $lines.Add("    <lastmod>$lastModified</lastmod>")
    $lines.Add('  </url>')
}
$lines.Add('</urlset>')

$outputDirectory = Split-Path -Parent $outputPathFull
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $outputDirectory
}
$content = ($lines -join "`n") + "`n"
[System.IO.File]::WriteAllText($outputPathFull, $content, [System.Text.UTF8Encoding]::new($false))

Write-Host "Generated sitemap with $($pages.Count) URLs: $outputPathFull"
