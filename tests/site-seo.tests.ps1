[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$siteRoot = $repositoryRoot
$separatorCharacters = [char[]]@('\', '/')
$siteRootFull = [System.IO.Path]::GetFullPath($siteRoot).TrimEnd($separatorCharacters)
$publishedBaseUrl = 'https://wdt.digital/'

$issues = New-Object System.Collections.Generic.List[string]

function Add-TestIssue {
    param([Parameter(Mandatory = $true)][string]$Message)
    $issues.Add($Message)
}

function Get-FirstMatchValue {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
    $match = [regex]::Match($Text, $Pattern, $options)
    if (-not $match.Success) {
        return $null
    }

    return [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value.Trim())
}

function ConvertTo-PlainText {
    param([Parameter(Mandatory = $true)][string]$Html)

    $withoutTags = [regex]::Replace($Html, '<[^>]+>', ' ')
    $decoded = [System.Net.WebUtility]::HtmlDecode($withoutTags)
    $normalized = [regex]::Replace($decoded, '\s+', ' ').Trim()
    return [regex]::Replace($normalized, '\s+([,.;:!?])', '$1')
}

function Get-RelativeSitePath {
    param([Parameter(Mandatory = $true)][string]$FullPath)

    $full = [System.IO.Path]::GetFullPath($FullPath)
    if (-not $full.StartsWith($siteRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full
    }

    return $full.Substring($siteRootFull.Length).TrimStart($separatorCharacters).Replace('\', '/')
}

function Resolve-LocalSiteTarget {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$SourceFile,
        [Parameter(Mandatory = $true)][string]$Reference
    )

    $referenceWithoutFragment = ($Reference -split '#', 2)[0]
    $pathPart = ($referenceWithoutFragment -split '\?', 2)[0]
    if ([string]::IsNullOrWhiteSpace($pathPart)) {
        return $null
    }

    if ($pathPart -match '(?i)^(https?:|mailto:|tel:|javascript:|data:)') {
        return $null
    }

    $isDirectoryReference = $pathPart.EndsWith('/') -or $pathPart -eq '.' -or $pathPart -eq '..'

    if ($pathPart.StartsWith('/')) {
        Add-TestIssue "Unsupported absolute local path in $($SourceFile.Name): $Reference"
        return $null
    }
    else {
        $relative = $pathPart.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $target = Join-Path -Path $SourceFile.DirectoryName -ChildPath $relative
    }

    $target = [System.IO.Path]::GetFullPath($target)
    if ($isDirectoryReference) {
        $target = Join-Path -Path $target -ChildPath 'index.html'
    }

    return $target
}

if (-not (Test-Path -LiteralPath $siteRoot -PathType Container)) {
    throw "Site directory is missing: $siteRoot"
}

$htmlFiles = @(
    @(Get-ChildItem -LiteralPath $siteRoot -Filter '*.html' -File)
    @(Get-ChildItem -LiteralPath (Join-Path $siteRoot 'cases') -Recurse -Filter '*.html' -File)
    @(Get-ChildItem -LiteralPath (Join-Path $siteRoot 'sample-report') -Recurse -Filter '*.html' -File)
) | Sort-Object -Property FullName
if ($htmlFiles.Count -lt 2) {
    Add-TestIssue 'Expected at least a homepage and one additional HTML page.'
}

$titleOwners = @{}
$canonicalOwners = @{}
$descriptionOwners = @{}
$indexableCanonicals = New-Object System.Collections.Generic.List[string]

foreach ($file in $htmlFiles) {
    $relativePath = Get-RelativeSitePath -FullPath $file.FullName
    $html = Get-Content -LiteralPath $file.FullName -Raw
    $isNotFoundPage = $relativePath -eq '404.html'

    if ($html -notmatch '(?i)<html\s+[^>]*lang=["'']en["'']') {
        Add-TestIssue "$relativePath is missing html lang=en."
    }

    $title = Get-FirstMatchValue -Text $html -Pattern '<title>\s*(.*?)\s*</title>'
    if ([string]::IsNullOrWhiteSpace($title)) {
        Add-TestIssue "$relativePath is missing a title."
    }
    else {
        if ($title.Length -lt 15 -or $title.Length -gt 70) {
            Add-TestIssue "$relativePath title length is $($title.Length); expected 15-70 characters."
        }
        if ($titleOwners.ContainsKey($title)) {
            Add-TestIssue "$relativePath duplicates the title used by $($titleOwners[$title])."
        }
        else {
            $titleOwners[$title] = $relativePath
        }
    }

    $description = Get-FirstMatchValue -Text $html -Pattern '<meta\s+[^>]*name=["'']description["''][^>]*content=["''](.*?)["''][^>]*>'
    if ([string]::IsNullOrWhiteSpace($description)) {
        Add-TestIssue "$relativePath is missing a meta description."
    }
    else {
        if ($description.Length -lt 70 -or $description.Length -gt 180) {
            Add-TestIssue "$relativePath description length is $($description.Length); expected 70-180 characters."
        }
        if (-not $isNotFoundPage) {
            if ($descriptionOwners.ContainsKey($description)) {
                Add-TestIssue "$relativePath duplicates the description used by $($descriptionOwners[$description])."
            }
            else {
                $descriptionOwners[$description] = $relativePath
            }
        }
    }

    $robots = Get-FirstMatchValue -Text $html -Pattern '<meta\s+[^>]*name=["'']robots["''][^>]*content=["''](.*?)["''][^>]*>'
    if ($isNotFoundPage) {
        if ($robots -notmatch '(?i)noindex') {
            Add-TestIssue '404.html must contain a noindex robots directive.'
        }
    }
    elseif ($robots -match '(?i)noindex') {
        Add-TestIssue "$relativePath unexpectedly contains noindex."
    }

    $h1Count = [regex]::Matches($html, '<h1\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    if ($h1Count -ne 1) {
        Add-TestIssue "$relativePath contains $h1Count h1 elements; expected exactly one."
    }

    if (-not $isNotFoundPage) {
        $canonical = Get-FirstMatchValue -Text $html -Pattern '<link\s+[^>]*rel=["'']canonical["''][^>]*href=["''](.*?)["''][^>]*>'
        if ([string]::IsNullOrWhiteSpace($canonical)) {
            Add-TestIssue "$relativePath is missing a canonical URL."
        }
        else {
            try {
                $canonicalUri = [uri]$canonical
                if (-not $canonicalUri.IsAbsoluteUri -or $canonicalUri.Scheme -cne 'https' -or $canonicalUri.Host -cne 'wdt.digital') {
                    Add-TestIssue "$relativePath canonical is outside the published site: $canonical"
                }
            }
            catch {
                Add-TestIssue "$relativePath canonical is invalid: $canonical"
            }
            if ($canonicalOwners.ContainsKey($canonical)) {
                Add-TestIssue "$relativePath duplicates the canonical used by $($canonicalOwners[$canonical])."
            }
            else {
                $canonicalOwners[$canonical] = $relativePath
                $indexableCanonicals.Add($canonical)
            }
        }

        foreach ($requiredMeta in @('og:title', 'og:description', 'og:url', 'og:image')) {
            $metaPattern = '<meta\s+[^>]*property=["'']{0}["''][^>]*content=["''](.*?)["''][^>]*>' -f [regex]::Escape($requiredMeta)
            $value = Get-FirstMatchValue -Text $html -Pattern $metaPattern
            if ([string]::IsNullOrWhiteSpace($value)) {
                Add-TestIssue "$relativePath is missing $requiredMeta."
            }
        }

        foreach ($requiredTwitterMeta in @('twitter:card', 'twitter:title', 'twitter:description', 'twitter:image')) {
            $metaPattern = '<meta\s+[^>]*name=["'']{0}["''][^>]*content=["''](.*?)["''][^>]*>' -f [regex]::Escape($requiredTwitterMeta)
            $value = Get-FirstMatchValue -Text $html -Pattern $metaPattern
            if ([string]::IsNullOrWhiteSpace($value)) {
                Add-TestIssue "$relativePath is missing $requiredTwitterMeta."
            }
        }
    }

    $jsonOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
    $jsonLdMatches = [regex]::Matches($html, '<script\s+[^>]*type=["'']application/ld\+json["''][^>]*>(.*?)</script>', $jsonOptions)
    foreach ($jsonLdMatch in $jsonLdMatches) {
        try {
            $null = $jsonLdMatch.Groups[1].Value | ConvertFrom-Json
        }
        catch {
            Add-TestIssue "$relativePath contains invalid JSON-LD: $($_.Exception.Message)"
        }
    }

    if ($relativePath -like 'cases/windows-*.html' -and $html -notmatch '"@type"\s*:\s*"TechArticle"') {
        Add-TestIssue "$relativePath is missing TechArticle structured data."
    }

    $referenceMatches = [regex]::Matches($html, '(?i)\b(?:href|src)=["'']([^"'']+)["'']')
    foreach ($referenceMatch in $referenceMatches) {
        $reference = [System.Net.WebUtility]::HtmlDecode($referenceMatch.Groups[1].Value)
        $target = Resolve-LocalSiteTarget -SourceFile $file -Reference $reference
        if ($null -eq $target) {
            continue
        }

        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            Add-TestIssue "$relativePath contains a broken local reference: $reference -> $(Get-RelativeSitePath -FullPath $target)"
        }
    }
}

$homeHtml = Get-Content -LiteralPath (Join-Path $siteRoot 'index.html') -Raw
$expectedHomeTitle = 'Windows Diagnostic Collection Tool for System Administrators | WDT'
$expectedHomeDescription = 'Collect system, performance, network, security, storage, update and crash diagnostics from Windows 10 and 11 in one structured read-only report.'
if ((Get-FirstMatchValue -Text $homeHtml -Pattern '<title>\s*(.*?)\s*</title>') -cne $expectedHomeTitle) {
    Add-TestIssue 'Home title does not match the approved system-administrator positioning.'
}
if ((Get-FirstMatchValue -Text $homeHtml -Pattern '<meta\s+[^>]*name=["'']description["''][^>]*content=["''](.*?)["''][^>]*>') -cne $expectedHomeDescription) {
    Add-TestIssue 'Home description does not match the approved diagnostic-collection copy.'
}
foreach ($property in @('og:title', 'twitter:title')) {
    $attributeName = if ($property.StartsWith('og:')) { 'property' } else { 'name' }
    $value = Get-FirstMatchValue -Text $homeHtml -Pattern (('<meta\s+[^>]*{0}=["'']{1}["''][^>]*content=["''](.*?)["''][^>]*>') -f $attributeName, [regex]::Escape($property))
    if ($value -cne $expectedHomeTitle) {
        Add-TestIssue "$property does not match the home title."
    }
}
foreach ($property in @('og:description', 'twitter:description')) {
    $attributeName = if ($property.StartsWith('og:')) { 'property' } else { 'name' }
    $value = Get-FirstMatchValue -Text $homeHtml -Pattern (('<meta\s+[^>]*{0}=["'']{1}["''][^>]*content=["''](.*?)["''][^>]*>') -f $attributeName, [regex]::Escape($property))
    if ($value -cne $expectedHomeDescription) {
        Add-TestIssue "$property does not match the home description."
    }
}

$howToArticlePath = Join-Path $siteRoot 'cases\windows-diagnostic-report-for-tech-support.html'
$howToArticleHtml = Get-Content -LiteralPath $howToArticlePath -Raw
$howToJsonMatches = [regex]::Matches($howToArticleHtml, '<script\s+[^>]*type=["'']application/ld\+json["''][^>]*>(.*?)</script>', $jsonOptions)
$structuredItems = New-Object System.Collections.Generic.List[object]
foreach ($jsonMatch in $howToJsonMatches) {
    try {
        $structuredDocument = $jsonMatch.Groups[1].Value | ConvertFrom-Json
        $structuredItems.Add($structuredDocument)
        if ($null -ne $structuredDocument.'@graph') {
            foreach ($graphItem in @($structuredDocument.'@graph')) {
                $structuredItems.Add($graphItem)
            }
        }
    }
    catch {
        continue
    }
}

$howToItems = @($structuredItems | Where-Object { $_.'@type' -eq 'HowTo' })
$techArticleItems = @($structuredItems | Where-Object { $_.'@type' -eq 'TechArticle' })
$breadcrumbItems = @($structuredItems | Where-Object { $_.'@type' -eq 'BreadcrumbList' })
if ($howToItems.Count -ne 1) {
    Add-TestIssue "Diagnostic report article contains $($howToItems.Count) HowTo objects; expected exactly one."
}
if ($techArticleItems.Count -ne 1) {
    Add-TestIssue "Diagnostic report article contains $($techArticleItems.Count) TechArticle objects; expected exactly one."
}
if ($breadcrumbItems.Count -ne 1) {
    Add-TestIssue "Diagnostic report article contains $($breadcrumbItems.Count) BreadcrumbList objects; expected exactly one."
}
if ($howToItems.Count -eq 1) {
    $howTo = $howToItems[0]
    if ($howTo.PSObject.Properties.Name -contains 'totalTime') {
        Add-TestIssue 'Diagnostic report HowTo contains an unsupported totalTime.'
    }
    if ($howToArticleHtml -match 'Download the toolkit') {
        Add-TestIssue 'Diagnostic report still contains the obsolete Download the toolkit step.'
    }

    $steps = @($howTo.step | Sort-Object -Property position)
    if ($steps.Count -ne 5) {
        Add-TestIssue "Diagnostic report HowTo contains $($steps.Count) steps; expected five visible article steps."
    }
    for ($index = 0; $index -lt $steps.Count; $index++) {
        $step = $steps[$index]
        if ([int]$step.position -ne ($index + 1)) {
            Add-TestIssue "HowTo step position $($step.position) is out of sequence."
        }

        $expectedPrefix = 'https://wdt.digital/cases/windows-diagnostic-report-for-tech-support.html#'
        $stepUrl = [string]$step.url
        if (-not $stepUrl.StartsWith($expectedPrefix, [System.StringComparison]::Ordinal)) {
            Add-TestIssue "HowTo step $($step.position) has an unexpected URL: $stepUrl"
            continue
        }
        $fragment = $stepUrl.Substring($expectedPrefix.Length)
        $sectionPattern = '(?is)<h2\b[^>]*\bid=["'']{0}["''][^>]*>(?<heading>.*?)</h2>(?<content>.*?)(?=<h2\b|</article>)' -f [regex]::Escape($fragment)
        $sectionMatch = [regex]::Match($howToArticleHtml, $sectionPattern)
        if (-not $sectionMatch.Success) {
            Add-TestIssue "HowTo step $($step.position) URL does not resolve to a visible h2 section: #$fragment"
            continue
        }

        $visibleHeading = (ConvertTo-PlainText -Html $sectionMatch.Groups['heading'].Value) -replace '^\d+\.\s*', ''
        if ($visibleHeading -cne [string]$step.name) {
            Add-TestIssue "HowTo step $($step.position) name does not match its visible heading: '$($step.name)' vs '$visibleHeading'."
        }
        $visibleSectionText = ConvertTo-PlainText -Html $sectionMatch.Groups['content'].Value
        if (-not $visibleSectionText.Contains([string]$step.text)) {
            Add-TestIssue "HowTo step $($step.position) text is not present in its visible section."
        }
    }
}

$sitemapPath = Join-Path -Path $siteRoot -ChildPath 'sitemap.xml'
if (-not (Test-Path -LiteralPath $sitemapPath -PathType Leaf)) {
    Add-TestIssue 'sitemap.xml is missing.'
}
else {
    try {
        $sitemapText = Get-Content -LiteralPath $sitemapPath -Raw
        [xml]$sitemap = $sitemapText
        $sitemapUrls = @($sitemap.urlset.url | ForEach-Object { [string]$_.loc })
        if ($sitemapUrls.Count -ne 11) {
            Add-TestIssue "sitemap.xml contains $($sitemapUrls.Count) URLs; expected exactly 11."
        }
        if (@($sitemapUrls | Select-Object -Unique).Count -ne $sitemapUrls.Count) {
            Add-TestIssue 'sitemap.xml contains duplicate URLs.'
        }
        if ($sitemapText -match '(?i)<lastmod\b') {
            Add-TestIssue 'sitemap.xml must omit lastmod until meaningful content dates can be maintained automatically.'
        }
        if ($sitemapText -match '0x0bug\.github\.io' -or $sitemapText -match '/windows-diagnostics-toolkit/') {
            Add-TestIssue 'sitemap.xml contains a legacy Pages host or project path.'
        }

        foreach ($canonical in $indexableCanonicals) {
            if ($canonical -notin $sitemapUrls) {
                Add-TestIssue "Canonical URL is missing from sitemap.xml: $canonical"
            }
        }
        foreach ($sitemapUrl in $sitemapUrls) {
            if ($sitemapUrl -notin $indexableCanonicals) {
                Add-TestIssue "sitemap.xml contains a URL without a matching canonical page: $sitemapUrl"
            }
        }

        foreach ($url in $sitemapUrls) {
            try {
                $sitemapUri = [uri]$url
            }
            catch {
                Add-TestIssue "Sitemap URL is invalid: $url"
                continue
            }
            if (-not $sitemapUri.IsAbsoluteUri -or $sitemapUri.Scheme -cne 'https' -or $sitemapUri.Host -cne 'wdt.digital') {
                Add-TestIssue "Sitemap URL is outside the published site: $url"
                continue
            }

            $relative = $url.Substring($publishedBaseUrl.Length)
            if ([string]::IsNullOrWhiteSpace($relative) -or $relative.EndsWith('/')) {
                $relative = $relative + 'index.html'
            }
            $target = Join-Path -Path $siteRoot -ChildPath ($relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                Add-TestIssue "Sitemap URL has no matching site file: $url"
            }
        }
    }
    catch {
        Add-TestIssue "sitemap.xml is invalid: $($_.Exception.Message)"
    }
}

$robotsPath = Join-Path -Path $siteRoot -ChildPath 'robots.txt'
if (-not (Test-Path -LiteralPath $robotsPath -PathType Leaf)) {
    Add-TestIssue 'robots.txt is missing.'
}
else {
    $robotsText = Get-Content -LiteralPath $robotsPath -Raw
    if ($robotsText -notmatch '(?im)^Sitemap:\s*https://wdt\.digital/sitemap\.xml\s*$') {
        Add-TestIssue 'robots.txt does not reference the published sitemap URL.'
    }
}

Write-Host 'Windows Diagnostics Toolkit site SEO validation'
Write-Host ('HTML files        : {0}' -f $htmlFiles.Count)
Write-Host ('Indexable pages   : {0}' -f $indexableCanonicals.Count)
Write-Host ('Validation issues : {0}' -f $issues.Count)

if ($issues.Count -gt 0) {
    Write-Host ''
    foreach ($issue in $issues) {
        Write-Host ('- {0}' -f $issue)
    }
    throw 'Static site SEO validation failed.'
}

Write-Host 'Static site SEO validation passed.'
