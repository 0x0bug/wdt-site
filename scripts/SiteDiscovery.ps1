$ErrorActionPreference = 'Stop'

function Get-SiteRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$SiteRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $separatorCharacters = [char[]]@('\', '/')
    $siteRootFull = [System.IO.Path]::GetFullPath($SiteRoot).TrimEnd($separatorCharacters)
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($siteRootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the site root: $Path"
    }

    return $pathFull.Substring($siteRootFull.Length).TrimStart($separatorCharacters).Replace('\', '/')
}

function Test-IsPublicHtmlCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$SiteRoot,
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$File
    )

    $relativePath = Get-SiteRelativePath -SiteRoot $SiteRoot -Path $File.FullName
    $segments = @($relativePath.Split('/'))
    $excludedDirectories = @(
        '.git',
        '.github',
        '.openai',
        '_site',
        'artifact',
        'artifacts',
        'assets',
        'build',
        'coverage',
        'dev',
        'dist',
        'fixture',
        'fixtures',
        'internal',
        'node_modules',
        'obj',
        'out',
        'scripts',
        'target',
        'test-fixtures',
        'tests',
        'windows-diagnostics-toolkit'
    )

    for ($index = 0; $index -lt ($segments.Count - 1); $index++) {
        $segment = $segments[$index]
        if ($segment.StartsWith('.', [System.StringComparison]::Ordinal) -or $segment -in $excludedDirectories) {
            return $false
        }
    }

    return $File.Name -notmatch '(?i)(?:^|[._-])(?:fixture|spec|test)(?:[._-]|$)'
}

function Get-SiteHtmlCandidates {
    param([Parameter(Mandatory = $true)][string]$SiteRoot)

    if (-not (Test-Path -LiteralPath $SiteRoot -PathType Container)) {
        throw "Site root is missing: $SiteRoot"
    }

    $relativePaths = @(& git -c core.quotepath=false -C $SiteRoot ls-files --cached --others --exclude-standard -- '*.html')
    $gitExitCode = $LASTEXITCODE
    if ($gitExitCode -ne 0) {
        throw "git ls-files failed while discovering public HTML under: $SiteRoot"
    }

    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($relativePath in @($relativePaths | Sort-Object -Unique)) {
        $fullPath = Join-Path $SiteRoot $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            continue
        }
        $file = Get-Item -LiteralPath $fullPath
        if (Test-IsPublicHtmlCandidate -SiteRoot $SiteRoot -File $file) {
            $files.Add($file)
        }
    }

    return @($files | Sort-Object -Property FullName)
}

function Get-ExpectedCanonicalUrl {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $normalizedPath = $RelativePath.Replace('\', '/').TrimStart('/')
    if ($normalizedPath -ceq 'index.html') {
        return 'https://wdt.digital/'
    }
    if ($normalizedPath.EndsWith('/index.html', [System.StringComparison]::Ordinal)) {
        return 'https://wdt.digital/' + $normalizedPath.Substring(0, $normalizedPath.Length - 'index.html'.Length)
    }
    return 'https://wdt.digital/' + $normalizedPath
}

function Get-HtmlTagAttribute {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $match = [regex]::Match($Tag, ('(?i)\b{0}=["'']([^"'']+)["'']' -f [regex]::Escape($Name)))
    if (-not $match.Success) {
        return $null
    }
    return [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value.Trim())
}

function Get-IndexableSitePages {
    param([Parameter(Mandatory = $true)][string]$SiteRoot)

    $canonicalOwners = @{}
    $pages = New-Object System.Collections.Generic.List[object]

    foreach ($file in @(Get-SiteHtmlCandidates -SiteRoot $SiteRoot)) {
        $relativePath = Get-SiteRelativePath -SiteRoot $SiteRoot -Path $file.FullName
        if ($file.Name -ieq '404.html') {
            continue
        }

        $html = Get-Content -LiteralPath $file.FullName -Raw
        $robotsTags = @([regex]::Matches($html, '(?is)<meta\b[^>]*>') | ForEach-Object {
            $name = Get-HtmlTagAttribute -Tag $_.Value -Name 'name'
            if ($name -ieq 'robots') { $_.Value }
        })
        $isNoIndex = $false
        foreach ($robotsTag in $robotsTags) {
            $robotsContent = Get-HtmlTagAttribute -Tag $robotsTag -Name 'content'
            if ($robotsContent -match '(?i)(?:^|[\s,])(?:noindex|none)(?:$|[\s,])') {
                $isNoIndex = $true
                break
            }
        }
        if ($isNoIndex) {
            continue
        }

        $canonicalTags = @([regex]::Matches($html, '(?is)<link\b[^>]*>') | Where-Object {
            $rel = Get-HtmlTagAttribute -Tag $_.Value -Name 'rel'
            $null -ne $rel -and @($rel -split '\s+') -icontains 'canonical'
        })
        if ($canonicalTags.Count -ne 1) {
            throw "$relativePath contains $($canonicalTags.Count) canonical links; expected exactly one."
        }

        $canonical = Get-HtmlTagAttribute -Tag $canonicalTags[0].Value -Name 'href'
        if ([string]::IsNullOrWhiteSpace($canonical)) {
            throw "$relativePath has a canonical link without href."
        }

        try {
            $canonicalUri = [uri]$canonical
        }
        catch {
            throw "$relativePath has an invalid canonical URL: $canonical"
        }
        if (-not $canonicalUri.IsAbsoluteUri -or $canonicalUri.Scheme -cne 'https' -or $canonicalUri.Host -cne 'wdt.digital') {
            throw "$relativePath canonical is outside the production site: $canonical"
        }

        $expectedCanonical = Get-ExpectedCanonicalUrl -RelativePath $relativePath
        if ($canonical -cne $expectedCanonical) {
            throw "$relativePath canonical is $canonical; expected $expectedCanonical"
        }
        if ($canonicalOwners.ContainsKey($canonical)) {
            throw "$relativePath duplicates the canonical used by $($canonicalOwners[$canonical]): $canonical"
        }

        $canonicalOwners[$canonical] = $relativePath
        $pages.Add([pscustomobject]@{
            File = $file
            RelativePath = $relativePath
            Canonical = $canonical
        })
    }

    return @($pages | Sort-Object -Property Canonical)
}

function Get-GitPageLastModified {
    param(
        [Parameter(Mandatory = $true)][string]$SiteRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $gitOutput = @(& git -C $SiteRoot log -1 '--format=%aI' -- $RelativePath 2>$null)
    $gitExitCode = $LASTEXITCODE
    if ($gitExitCode -ne 0) {
        throw "git log failed for public page: $RelativePath"
    }
    $gitDate = $gitOutput | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($gitDate)) {
        throw "Public page has no Git history. Commit it before generating sitemap.xml: $RelativePath"
    }

    $parsedDate = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact(
        $gitDate,
        "yyyy-MM-dd'T'HH:mm:ssK",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsedDate
    )) {
        throw "Git returned a non-W3C timestamp for ${RelativePath}: $gitDate"
    }
    if ($parsedDate.UtcDateTime -gt [DateTime]::UtcNow) {
        throw "Git-derived lastmod is in the future for ${RelativePath}: $gitDate"
    }

    return $gitDate
}
