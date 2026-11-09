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

function Get-RelativeLuminance {
    param([Parameter(Mandatory = $true)][string]$HexColor)

    if ($HexColor -notmatch '^#(?<value>[0-9a-fA-F]{6})$') {
        throw "Invalid six-digit hex color: $HexColor"
    }

    $components = @(
        [Convert]::ToInt32($Matches.value.Substring(0, 2), 16),
        [Convert]::ToInt32($Matches.value.Substring(2, 2), 16),
        [Convert]::ToInt32($Matches.value.Substring(4, 2), 16)
    )

    $linear = @($components | ForEach-Object {
        $channel = $_ / 255
        if ($channel -le 0.04045) {
            $channel / 12.92
        }
        else {
            [Math]::Pow((($channel + 0.055) / 1.055), 2.4)
        }
    })

    return (0.2126 * $linear[0]) + (0.7152 * $linear[1]) + (0.0722 * $linear[2])
}

function Get-ContrastRatio {
    param(
        [Parameter(Mandatory = $true)][string]$Foreground,
        [Parameter(Mandatory = $true)][string]$Background
    )

    $foregroundLuminance = Get-RelativeLuminance -HexColor $Foreground
    $backgroundLuminance = Get-RelativeLuminance -HexColor $Background
    $lighter = [Math]::Max($foregroundLuminance, $backgroundLuminance)
    $darker = [Math]::Min($foregroundLuminance, $backgroundLuminance)
    return ($lighter + 0.05) / ($darker + 0.05)
}

function Get-WorkflowJobBlock {
    param(
        [Parameter(Mandatory = $true)][string]$WorkflowText,
        [Parameter(Mandatory = $true)][string]$JobName
    )

    $pattern = '(?ms)^  {0}:\s*\r?\n.*?(?=^  [a-zA-Z0-9_-]+:\s*\r?$|\z)' -f [regex]::Escape($JobName)
    $match = [regex]::Match($WorkflowText, $pattern)
    if (-not $match.Success) {
        return $null
    }
    return $match.Value
}

function Get-TagAttribute {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $match = [regex]::Match($Tag, ('(?i)\b{0}=["'']([^"'']+)["'']' -f [regex]::Escape($Name)))
    if (-not $match.Success) {
        return $null
    }
    return $match.Groups[1].Value
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$prepareScript = Join-Path $repositoryRoot 'scripts\Prepare-PagesArtifact.ps1'
$siteDiscoveryScript = Join-Path $repositoryRoot 'scripts\SiteDiscovery.ps1'
$sitemapGenerator = Join-Path $repositoryRoot 'scripts\Generate-Sitemap.ps1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wdt-site-assets-' + [System.Guid]::NewGuid().ToString('N'))
$artifactRoot = Join-Path $temporaryRoot 'artifact'

Assert-True (Test-Path -LiteralPath $siteDiscoveryScript -PathType Leaf) 'Public site discovery script is missing.'
Assert-True (Test-Path -LiteralPath $sitemapGenerator -PathType Leaf) 'Sitemap generator is missing.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot 'sitemap.xml'))) 'sitemap.xml must not be stored in the source tree.'
. $siteDiscoveryScript

$requiredAssets = @(
    'assets/site.js',
    'assets/social-preview.png',
    'assets/social-preview.svg',
    'assets/style.css',
    'assets/tui-result-real.png',
    'assets/tui-wide-real.png'
)

$publicHtmlFiles = @(Get-SiteHtmlCandidates -SiteRoot $repositoryRoot)
$publicHtmlPaths = @($publicHtmlFiles | ForEach-Object { Get-RelativePath -Root $repositoryRoot -Path $_.FullName })
$assetPaths = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'assets') -Recurse -File | ForEach-Object {
    Get-RelativePath -Root $repositoryRoot -Path $_.FullName
})
$expectedArtifactPaths = @(@(
    '.nojekyll',
    'robots.txt',
    'run.ps1',
    'sitemap.xml'
) + $assetPaths + $publicHtmlPaths | Sort-Object -Unique)

Assert-True (Test-Path -LiteralPath $prepareScript -PathType Leaf) 'Pages artifact preparation script is missing.'

New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    & $prepareScript -OutputPath $artifactRoot

    $artifactFiles = @(Get-ChildItem -LiteralPath $artifactRoot -Recurse -File -Force)
    $artifactPaths = @($artifactFiles | ForEach-Object { Get-RelativePath -Root $artifactRoot -Path $_.FullName })
    $missingArtifactPaths = @($expectedArtifactPaths | Where-Object { $_ -notin $artifactPaths })
    $unexpectedArtifactPaths = @($artifactPaths | Where-Object { $_ -notin $expectedArtifactPaths })
    Assert-True ($artifactFiles.Count -eq $expectedArtifactPaths.Count) "Pages artifact contains $($artifactFiles.Count) files; expected $($expectedArtifactPaths.Count)."
    Assert-True ($missingArtifactPaths.Count -eq 0) "Pages artifact is missing: $($missingArtifactPaths -join ', ')"
    Assert-True ($unexpectedArtifactPaths.Count -eq 0) "Pages artifact contains unexpected files: $($unexpectedArtifactPaths -join ', ')"

    $artifactSitemapPath = Join-Path $artifactRoot 'sitemap.xml'
    [xml]$artifactSitemap = Get-Content -LiteralPath $artifactSitemapPath -Raw
    Assert-True (@($artifactSitemap.urlset.url).Count -gt 0) 'Generated Pages artifact sitemap contains no URLs.'
    Assert-True (@($artifactSitemap.urlset.url | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.lastmod) }).Count -eq 0) 'Generated Pages artifact sitemap contains a URL without lastmod.'

    foreach ($forbiddenPath in @('.git', '.github', 'tests', 'scripts', 'README.md', 'LICENSE')) {
        Assert-True (@($artifactPaths | Where-Object { $_ -eq $forbiddenPath -or $_.StartsWith($forbiddenPath + '/', [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) "Pages artifact contains forbidden content: $forbiddenPath"
    }

    $htmlFiles = $publicHtmlFiles
    Assert-True ($htmlFiles.Count -ge 2) "Expected at least two public HTML files; found $($htmlFiles.Count)."

    foreach ($htmlFile in $htmlFiles) {
        $html = Get-Content -LiteralPath $htmlFile.FullName -Raw
        Assert-True ($html -notmatch '(?i)\b(?:href|src)=["'']/') "Root-relative reference breaks project-site staging: $($htmlFile.FullName)"
        Assert-True ($html -notmatch '0x0bug\.github\.io/windows-diagnostics-toolkit') "Legacy project-site URL remains: $($htmlFile.FullName)"
        Assert-True ($html -notmatch '(?i)support\.js|text/x-dc|#/guides') "Prototype runtime or hash routing remains: $($htmlFile.FullName)"
        Assert-True ($html -notmatch '(?i)fonts\.(?:googleapis|gstatic)\.com') "External font CDN remains: $($htmlFile.FullName)"
        Assert-True ($html -match '(?i)<link\s+[^>]*rel=["'']icon["''][^>]*>') "Favicon link is missing: $($htmlFile.FullName)"
        Assert-True ($html -match '(?i)<button\s+[^>]*class=["''][^"'']*(?:wnav-toggle|nav-toggle)[^"'']*["''][^>]*aria-expanded=["'']false["'']') "Accessible mobile menu toggle is missing: $($htmlFile.FullName)"
        Assert-True ($html -match '(?i)<script\s+[^>]*src=["''][^"'']*assets/site\.js["''][^>]*defer') "Shared interaction script is missing: $($htmlFile.FullName)"
    }

    foreach ($relativePath in $requiredAssets) {
        $asset = Get-Item -LiteralPath (Join-Path $repositoryRoot $relativePath)
        Assert-True ($asset.Length -gt 0) "Asset is empty: $relativePath"
    }

    $socialPreviewSvg = Get-Content -LiteralPath (Join-Path $repositoryRoot 'assets\social-preview.svg') -Raw
    [xml]$socialPreviewSvg | Out-Null
    Assert-True ($socialPreviewSvg -notmatch '\[x\]\s+PRIVATE\b') 'Social preview SVG still contains the misleading [x] PRIVATE claim.'
    Assert-True ($socialPreviewSvg -match '\[x\]\s+PRIVACY MODE\b') 'Social preview SVG is missing the approved [x] PRIVACY MODE wording.'

    $socialPreviewPng = [System.IO.File]::ReadAllBytes((Join-Path $repositoryRoot 'assets\social-preview.png'))
    $pngSignature = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
    Assert-True ($socialPreviewPng.Length -gt 1024) 'Social preview PNG is below the minimum reasonable encoded image size.'
    for ($index = 0; $index -lt $pngSignature.Length; $index++) {
        Assert-True ($socialPreviewPng[$index] -eq $pngSignature[$index]) 'assets/social-preview.png does not have a PNG signature.'
    }
    $pngPrefix = [System.Text.Encoding]::ASCII.GetString($socialPreviewPng, 0, [Math]::Min(64, $socialPreviewPng.Length))
    Assert-True ($pngPrefix -notmatch '(?i)<svg|<\?xml|<!doctype|<html') 'assets/social-preview.png contains text or SVG data instead of an encoded PNG.'
    $ihdrLength = ([int64]$socialPreviewPng[8] * 16777216) + ([int64]$socialPreviewPng[9] * 65536) + ([int64]$socialPreviewPng[10] * 256) + $socialPreviewPng[11]
    $ihdrType = [System.Text.Encoding]::ASCII.GetString($socialPreviewPng, 12, 4)
    Assert-True ($ihdrLength -eq 13 -and $ihdrType -eq 'IHDR') 'Social preview PNG must begin with a 13-byte IHDR chunk.'
    $pngWidth = ([int64]$socialPreviewPng[16] * 16777216) + ([int64]$socialPreviewPng[17] * 65536) + ([int64]$socialPreviewPng[18] * 256) + $socialPreviewPng[19]
    $pngHeight = ([int64]$socialPreviewPng[20] * 16777216) + ([int64]$socialPreviewPng[21] * 65536) + ([int64]$socialPreviewPng[22] * 256) + $socialPreviewPng[23]
    Assert-True ($pngWidth -eq 1280 -and $pngHeight -eq 640) "Social preview PNG dimensions are ${pngWidth}x${pngHeight}; expected 1280x640."
    $iend = $socialPreviewPng[($socialPreviewPng.Length - 12)..($socialPreviewPng.Length - 1)]
    $expectedIend = [byte[]](0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130)
    Assert-True ([System.Linq.Enumerable]::SequenceEqual([byte[]]$iend, $expectedIend)) 'Social preview PNG is missing the canonical zero-length IEND chunk and CRC.'
    Assert-True ((Get-Item -LiteralPath (Join-Path $repositoryRoot 'run.ps1')).Length -gt 0) 'Published run.ps1 is empty.'

    $pagesWorkflowPath = Join-Path $repositoryRoot '.github\workflows\pages.yml'
    $pagesWorkflow = Get-Content -LiteralPath $pagesWorkflowPath -Raw
    Assert-True ($pagesWorkflow -notmatch '(?m)^\s*contents:\s*write\s*$') 'Pages workflow must not use a write token to commit generated sitemap data.'
    $validateJob = Get-WorkflowJobBlock -WorkflowText $pagesWorkflow -JobName 'validate'
    $verifyBootstrapJob = Get-WorkflowJobBlock -WorkflowText $pagesWorkflow -JobName 'verify-bootstrap'
    $packageJob = Get-WorkflowJobBlock -WorkflowText $pagesWorkflow -JobName 'package'
    $deployJob = Get-WorkflowJobBlock -WorkflowText $pagesWorkflow -JobName 'deploy'

    Assert-True (-not [string]::IsNullOrWhiteSpace($validateJob)) 'Pages workflow is missing the validate job.'
    Assert-True ($validateJob -match '(?m)^\s*fetch-depth:\s*0\s*$') 'validate checkout must fetch full history for Git-derived sitemap dates.'
    Assert-True ($validateJob -match 'tests/sitemap\.tests\.ps1') 'validate must run the sitemap test suite.'
    Assert-True ($validateJob -notmatch 'git diff --exit-code -- sitemap\.xml') 'validate must not depend on a committed generated sitemap.'
    Assert-True ($validateJob -match 'tests/site-seo\.tests\.ps1') 'validate must run the SEO test suite.'
    Assert-True ($validateJob -match 'tests/site-assets\.tests\.ps1') 'validate must run the asset test suite.'
    Assert-True (-not [string]::IsNullOrWhiteSpace($verifyBootstrapJob)) 'Pages workflow is missing the verify-bootstrap job.'
    Assert-True ($verifyBootstrapJob -match '(?m)^    runs-on:\s*ubuntu-latest\s*$') 'verify-bootstrap must run on ubuntu-latest.'
    Assert-True ($verifyBootstrapJob -match '(?ms)^    permissions:\s*\r?\n      contents:\s*read\s*$') 'verify-bootstrap must grant only contents: read.'
    Assert-True ($verifyBootstrapJob -notmatch '(?m)^\s*continue-on-error:') 'verify-bootstrap must not use continue-on-error.'
    Assert-True ($verifyBootstrapJob -match 'tests/bootstrap-sync\.tests\.ps1') 'verify-bootstrap must use the byte-for-byte comparison test.'
    Assert-True (@([regex]::Matches($verifyBootstrapJob, '(?m)^\s*persist-credentials:\s*false\s*$')).Count -eq 2) 'Both verify-bootstrap checkouts must disable persisted credentials.'
    Assert-True ($verifyBootstrapJob -match '(?m)^\s*repository:\s*0x0bug/windows-diagnostics-toolkit\s*$') 'verify-bootstrap must checkout the WDT repository.'
    Assert-True ($verifyBootstrapJob -match '(?m)^\s*ref:\s*main\s*$') 'verify-bootstrap must compare against WDT main.'
    Assert-True ($packageJob -match '(?m)^    needs:\s*\[\s*validate\s*,\s*verify-bootstrap\s*\]\s*$') 'package must depend on validate and verify-bootstrap.'
    Assert-True ($packageJob -match '(?m)^    if:\s*github\.ref\s*==\s*[''"]refs/heads/main[''"]\s*$') 'package must be restricted to the main branch.'
    Assert-True ($packageJob -match '(?m)^\s*fetch-depth:\s*0\s*$') 'package checkout must fetch full history for Git-derived sitemap dates.'
    Assert-True ($packageJob -match 'scripts/Prepare-PagesArtifact\.ps1') 'package must prepare the Pages artifact.'
    $prepareScriptText = Get-Content -LiteralPath $prepareScript -Raw
    Assert-True ($prepareScriptText -match 'Generate-Sitemap\.ps1') 'Pages artifact preparation must generate sitemap.xml.'
    Assert-True ($prepareScriptText -match '(?s)-OutputPath\s+\(Join-Path\s+\$outputRoot\s+[''"]sitemap\.xml[''"]\)') 'Pages artifact preparation must write sitemap.xml inside the artifact root.'
    Assert-True ($deployJob -match '(?m)^    needs:\s*package\s*$') 'deploy must depend only on package.'

    $productionSmokeText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'tests\production-smoke.tests.ps1') -Raw
    Assert-True ($productionSmokeText -match 'SiteDiscovery\.ps1') 'Production smoke must load the shared HTML attribute parser.'
    Assert-True ($productionSmokeText -match 'Get-HtmlTagAttribute') 'Production smoke canonical extraction must be independent of attribute order.'

    $workflowFiles = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot '.github\workflows') -File | Where-Object { $_.Extension -in @('.yml', '.yaml') })
    foreach ($workflowFile in $workflowFiles) {
        $workflowText = Get-Content -LiteralPath $workflowFile.FullName -Raw
        foreach ($usesMatch in [regex]::Matches($workflowText, '(?m)^\s*uses:\s*[^@\s]+@([^\s#]+)')) {
            $reference = $usesMatch.Groups[1].Value
            Assert-True ($reference -match '^[0-9a-fA-F]{40}$') "$($workflowFile.Name) contains an Action reference that is not pinned to a full commit SHA: $reference"
        }
    }

    $gitAttributesPath = Join-Path $repositoryRoot '.gitattributes'
    Assert-True (Test-Path -LiteralPath $gitAttributesPath -PathType Leaf) 'Repository root is missing .gitattributes; the PowerShell LF policy must be repository-owned.'
    $gitAttributesLines = @(Get-Content -LiteralPath $gitAttributesPath)
    Assert-True (@($gitAttributesLines | Where-Object { $_ -match '^\s*\*\.ps1\s+text\s+eol=lf\s*$' }).Count -ge 1) '.gitattributes does not contain the active rule: *.ps1 text eol=lf'
    $publishedBootstrapBytes = [System.IO.File]::ReadAllBytes((Join-Path $repositoryRoot 'run.ps1'))
    Assert-True ([System.Array]::IndexOf($publishedBootstrapBytes, [byte]13) -lt 0) 'run.ps1 checkout contains CR bytes; the byte-for-byte bootstrap comparison requires LF. Re-checkout PowerShell files (for example: git checkout -- .).'

    $dependabotPath = Join-Path $repositoryRoot '.github\dependabot.yml'
    Assert-True (Test-Path -LiteralPath $dependabotPath -PathType Leaf) 'Dependabot configuration is missing: .github/dependabot.yml'
    $dependabotText = Get-Content -LiteralPath $dependabotPath -Raw
    Assert-True ($dependabotText -match '(?m)^version:\s*2\s*$') 'dependabot.yml must declare version: 2.'
    Assert-True ($dependabotText -match '(?m)^\s*-\s*package-ecosystem:\s*"github-actions"\s*$') 'dependabot.yml must cover the github-actions ecosystem.'
    Assert-True ($dependabotText -match '(?m)^\s*directory:\s*"/"\s*$') 'dependabot.yml must cover the repository root directory.'

    Assert-True ($pagesWorkflow -match '(?m)^  group:\s*pages-\$\{\{\s*github\.ref\s*\}\}\s*$') 'Pages concurrency group must be scoped per ref: pages-${{ github.ref }}'
    Assert-True ($pagesWorkflow -match '(?m)^  cancel-in-progress:\s*false\s*$') 'Pages concurrency must keep cancel-in-progress: false.'

    $checkoutShas = New-Object System.Collections.Generic.List[string]
    foreach ($workflowFile in $workflowFiles) {
        $workflowText = Get-Content -LiteralPath $workflowFile.FullName -Raw
        foreach ($checkoutMatch in [regex]::Matches($workflowText, '(?m)^\s*uses:\s*actions/checkout@([0-9a-fA-F]{40})\b')) {
            $checkoutShas.Add($checkoutMatch.Groups[1].Value.ToLowerInvariant())
        }
    }
    $uniqueCheckoutShas = @($checkoutShas | Sort-Object -Unique)
    Assert-True ($checkoutShas.Count -ge 1) 'No pinned actions/checkout references were found in the workflows.'
    Assert-True ($uniqueCheckoutShas.Count -eq 1) "actions/checkout must be pinned to one consistent commit SHA across all workflows; found: $($uniqueCheckoutShas -join ', ')"

    $indexHtml = Get-Content -LiteralPath (Join-Path $repositoryRoot 'index.html') -Raw
    $siteJavaScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'assets\site.js') -Raw
    $bootstrapCommand = 'irm https://wdt.digital/run.ps1 | iex'
    $releaseUrl = 'https://github.com/0x0bug/windows-diagnostics-toolkit/releases/tag/v0.2.0-beta.1'
    $zipUrl = 'https://github.com/0x0bug/windows-diagnostics-toolkit/releases/download/v0.2.0-beta.1/windows-diagnostics-toolkit-v0.2.0-beta.1.zip'
    $checksumUrl = 'https://github.com/0x0bug/windows-diagnostics-toolkit/releases/download/v0.2.0-beta.1/windows-diagnostics-toolkit-v0.2.0-beta.1.zip.sha256'
    $zipSha256 = '830bd4e3cf94c101fc320eb6aaf899f46963f9ca6b06f6596f8d57fcf9af5211'
    $homeJsonLdMatch = [regex]::Match($indexHtml, '(?is)<script\s+[^>]*type=["'']application/ld\+json["''][^>]*>(.*?)</script>')
    Assert-True $homeJsonLdMatch.Success 'Home page is missing JSON-LD.'
    $homeStructuredData = $homeJsonLdMatch.Groups[1].Value | ConvertFrom-Json
    $softwareApplication = @($homeStructuredData.'@graph' | Where-Object { $_.'@type' -ceq 'SoftwareApplication' })
    Assert-True ($softwareApplication.Count -eq 1) 'Home JSON-LD must contain exactly one SoftwareApplication.'
    Assert-True ($softwareApplication[0].softwareVersion -ceq '0.2.0-beta.1') 'SoftwareApplication softwareVersion is incorrect.'
    Assert-True ($softwareApplication[0].downloadUrl -ceq $zipUrl) 'SoftwareApplication downloadUrl is incorrect.'
    Assert-True ($softwareApplication[0].releaseNotes -ceq $releaseUrl) 'SoftwareApplication releaseNotes is incorrect.'
    foreach ($feature in @('Selective module collection', 'Command-line automation', 'Findings summary', 'Local TXT and Markdown reports', 'Privacy Mode', 'Windows PowerShell 5.1 and PowerShell 7+', 'No agent or third-party dependencies')) {
        Assert-True ($feature -cin @($softwareApplication[0].featureList)) "SoftwareApplication featureList is missing: $feature"
    }
    Assert-True (@([regex]::Matches($indexHtml, [regex]::Escape($bootstrapCommand))).Count -eq 1) 'Home page must contain exactly one primary bootstrap command.'
    $quickCommandMatch = [regex]::Match($indexHtml, '(?is)<pre\b[^>]*\bid=["'']quick-command["''][^>]*>(.*?)</pre>')
    Assert-True $quickCommandMatch.Success 'Home page is missing the quick-command copy target.'
    $quickCommandText = [System.Net.WebUtility]::HtmlDecode([regex]::Replace($quickCommandMatch.Groups[1].Value, '<[^>]+>', ''))
    $quickCommandText = ($quickCommandText -replace '(?m)^\s*PS>\s?', '').Trim()
    Assert-True ($quickCommandText -ceq $bootstrapCommand) 'Quick-start COPY target does not contain the canonical bootstrap command.'
    Assert-True ($indexHtml -match '(?i)<section\b[^>]*\bid=["'']quick-start["'']') 'Quick-start section is missing its permanent ID.'
    Assert-True (@([regex]::Matches($indexHtml, '(?i)href=["'']#quick-start["'']')).Count -eq 3) 'Header, hero and bottom CTA must target #quick-start.'
    Assert-True ($indexHtml.Contains($releaseUrl)) 'Home page is missing the GitHub prerelease URL.'
    Assert-True ($indexHtml.Contains($zipUrl)) 'Home page is missing the release ZIP URL.'
    Assert-True ($indexHtml.Contains($checksumUrl)) 'Home page is missing the release checksum URL.'
    Assert-True ($indexHtml.Contains($zipSha256)) 'Home page is missing the release ZIP SHA-256.'
    Assert-True ($indexHtml.Contains('irm https://wdt.digital/run.ps1 -OutFile .\wdt-run.ps1')) 'Home page is missing the bootstrap inspection workflow.'
    foreach ($staleCopy in @('no beta release ZIP is published yet', 'planned v0.1.0-beta', 'until that beta is published', 'bootstrap is prepared')) {
        Assert-True ($indexHtml.IndexOf($staleCopy, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "Home page contains stale prerelease copy: $staleCopy"
    }
    Assert-True ($indexHtml -match '(?i)<[^>]+\brole=["'']status["''][^>]+\baria-live=["'']polite["'']') 'Copy feedback is missing a polite screen-reader status element.'
    Assert-True ($indexHtml -match '(?i)<button[^>]+\bdata-copy-status=["''][^"'']+["''][^>]*>') 'Copy button is not associated with the status element.'
    Assert-True ($siteJavaScript -match '\.textContent\s*=') 'Copy feedback must update status text without HTML injection.'
    Assert-True ($siteJavaScript -notmatch '\.innerHTML\s*=') 'Copy feedback must not use innerHTML.'
    Assert-True ($siteJavaScript -match 'copied to the clipboard') 'Copy success is not announced.'
    Assert-True ($siteJavaScript -match 'Clipboard access failed') 'Copy fallback is not announced.'
    foreach ($articlePath in @($expectedArtifactPaths | Where-Object { $_ -like 'cases/windows-*.html' })) {
        $articleHtml = Get-Content -LiteralPath (Join-Path $repositoryRoot $articlePath) -Raw
        Assert-True ($articleHtml -match '(?i)<button[^>]+data-copy-(?:text|target)=["''][^"'']+["''][^>]+data-copy-status=["''][^"'']+["'']') "Article command copy control is missing: $articlePath"
    }
    Assert-True ($indexHtml -match [regex]::Escape('This simulation runs only in the browser.')) 'TUI simulation disclosure is missing.'
    Assert-True ($indexHtml -match [regex]::Escape('Output: .\WindowsDiagnosticsReports')) 'TUI default output directory is inaccurate.'
    Assert-True ($indexHtml -match 'data-tui-module' -and $indexHtml -match 'data-tui-option' -and $indexHtml -match 'data-tui-action=["'']run["'']') 'Interactive TUI controls are missing.'
    foreach ($anchor in @('try', 'quick-start', 'checks', 'privacy', 'guides', 'faq')) {
        Assert-True ($indexHtml -match ('(?i)\bid=["'']{0}["'']' -f [regex]::Escape($anchor))) "Required homepage anchor is missing: #$anchor"
    }
    foreach ($selector in @('-Module System', '-Module Performance', '-Module Network', '-Module Security', '-Module Disk', '-Module Crashes,Events', '-Module Services', '-Module Updates,Time')) {
        Assert-True ($indexHtml.Contains($selector)) "Verified diagnostic selector is missing: $selector"
    }
    Assert-True (@([regex]::Matches($indexHtml, '(?i)<article\b[^>]*class=["''][^"'']*diagnostic-card[^"'']*["'']')).Count -eq 8) 'Homepage must contain exactly eight diagnostic groups.'
    Assert-True (@([regex]::Matches($indexHtml, '(?i)<details\b')).Count -eq 9) 'Homepage must contain the screenshot, release and five FAQ details elements.'
    Assert-True ($indexHtml -notmatch [regex]::Escape('Three steps, one file at the end.')) 'Removed workflow section is still present.'
    foreach ($state in @('QUEUED', 'RUNNING', '[OK]', '[WARN]', '[ERROR]')) {
        Assert-True ($indexHtml -match [regex]::Escape($state) -or $siteJavaScript -match [regex]::Escape($state)) "TUI state is missing: $state"
    }
    Assert-True ($siteJavaScript -match 'prefers-reduced-motion') 'Reduced-motion behavior is missing from JavaScript.'
    Assert-True ($siteJavaScript -match "event\.key\s*-eq\s*'Escape'|event\.key\s*===\s*'Escape'") 'Escape-key handling is missing.'
    Assert-True ($siteJavaScript -match 'restoreFocus') 'Mobile menu focus restoration is missing.'
    $focusSync = [regex]::Match($siteJavaScript, '(?s)const syncTabSemantics\s*=.*?\n\s*};')
    Assert-True ($focusSync.Success) 'Responsive tab semantics synchronizer is missing.'
    Assert-True ($siteJavaScript -match 'const panelByTab\s*=\s*new Map' -and $siteJavaScript -match 'getAttribute\([''\"]aria-controls[''\"]\)') 'Responsive tabs must explicitly map each tab to its aria-controls panel.'
    Assert-True ($focusSync.Value -match 'const activeElement\s*=\s*document\.activeElement' -and $focusSync.Value -match 'tabsContainer\?\.contains\(activeElement\)') 'Responsive tabs must capture activeElement and distinguish focus inside the tablist before changing layout.'
    Assert-True ($focusSync.Value -match 'focusInTabs' -and $focusSync.Value -match 'focusPanel\(activePanel\)' -and $focusSync.Value.IndexOf('focusPanel(activePanel)', [System.StringComparison]::Ordinal) -lt $focusSync.Value.IndexOf('terminal.dataset.layout', [System.StringComparison]::Ordinal)) 'Focused mobile tabs must transfer focus to their mapped panel before the tablist is hidden.'
    Assert-True ($focusSync.Value -match '!wasCompact\s*&&\s*compact\s*&&\s*focusOnTransferredPanel' -and $focusSync.Value -match 'activeTab\?\.focus\(\)') 'Desktop-to-mobile transitions must restore a previously transferred panel focus to its related tab only.'

    Assert-True ($indexHtml -match 'navigate\s+[^<]*Space / Enter toggle') 'Visible module keyboard hint does not describe the supported toggle keys.'
    Assert-True ($indexHtml -match 'A all\s+[^<]*R recommended\s+[^<]*Enter on Run') 'Visible TUI shortcut hint does not describe the implemented actions.'
    foreach ($key in @('ArrowUp', 'ArrowDown', "event.key.toLowerCase() === 'a'", "event.key.toLowerCase() === 'r'")) {
        Assert-True ($siteJavaScript -match [regex]::Escape($key)) "TUI keyboard hint advertises an unimplemented key: $key"
    }
    Assert-True ($siteJavaScript -match 'setModuleTabStop') 'TUI module list is missing roving-tabindex behavior.'
    $moduleTags = @([regex]::Matches($indexHtml, '(?i)<button\b[^>]*\bdata-tui-module=["''][^"'']+["''][^>]*>'))
    Assert-True ($moduleTags.Count -eq 10) "Expected 10 TUI module buttons; found $($moduleTags.Count)."
    Assert-True (@($moduleTags | Where-Object { $_.Value -match '(?i)\btabindex=["'']0["'']' }).Count -eq 1) 'TUI module roving tabindex must expose exactly one initial tab stop.'
    Assert-True (@($moduleTags | Where-Object { $_.Value -match '(?i)\btabindex=["'']-1["'']' }).Count -eq 9) 'All non-active TUI module buttons must start outside the tab order.'

    $tabTags = @([regex]::Matches($indexHtml, '(?i)<button\b[^>]*\bdata-tui-tab=["''][^"'']+["''][^>]*>'))
    $panelTags = @([regex]::Matches($indexHtml, '(?i)<div\b[^>]*\bdata-panel=["''][^"'']+["''][^>]*>'))
    Assert-True ($tabTags.Count -eq 3 -and $panelTags.Count -eq 3) 'TUI must contain exactly three tabs and three panels.'
    $documentIds = @([regex]::Matches($indexHtml, '(?i)\bid=["'']([^"'']+)["'']') | ForEach-Object { $_.Groups[1].Value })
    Assert-True (@($documentIds | Select-Object -Unique).Count -eq $documentIds.Count) 'Homepage contains duplicate id values.'
    foreach ($tabMatch in $tabTags) {
        $tabId = Get-TagAttribute -Tag $tabMatch.Value -Name 'id'
        $panelId = Get-TagAttribute -Tag $tabMatch.Value -Name 'aria-controls'
        Assert-True (-not [string]::IsNullOrWhiteSpace($tabId) -and -not [string]::IsNullOrWhiteSpace($panelId)) 'Every TUI tab must have an id and aria-controls.'
        $matchingPanels = @($panelTags | Where-Object { (Get-TagAttribute -Tag $_.Value -Name 'id') -eq $panelId })
        Assert-True ($matchingPanels.Count -eq 1) "Tab $tabId does not control exactly one panel: $panelId"
        Assert-True ((Get-TagAttribute -Tag $matchingPanels[0].Value -Name 'aria-labelledby') -eq $tabId) "Panel $panelId is not labelled by tab $tabId."
    }
    Assert-True ($indexHtml -notmatch '(?i)\brole=["''](?:tablist|tab|tabpanel)["'']') 'Desktop source HTML must not expose inactive tab roles.'
    foreach ($role in @('tablist', 'tab', 'tabpanel')) {
        Assert-True ($siteJavaScript -match [regex]::Escape("setAttribute('role', '$role')")) "Mobile adaptive logic does not apply role=$role."
    }
    Assert-True ($siteJavaScript -match "removeAttribute\('role'\)" -and $siteJavaScript -match 'compactTui\.addEventListener') 'Desktop/mobile resize logic does not remove obsolete tab roles.'

    $sampleReportPath = Join-Path $repositoryRoot 'sample-report\index.html'
    $sampleReportHtml = Get-Content -LiteralPath $sampleReportPath -Raw
    Assert-True ($sampleReportHtml -match '(?i)<html\s+lang=["'']en["'']') 'Sample report language is missing or incorrect.'
    Assert-True ($sampleReportHtml -match '(?i)<link\s+[^>]*rel=["'']canonical["''][^>]*href=["'']https://wdt\.digital/sample-report/["'']') 'Sample report canonical is incorrect.'
    Assert-True ($sampleReportHtml -match '(?i)data-copy-target=["'']sample-report-full["'']') 'Sample report copy control is missing.'
    Assert-True ($sampleReportHtml -match [regex]::Escape('These values do not describe a real system.')) 'Sample report does not identify its demonstration data.'
    Assert-True ($sampleReportHtml -match [regex]::Escape('docs/report-example.md')) 'Sample report source link is missing.'

    $observerRegistration = $siteJavaScript.IndexOf('revealObserver.observe(element)', [System.StringComparison]::Ordinal)
    $motionOptIn = $siteJavaScript.IndexOf("classList.add('wdt-motion')", [System.StringComparison]::Ordinal)
    Assert-True ($observerRegistration -ge 0 -and $motionOptIn -gt $observerRegistration) 'Motion must opt in only after the IntersectionObserver owns all reveal targets.'
    Assert-True ($siteJavaScript -match "classList.remove\('wdt-motion'\)") 'Motion initialization errors must restore the fail-visible state.'
    Assert-True ($siteJavaScript -notmatch '2400') 'A reveal watchdog must not be the primary content-visibility mechanism.'

    $styleSheet = Get-Content -LiteralPath (Join-Path $repositoryRoot 'assets\style.css') -Raw
    Assert-True ($styleSheet -notmatch '(?s)\[data-reveal=["'']scroll["'']\][^{]*\{[^}]*opacity\s*:\s*0') 'CSS hides unrevealed scroll content before IntersectionObserver callbacks.'
    Assert-True ($styleSheet -notmatch '(?s)\[data-seq=["'']wait["'']\][^{]*\{[^}]*opacity\s*:\s*0') 'CSS hides the hero sequence before JavaScript starts it.'
    Assert-True ($styleSheet -notmatch '(?s)@keyframes\s+revealIn\s*\{[^}]*opacity\s*:\s*0') 'Reveal motion must remain visible if a background tab pauses its animation.'
    Assert-True ($styleSheet -notmatch '(?m)^\s*\+\s*$') 'Stylesheet contains a stray standalone + token.'
    Assert-True ($styleSheet -match '@media\s*\(prefers-reduced-motion:\s*reduce\)') 'Reduced-motion CSS is missing.'
    Assert-True ($styleSheet -match '--accent:\s*#46e08a') 'Approved green accent token is missing.'
    $dimMatch = [regex]::Match($styleSheet, '--dim:\s*(#[0-9a-fA-F]{6})')
    Assert-True ($dimMatch.Success) 'CSS --dim color is missing or is not a six-digit hex value.'
    $dimColor = $dimMatch.Groups[1].Value
    foreach ($background in @('#000000', '#070909', '#0c1010', '#111616')) {
        $ratio = Get-ContrastRatio -Foreground $dimColor -Background $background
        Assert-True ($ratio -ge 4.5) "--dim $dimColor has contrast $($ratio.ToString('0.000')):1 on $background; expected at least 4.5:1."
    }

    $guidesIndexHtml = Get-Content -LiteralPath (Join-Path $repositoryRoot 'cases\index.html') -Raw
    $breadcrumb = [regex]::Match($guidesIndexHtml, '(?is)<nav\b[^>]*aria-label=["'']Breadcrumb["''][^>]*>.*?</nav>')
    Assert-True ($breadcrumb.Success) 'Guides breadcrumb must be a named navigation landmark.'
    Assert-True ($breadcrumb.Value -match '(?is)<ol\b[^>]*>.*?</ol>') 'Guides breadcrumb landmark must contain an ordered list.'
    $currentBreadcrumbItems = @([regex]::Matches($breadcrumb.Value, '(?i)aria-current=["'']page["'']'))
    Assert-True ($currentBreadcrumbItems.Count -eq 1) "Guides breadcrumb must contain exactly one aria-current=page item; found $($currentBreadcrumbItems.Count)."

    foreach ($htmlFile in @($htmlFiles | Where-Object { $_.Name -ne '404.html' })) {
        $metadataHtml = Get-Content -LiteralPath $htmlFile.FullName -Raw
        Assert-True ($metadataHtml -match '(?i)<meta\s+[^>]*property=["'']og:image["''][^>]*content=["'']https://wdt\.digital/assets/social-preview\.png["'']') "og:image does not reference the current social preview: $($htmlFile.FullName)"
        Assert-True ($metadataHtml -match '(?i)<meta\s+[^>]*name=["'']twitter:image["''][^>]*content=["'']https://wdt\.digital/assets/social-preview\.png["'']') "twitter:image does not reference the current social preview: $($htmlFile.FullName)"
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Host "Site asset and Pages artifact tests passed with PowerShell $($PSVersionTable.PSVersion)."
