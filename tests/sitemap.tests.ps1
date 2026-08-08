[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$discoveryScript = Join-Path $repositoryRoot 'scripts\SiteDiscovery.ps1'
$generatorScript = Join-Path $repositoryRoot 'scripts\Generate-Sitemap.ps1'
$sourceSitemapPath = Join-Path $repositoryRoot 'sitemap.xml'

Assert-True (Test-Path -LiteralPath $discoveryScript -PathType Leaf) 'Public site discovery script is missing.'
Assert-True (Test-Path -LiteralPath $generatorScript -PathType Leaf) 'Sitemap generator is missing.'
Assert-True (-not (Test-Path -LiteralPath $sourceSitemapPath)) 'sitemap.xml must be generated for validation and deployment, not stored in the source tree.'

. $discoveryScript

$pages = @(Get-IndexableSitePages -SiteRoot $repositoryRoot)
Assert-True ($pages.Count -gt 0) 'No indexable public pages were discovered.'

$pagesByCanonical = @{}
foreach ($page in $pages) {
    Assert-True (-not $pagesByCanonical.ContainsKey($page.Canonical)) "Duplicate discovered canonical: $($page.Canonical)"
    $pagesByCanonical[$page.Canonical] = $page
}
Assert-True ($pagesByCanonical.ContainsKey('https://wdt.digital/')) 'The canonical homepage was not discovered.'

$temporaryPath = Join-Path ([System.IO.Path]::GetTempPath()) ('wdt-sitemap-' + [System.Guid]::NewGuid().ToString('N') + '.xml')
try {
    & $generatorScript -SiteRoot $repositoryRoot -OutputPath $temporaryPath
    $firstGeneration = [System.IO.File]::ReadAllBytes($temporaryPath)
    & $generatorScript -SiteRoot $repositoryRoot -OutputPath $temporaryPath
    $secondGeneration = [System.IO.File]::ReadAllBytes($temporaryPath)

    Assert-True ([System.Linq.Enumerable]::SequenceEqual([byte[]]$firstGeneration, [byte[]]$secondGeneration)) 'Sitemap generation is not byte-for-byte idempotent.'
    Assert-True ([System.Array]::IndexOf($secondGeneration, [byte]13) -lt 0) 'Generated sitemap.xml must use deterministic LF line endings.'

    $sitemapText = [System.Text.Encoding]::UTF8.GetString($secondGeneration)
    try {
        [xml]$sitemap = $sitemapText
    }
    catch {
        throw "Generated sitemap.xml is invalid XML: $($_.Exception.Message)"
    }

    $namespaceManager = [System.Xml.XmlNamespaceManager]::new($sitemap.NameTable)
    $namespaceManager.AddNamespace('sm', 'http://www.sitemaps.org/schemas/sitemap/0.9')
    $urlNodes = @($sitemap.SelectNodes('/sm:urlset/sm:url', $namespaceManager))
    Assert-True ($urlNodes.Count -gt 0) 'Generated sitemap.xml contains no URLs.'

    $sitemapUrls = New-Object System.Collections.Generic.List[string]
    foreach ($urlNode in $urlNodes) {
        $locNodes = @($urlNode.SelectNodes('sm:loc', $namespaceManager))
        $lastModifiedNodes = @($urlNode.SelectNodes('sm:lastmod', $namespaceManager))
        Assert-True ($locNodes.Count -eq 1) 'Every sitemap URL must contain exactly one loc.'
        Assert-True ($lastModifiedNodes.Count -eq 1) 'Every sitemap URL must contain exactly one lastmod.'

        $url = $locNodes[0].InnerText.Trim()
        $lastModified = $lastModifiedNodes[0].InnerText.Trim()
        Assert-True (-not [string]::IsNullOrWhiteSpace($url)) 'Sitemap loc must not be empty.'
        Assert-True (-not [string]::IsNullOrWhiteSpace($lastModified)) "Sitemap lastmod is empty for $url"

        try {
            $uri = [uri]$url
        }
        catch {
            throw "Sitemap URL is invalid: $url"
        }
        Assert-True ($uri.IsAbsoluteUri -and $uri.Scheme -ceq 'https' -and $uri.Host -ceq 'wdt.digital') "Sitemap URL is outside the canonical production site: $url"
        Assert-True ($url -notmatch '0x0bug\.github\.io') "Sitemap contains the legacy Pages host: $url"
        Assert-True ($uri.AbsolutePath -notmatch '/windows-diagnostics-toolkit/') "Sitemap contains the legacy project path: $url"
        Assert-True ($uri.AbsolutePath -notmatch '(?i)/404\.html$') "Sitemap contains 404.html: $url"
        Assert-True ($pagesByCanonical.ContainsKey($url)) "Sitemap URL has no matching indexable canonical page: $url"

        $parsedLastModified = [DateTimeOffset]::MinValue
        Assert-True ([DateTimeOffset]::TryParseExact(
            $lastModified,
            "yyyy-MM-dd'T'HH:mm:ssK",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsedLastModified
        )) "Sitemap lastmod is not a W3C timestamp for ${url}: $lastModified"
        Assert-True ($parsedLastModified.UtcDateTime -le [DateTime]::UtcNow) "Sitemap lastmod is in the future for ${url}: $lastModified"

        $page = $pagesByCanonical[$url]
        $expectedLastModified = Get-GitPageLastModified -SiteRoot $repositoryRoot -RelativePath $page.RelativePath
        Assert-True ($lastModified -ceq $expectedLastModified) "Sitemap lastmod for $url is $lastModified; expected Git-derived $expectedLastModified"
        Assert-True (Test-Path -LiteralPath $page.File.FullName -PathType Leaf) "Sitemap URL maps to a missing HTML file: $url"

        $sitemapUrls.Add($url)
    }

    Assert-True (@($sitemapUrls | Select-Object -Unique).Count -eq $sitemapUrls.Count) 'Generated sitemap.xml contains duplicate URLs.'
    Assert-True ($sitemapUrls.Count -eq $pages.Count) "Generated sitemap.xml contains $($sitemapUrls.Count) URLs, but discovery found $($pages.Count) indexable pages."
    foreach ($page in $pages) {
        Assert-True ($page.Canonical -in $sitemapUrls) "Indexable canonical is missing from generated sitemap.xml: $($page.Canonical)"
    }
    $sortedUrls = @($sitemapUrls | Sort-Object)
    for ($index = 0; $index -lt $sitemapUrls.Count; $index++) {
        Assert-True ($sitemapUrls[$index] -ceq $sortedUrls[$index]) 'Generated sitemap.xml URLs are not in deterministic canonical order.'
    }

    Write-Host "Generated sitemap validation passed for $($pages.Count) indexable pages."
}
finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
}
