[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$siteRoot = $repositoryRoot
$separatorCharacters = [char[]]@('\', '/')
$siteRootFull = [System.IO.Path]::GetFullPath($siteRoot).TrimEnd($separatorCharacters)
$siteDiscoveryScript = Join-Path $repositoryRoot 'scripts\SiteDiscovery.ps1'

if (-not (Test-Path -LiteralPath $siteDiscoveryScript -PathType Leaf)) {
    throw "Public site discovery script is missing: $siteDiscoveryScript"
}
. $siteDiscoveryScript

$issues = New-Object System.Collections.Generic.List[string]

function Add-TestIssue {
    param([Parameter(Mandatory = $true)][string]$Message)
    $issues.Add($Message)
}

$canonicalAttributeOrderFixtures = @(
    '<link rel="canonical" href="https://wdt.digital/fixture.html">',
    '<link href="https://wdt.digital/fixture.html" rel="canonical">'
)
foreach ($fixture in $canonicalAttributeOrderFixtures) {
    $fixtureTags = @([regex]::Matches($fixture, '(?is)<link\b[^>]*>') | Where-Object {
        $rel = Get-HtmlTagAttribute -Tag $_.Value -Name 'rel'
        $null -ne $rel -and @($rel -split '\s+') -icontains 'canonical'
    })
    if ($fixtureTags.Count -ne 1 -or (Get-HtmlTagAttribute -Tag $fixtureTags[0].Value -Name 'href') -cne 'https://wdt.digital/fixture.html') {
        Add-TestIssue 'Canonical parsing depends on HTML attribute order.'
    }
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

$htmlFiles = @(Get-SiteHtmlCandidates -SiteRoot $siteRoot)
if ($htmlFiles.Count -lt 2) {
    Add-TestIssue 'Expected at least a homepage and one additional HTML page.'
}

$titleOwners = @{}
$canonicalOwners = @{}
$descriptionOwners = @{}
$indexableCanonicals = New-Object System.Collections.Generic.List[string]
$indexableRelativePaths = New-Object System.Collections.Generic.List[string]
$linkedHtmlTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

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
    elseif ($robots -match '(?i)(?:^|[\s,])(?:noindex|nofollow|none)(?:$|[\s,])') {
        Add-TestIssue "$relativePath contains a restrictive robots directive: $robots"
    }

    $h1Count = [regex]::Matches($html, '<h1\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    if ($h1Count -ne 1) {
        Add-TestIssue "$relativePath contains $h1Count h1 elements; expected exactly one."
    }

    if (-not $isNotFoundPage) {
        $canonical = $null
        $canonicalTags = @([regex]::Matches($html, '(?is)<link\b[^>]*>') | Where-Object {
            $rel = Get-HtmlTagAttribute -Tag $_.Value -Name 'rel'
            $null -ne $rel -and @($rel -split '\s+') -icontains 'canonical'
        })
        if ($canonicalTags.Count -ne 1) {
            Add-TestIssue "$relativePath contains $($canonicalTags.Count) canonical links; expected exactly one."
        }
        else {
            $canonical = Get-HtmlTagAttribute -Tag $canonicalTags[0].Value -Name 'href'
            if ([string]::IsNullOrWhiteSpace($canonical)) {
                Add-TestIssue "$relativePath canonical link has no href."
                continue
            }
            try {
                $canonicalUri = [uri]$canonical
                if (-not $canonicalUri.IsAbsoluteUri -or $canonicalUri.Scheme -cne 'https' -or $canonicalUri.Host -cne 'wdt.digital') {
                    Add-TestIssue "$relativePath canonical is outside the published site: $canonical"
                }
            }
            catch {
                Add-TestIssue "$relativePath canonical is invalid: $canonical"
            }
            $expectedCanonical = Get-ExpectedCanonicalUrl -RelativePath $relativePath
            if ($canonical -cne $expectedCanonical) {
                Add-TestIssue "$relativePath canonical is $canonical; expected $expectedCanonical"
            }
            if ($canonicalOwners.ContainsKey($canonical)) {
                Add-TestIssue "$relativePath duplicates the canonical used by $($canonicalOwners[$canonical])."
            }
            else {
                $canonicalOwners[$canonical] = $relativePath
                $indexableCanonicals.Add($canonical)
                $indexableRelativePaths.Add($relativePath)
            }
        }

        $openGraphValues = @{}
        foreach ($requiredMeta in @('og:title', 'og:description', 'og:url', 'og:image')) {
            $metaPattern = '<meta\s+[^>]*property=["'']{0}["''][^>]*content=["''](.*?)["''][^>]*>' -f [regex]::Escape($requiredMeta)
            $value = Get-FirstMatchValue -Text $html -Pattern $metaPattern
            if ([string]::IsNullOrWhiteSpace($value)) {
                Add-TestIssue "$relativePath is missing $requiredMeta."
            }
            else {
                $openGraphValues[$requiredMeta] = $value
            }
        }
        if ($null -ne $canonical -and $openGraphValues['og:url'] -cne $canonical) {
            Add-TestIssue "$relativePath og:url does not match its canonical URL."
        }
        if ($openGraphValues.ContainsKey('og:image')) {
            try {
                $ogImageUri = [uri]$openGraphValues['og:image']
                if (-not $ogImageUri.IsAbsoluteUri -or $ogImageUri.Scheme -cne 'https' -or $ogImageUri.Host -cne 'wdt.digital') {
                    Add-TestIssue "$relativePath og:image is outside the production site."
                }
            }
            catch {
                Add-TestIssue "$relativePath og:image is invalid."
            }
        }

        $twitterValues = @{}
        foreach ($requiredTwitterMeta in @('twitter:card', 'twitter:title', 'twitter:description', 'twitter:image')) {
            $metaPattern = '<meta\s+[^>]*name=["'']{0}["''][^>]*content=["''](.*?)["''][^>]*>' -f [regex]::Escape($requiredTwitterMeta)
            $value = Get-FirstMatchValue -Text $html -Pattern $metaPattern
            if ([string]::IsNullOrWhiteSpace($value)) {
                Add-TestIssue "$relativePath is missing $requiredTwitterMeta."
            }
            else {
                $twitterValues[$requiredTwitterMeta] = $value
            }
        }
        if ($twitterValues.ContainsKey('twitter:image')) {
            try {
                $twitterImageUri = [uri]$twitterValues['twitter:image']
                if (-not $twitterImageUri.IsAbsoluteUri -or $twitterImageUri.Scheme -cne 'https' -or $twitterImageUri.Host -cne 'wdt.digital') {
                    Add-TestIssue "$relativePath twitter:image is outside the production site."
                }
            }
            catch {
                Add-TestIssue "$relativePath twitter:image is invalid."
            }
        }
    }

    if ($html -match '0x0bug\.github\.io' -or $html -match 'https://wdt\.digital/windows-diagnostics-toolkit/') {
        Add-TestIssue "$relativePath contains a legacy Pages URL."
    }
    if ($html -match '(?is)<meta\b[^>]*http-equiv=["'']refresh["'']' -or $html -match '(?i)\b(?:window\.)?location\s*(?:=|\[\s*["'']|\.(?:href|assign|replace)\b)') {
        Add-TestIssue "$relativePath contains a client-side redirect."
    }
    if ($html -match '(?is)<meta\b[^>]*name=["'']keywords["'']') {
        Add-TestIssue "$relativePath contains an obsolete keywords meta tag."
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

    $referenceMatches = [regex]::Matches($html, '(?i)\b(?<attribute>href|src)=["''](?<reference>[^"'']+)["'']')
    foreach ($referenceMatch in $referenceMatches) {
        $reference = [System.Net.WebUtility]::HtmlDecode($referenceMatch.Groups['reference'].Value)
        $target = Resolve-LocalSiteTarget -SourceFile $file -Reference $reference
        if ($null -eq $target) {
            continue
        }

        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            Add-TestIssue "$relativePath contains a broken local reference: $reference -> $(Get-RelativeSitePath -FullPath $target)"
        }
        elseif ($referenceMatch.Groups['attribute'].Value -ieq 'href' -and [System.IO.Path]::GetExtension($target) -ieq '.html') {
            $null = $linkedHtmlTargets.Add((Get-RelativeSitePath -FullPath $target))
        }
    }
}

foreach ($relativePath in $indexableRelativePaths) {
    if ($relativePath -cne 'index.html' -and -not $linkedHtmlTargets.Contains($relativePath)) {
        Add-TestIssue "$relativePath is indexable but has no incoming internal link."
    }
}

$homeHtml = Get-Content -LiteralPath (Join-Path $siteRoot 'index.html') -Raw
$expectedHomeTitle = 'Windows Diagnostics Toolkit (WDT) | Read-Only PowerShell Diagnostics'
$expectedHomeDescription = 'Collect system, performance, network, security, storage, update and crash diagnostics from Windows 10 and 11 in one structured read-only report.'
if ((Get-FirstMatchValue -Text $homeHtml -Pattern '<title>\s*(.*?)\s*</title>') -cne $expectedHomeTitle) {
    Add-TestIssue 'Home title does not match the canonical product entity positioning.'
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

$homeJsonMatches = [regex]::Matches($homeHtml, '<script\s+[^>]*type=["'']application/ld\+json["''][^>]*>(.*?)</script>', $jsonOptions)
$homeStructuredItems = New-Object System.Collections.Generic.List[object]
$homeJsonText = New-Object System.Collections.Generic.List[string]
foreach ($jsonMatch in $homeJsonMatches) {
    try {
        $homeJsonText.Add($jsonMatch.Groups[1].Value)
        $structuredDocument = $jsonMatch.Groups[1].Value | ConvertFrom-Json
        $homeStructuredItems.Add($structuredDocument)
        if ($null -ne $structuredDocument.'@graph') {
            foreach ($graphItem in @($structuredDocument.'@graph')) {
                $homeStructuredItems.Add($graphItem)
            }
        }
    }
    catch {
        continue
    }
}

$websiteItems = @($homeStructuredItems | Where-Object { $_.'@type' -eq 'WebSite' })
$softwareItems = @($homeStructuredItems | Where-Object { $_.'@type' -eq 'SoftwareApplication' })
$faqItems = @($homeStructuredItems | Where-Object { $_.'@type' -eq 'FAQPage' })
if ($websiteItems.Count -ne 1) {
    Add-TestIssue "Homepage contains $($websiteItems.Count) WebSite objects; expected exactly one."
}
if ($softwareItems.Count -ne 1) {
    Add-TestIssue "Homepage contains $($softwareItems.Count) SoftwareApplication objects; expected exactly one."
}
if ($faqItems.Count -ne 1) {
    Add-TestIssue "Homepage contains $($faqItems.Count) FAQPage objects; expected exactly one."
}

$expectedEntityDescription = 'Open-source read-only PowerShell diagnostics toolkit for Windows 10 and Windows 11 that collects system, performance, network, security, storage, update, services and crash evidence into local structured reports for troubleshooting.'
if ($websiteItems.Count -eq 1) {
    $website = $websiteItems[0]
    if ($website.name -cne 'Windows Diagnostics Toolkit' -or $website.url -cne 'https://wdt.digital/') {
        Add-TestIssue 'WebSite structured data does not use the canonical WDT name and URL.'
    }
    $alternateNames = @($website.alternateName)
    if ($alternateNames.Count -ne 2 -or 'WDT' -notin $alternateNames -or 'wdt.digital' -notin $alternateNames) {
        Add-TestIssue 'WebSite alternateName must contain exactly WDT and wdt.digital.'
    }
    if ($website.description -cne $expectedEntityDescription) {
        Add-TestIssue 'WebSite description does not match the canonical product entity description.'
    }
}
if ($softwareItems.Count -eq 1) {
    $software = $softwareItems[0]
    if ($software.name -cne 'Windows Diagnostics Toolkit' -or $software.alternateName -cne 'WDT') {
        Add-TestIssue 'SoftwareApplication does not connect Windows Diagnostics Toolkit with WDT.'
    }
    if ($software.description -cne $expectedEntityDescription) {
        Add-TestIssue 'SoftwareApplication description does not match the canonical product entity description.'
    }
    if ($software.applicationCategory -cne 'UtilitiesApplication' -or $software.isAccessibleForFree -ne $true) {
        Add-TestIssue 'SoftwareApplication category or free-access status is incorrect.'
    }
    if ('Windows 10' -notin @($software.operatingSystem) -or 'Windows 11' -notin @($software.operatingSystem)) {
        Add-TestIssue 'SoftwareApplication operatingSystem must include Windows 10 and Windows 11.'
    }
    foreach ($requiredProperty in @('softwareRequirements', 'license', 'codeRepository', 'softwareVersion', 'downloadUrl', 'releaseNotes', 'author', 'image', 'featureList', 'offers')) {
        if ($software.PSObject.Properties.Name -notcontains $requiredProperty -or $null -eq $software.$requiredProperty) {
            Add-TestIssue "SoftwareApplication is missing $requiredProperty."
        }
    }
    if ($software.codeRepository -cne 'https://github.com/0x0bug/windows-diagnostics-toolkit') {
        Add-TestIssue 'SoftwareApplication codeRepository is incorrect.'
    }
    if ($software.offers.'@type' -cne 'Offer' -or [string]$software.offers.price -cne '0') {
        Add-TestIssue 'SoftwareApplication free Offer is incorrect.'
    }
}
if (($homeJsonText -join "`n") -match '"@type"\s*:\s*"AggregateRating"') {
    Add-TestIssue 'Homepage structured data must not contain fabricated AggregateRating data.'
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

$robotsPath = Join-Path -Path $siteRoot -ChildPath 'robots.txt'
if (-not (Test-Path -LiteralPath $robotsPath -PathType Leaf)) {
    Add-TestIssue 'robots.txt is missing.'
}
else {
    $robotsText = Get-Content -LiteralPath $robotsPath -Raw
    $robotsPolicy = @($robotsText -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith('#')
    })
    $expectedRobotsPolicy = @('User-agent: *', 'Allow: /', 'Sitemap: https://wdt.digital/sitemap.xml')
    if ($robotsPolicy.Count -ne $expectedRobotsPolicy.Count) {
        Add-TestIssue 'robots.txt must contain only the universal allow policy and production sitemap declaration.'
    }
    else {
        for ($index = 0; $index -lt $expectedRobotsPolicy.Count; $index++) {
            if ($robotsPolicy[$index] -cne $expectedRobotsPolicy[$index]) {
                Add-TestIssue "robots.txt line $($index + 1) is '$($robotsPolicy[$index])'; expected '$($expectedRobotsPolicy[$index])'."
            }
        }
    }
    if ($robotsText -match '(?im)^\s*Disallow\s*:') {
        Add-TestIssue 'robots.txt must not contain crawler restrictions.'
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
