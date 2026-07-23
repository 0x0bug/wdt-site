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

$expectedArtifactPaths = @(
    '.nojekyll',
    '404.html',
    'index.html',
    'robots.txt',
    'run.ps1',
    'sitemap.xml'
) + $requiredAssets + @(
    'cases/index.html',
    'cases/windows-application-crashes.html',
    'cases/windows-diagnostic-report-for-tech-support.html',
    'cases/windows-disk-health-low-space.html',
    'cases/windows-firewall-disabled.html',
    'cases/windows-high-memory-usage.html',
    'cases/windows-network-routes.html',
    'cases/windows-time-service-stopped.html',
    'cases/windows-update-pending-reboot.html'
)

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

    foreach ($forbiddenPath in @('.git', '.github', 'tests', 'scripts', 'README.md', 'LICENSE')) {
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

    $pagesWorkflowPath = Join-Path $repositoryRoot '.github\workflows\pages.yml'
    $pagesWorkflow = Get-Content -LiteralPath $pagesWorkflowPath -Raw
    $verifyBootstrapJob = Get-WorkflowJobBlock -WorkflowText $pagesWorkflow -JobName 'verify-bootstrap'
    $packageJob = Get-WorkflowJobBlock -WorkflowText $pagesWorkflow -JobName 'package'
    $deployJob = Get-WorkflowJobBlock -WorkflowText $pagesWorkflow -JobName 'deploy'

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
    Assert-True ($deployJob -match '(?m)^    needs:\s*package\s*$') 'deploy must depend only on package.'

    $workflowFiles = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot '.github\workflows') -File | Where-Object { $_.Extension -in @('.yml', '.yaml') })
    foreach ($workflowFile in $workflowFiles) {
        $workflowText = Get-Content -LiteralPath $workflowFile.FullName -Raw
        foreach ($usesMatch in [regex]::Matches($workflowText, '(?m)^\s*uses:\s*[^@\s]+@([^\s#]+)')) {
            $reference = $usesMatch.Groups[1].Value
            Assert-True ($reference -match '^[0-9a-fA-F]{40}$') "$($workflowFile.Name) contains an Action reference that is not pinned to a full commit SHA: $reference"
        }
    }

    $indexHtml = Get-Content -LiteralPath (Join-Path $repositoryRoot 'index.html') -Raw
    $siteJavaScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'assets\site.js') -Raw
    Assert-True ($indexHtml -match '(?i)<[^>]+\brole=["'']status["''][^>]+\baria-live=["'']polite["'']') 'Copy feedback is missing a polite screen-reader status element.'
    Assert-True ($indexHtml -match '(?i)<button[^>]+\bdata-copy-status=["''][^"'']+["''][^>]*>') 'Copy button is not associated with the status element.'
    Assert-True ($siteJavaScript -match '\.textContent\s*=') 'Copy feedback must update status text without HTML injection.'
    Assert-True ($siteJavaScript -notmatch '\.innerHTML\s*=') 'Copy feedback must not use innerHTML.'
    Assert-True ($siteJavaScript -match 'copied to the clipboard') 'Copy success is not announced.'
    Assert-True ($siteJavaScript -match 'Clipboard access failed') 'Copy fallback is not announced.'

    $styleSheet = Get-Content -LiteralPath (Join-Path $repositoryRoot 'assets\style.css') -Raw
    $dimMatch = [regex]::Match($styleSheet, '--dim:\s*(#[0-9a-fA-F]{6})')
    Assert-True ($dimMatch.Success) 'CSS --dim color is missing or is not a six-digit hex value.'
    $dimColor = $dimMatch.Groups[1].Value
    foreach ($background in @('#000000', '#070909', '#0c1010', '#111616')) {
        $ratio = Get-ContrastRatio -Foreground $dimColor -Background $background
        Assert-True ($ratio -ge 4.5) "--dim $dimColor has contrast $($ratio.ToString('0.000')):1 on $background; expected at least 4.5:1."
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Host "Site asset and Pages artifact tests passed with PowerShell $($PSVersionTable.PSVersion)."
