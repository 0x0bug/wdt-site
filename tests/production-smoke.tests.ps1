[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CanonicalBootstrapPath,

    [ValidateNotNullOrEmpty()]
    [string]$BaseUrl = 'https://wdt.digital/',

    [ValidateRange(1, 1000)]
    [int]$MaxSitemapPages = 100
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-SiteHttpClient {
    param(
        [bool]$AllowAutoRedirect,
        [ValidateNotNullOrEmpty()][string]$UserAgent = 'wdt-production-smoke/1.0'
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $AllowAutoRedirect
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd($UserAgent)
    return $client
}

function Assert-NoIndexingHeader {
    param(
        [Parameter(Mandatory = $true)][System.Net.Http.HttpResponseMessage]$Response,
        [Parameter(Mandatory = $true)][string]$Url
    )

    $values = New-Object System.Collections.Generic.List[string]
    if ($Response.Headers.Contains('X-Robots-Tag')) {
        foreach ($value in $Response.Headers.GetValues('X-Robots-Tag')) { $values.Add($value) }
    }
    if ($Response.Content.Headers.Contains('X-Robots-Tag')) {
        foreach ($value in $Response.Content.Headers.GetValues('X-Robots-Tag')) { $values.Add($value) }
    }
    $combined = $values -join ','
    Assert-True ($combined -notmatch '(?i)(?:^|[\s,])(?:noindex|nofollow|none)(?:$|[\s,])') "$url returns a restrictive X-Robots-Tag: $combined"
}

function Assert-HtmlResponse {
    param(
        [Parameter(Mandatory = $true)][System.Net.Http.HttpResponseMessage]$Response,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ExpectedCanonical
    )

    Assert-True ([int]$Response.StatusCode -eq 200) "$Url returned HTTP $([int]$Response.StatusCode), expected 200."
    $mediaType = [string]$Response.Content.Headers.ContentType.MediaType
    Assert-True ($mediaType -in @('text/html', 'application/xhtml+xml')) "$Url returned Content-Type '$mediaType', expected HTML."
    Assert-NoIndexingHeader -Response $Response -Url $Url

    $html = $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    Assert-True ($html -match '(?i)<html\b') "$Url did not return an HTML document."
    Assert-True ($html -notmatch '(?is)<meta\b[^>]*name=["'']robots["''][^>]*content=["''][^"'']*(?:noindex|nofollow|none)') "$Url contains a restrictive meta robots directive."
    $canonicalMatches = @([regex]::Matches($html, '(?is)<link\b[^>]*rel=["'']canonical["''][^>]*href=["'']([^"'']+)["''][^>]*>'))
    Assert-True ($canonicalMatches.Count -eq 1) "$Url contains $($canonicalMatches.Count) canonical links; expected exactly one."
    $canonical = [System.Net.WebUtility]::HtmlDecode($canonicalMatches[0].Groups[1].Value)
    Assert-True ($canonical -ceq $ExpectedCanonical) "$Url canonical is $canonical, expected $ExpectedCanonical"

    return $html
}

function Get-SiteResponse {
    param(
        [Parameter(Mandatory = $true)][System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory = $true)][string]$Url
    )

    return $Client.GetAsync($Url).GetAwaiter().GetResult()
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

Assert-True (Test-Path -LiteralPath $CanonicalBootstrapPath -PathType Leaf) "Canonical bootstrap is missing: $CanonicalBootstrapPath"

$baseUri = [uri]$BaseUrl
Assert-True ($baseUri.Scheme -ceq 'https') "Base URL must use HTTPS: $BaseUrl"
Assert-True ($baseUri.Host -ceq 'wdt.digital') "Unexpected production host: $($baseUri.Host)"
Assert-True ($baseUri.AbsolutePath -ceq '/') "Base URL must point to the site root: $BaseUrl"

$directClient = New-SiteHttpClient -AllowAutoRedirect $false -UserAgent 'wdt-production-smoke/1.0'
$redirectClient = New-SiteHttpClient -AllowAutoRedirect $true -UserAgent 'wdt-production-smoke/1.0'
try {
    $expectedHomeTitle = 'Windows Diagnostics Toolkit (WDT) | Read-Only PowerShell Diagnostics'
    $crawlerUserAgents = [ordered]@{
        'WDT smoke' = 'wdt-production-smoke/1.0'
        'Googlebot' = 'Googlebot'
        'bingbot' = 'bingbot'
        'YandexBot' = 'YandexBot'
        'OAI-SearchBot' = 'OAI-SearchBot'
        'ChatGPT-User' = 'ChatGPT-User'
        'PerplexityBot' = 'PerplexityBot'
        'ClaudeBot' = 'ClaudeBot'
    }
    foreach ($crawlerName in $crawlerUserAgents.Keys) {
        $crawlerClient = New-SiteHttpClient -AllowAutoRedirect $false -UserAgent $crawlerUserAgents[$crawlerName]
        try {
            $crawlerResponse = Get-SiteResponse -Client $crawlerClient -Url $BaseUrl
            try {
                $crawlerHtml = Assert-HtmlResponse -Response $crawlerResponse -Url "$BaseUrl ($crawlerName)" -ExpectedCanonical $BaseUrl
                Assert-True ($crawlerHtml.Contains("<title>$expectedHomeTitle</title>", [System.StringComparison]::Ordinal)) "$crawlerName received HTTP 200 without the expected homepage title; a challenge page may have been returned."
            }
            finally {
                $crawlerResponse.Dispose()
            }
        }
        finally {
            $crawlerClient.Dispose()
        }
    }

    $wwwUrl = 'https://www.wdt.digital/'
    $wwwResponse = Get-SiteResponse -Client $directClient -Url $wwwUrl
    try {
        Assert-True ([int]$wwwResponse.StatusCode -in @(301, 308)) "www returned HTTP $([int]$wwwResponse.StatusCode), expected 301 or 308."
        $redirectLocation = [uri]::new([uri]$wwwUrl, $wwwResponse.Headers.Location).AbsoluteUri
        Assert-True ($redirectLocation -ceq $BaseUrl) "www redirect points to $redirectLocation, expected $BaseUrl"
    }
    finally {
        $wwwResponse.Dispose()
    }

    $wwwFinalResponse = Get-SiteResponse -Client $redirectClient -Url $wwwUrl
    try {
        Assert-True ([int]$wwwFinalResponse.StatusCode -eq 200) "www redirect ended with HTTP $([int]$wwwFinalResponse.StatusCode), expected 200."
        Assert-True ($wwwFinalResponse.RequestMessage.RequestUri.AbsoluteUri -ceq $BaseUrl) "www redirect ended at $($wwwFinalResponse.RequestMessage.RequestUri.AbsoluteUri), expected $BaseUrl"
    }
    finally {
        $wwwFinalResponse.Dispose()
    }

    $resourceBodies = @{}
    $resourceMediaTypes = @{}
    foreach ($relativePath in @('run.ps1', 'robots.txt', 'sitemap.xml', 'assets/style.css', 'assets/site.js')) {
        $resourceUrl = [uri]::new($baseUri, $relativePath).AbsoluteUri
        $response = Get-SiteResponse -Client $directClient -Url $resourceUrl
        try {
            Assert-True ([int]$response.StatusCode -eq 200) "$resourceUrl returned HTTP $([int]$response.StatusCode), expected 200."
            $resourceBodies[$relativePath] = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $resourceMediaTypes[$relativePath] = [string]$response.Content.Headers.ContentType.MediaType
        }
        finally {
            $response.Dispose()
        }
    }

    $sitemapText = [System.Text.Encoding]::UTF8.GetString([byte[]]$resourceBodies['sitemap.xml'])
    $sitemapMediaType = $resourceMediaTypes['sitemap.xml']
    Assert-True ($sitemapMediaType -in @('application/xml', 'text/xml') -or $sitemapMediaType.EndsWith('+xml', [System.StringComparison]::OrdinalIgnoreCase)) "Production sitemap returned Content-Type '$sitemapMediaType', expected XML."
    [xml]$sitemap = $sitemapText
    $sitemapEntries = @($sitemap.urlset.url)
    $sitemapUrls = @($sitemapEntries | ForEach-Object { [string]$_.loc })
    Assert-True ($sitemapUrls.Count -gt 0) 'Production sitemap contains no URLs.'
    Assert-True (@($sitemapUrls | Select-Object -Unique).Count -eq $sitemapUrls.Count) 'Production sitemap contains duplicate URLs.'
    Assert-True ($BaseUrl -in $sitemapUrls) 'Production sitemap does not contain the homepage.'

    foreach ($entry in $sitemapEntries) {
        $url = [string]$entry.loc
        $uri = [uri]$url
        Assert-True ($uri.IsAbsoluteUri) "Sitemap URL is not absolute: $url"
        Assert-True ($uri.Scheme -ceq 'https') "Sitemap URL does not use HTTPS: $url"
        Assert-True ($uri.Host -ceq 'wdt.digital') "Sitemap URL uses an unexpected host: $url"
        Assert-True ($url -notmatch '0x0bug\.github\.io') "Sitemap contains the old Pages host: $url"
        Assert-True ($uri.AbsolutePath -notmatch '/windows-diagnostics-toolkit/') "Sitemap contains the legacy project path: $url"
        $lastModified = [string]$entry.lastmod
        Assert-True (-not [string]::IsNullOrWhiteSpace($lastModified)) "Sitemap URL is missing lastmod: $url"
        $parsedLastModified = [DateTimeOffset]::MinValue
        Assert-True ([DateTimeOffset]::TryParseExact(
            $lastModified,
            "yyyy-MM-dd'T'HH:mm:sszzz",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsedLastModified
        )) "Sitemap lastmod is invalid for ${url}: $lastModified"
        Assert-True ($parsedLastModified.UtcDateTime -le [DateTime]::UtcNow) "Sitemap lastmod is in the future for ${url}: $lastModified"
    }

    $htmlUrls = @($sitemapUrls | Sort-Object)
    if ($htmlUrls.Count -gt $MaxSitemapPages) {
        $htmlUrls = @(@($BaseUrl) + @($htmlUrls | Where-Object { $_ -cne $BaseUrl }) | Select-Object -First $MaxSitemapPages)
        Write-Host "Sitemap has $($sitemapUrls.Count) URLs; validating a deterministic sample of $MaxSitemapPages pages."
    }
    foreach ($url in $htmlUrls) {
        $response = Get-SiteResponse -Client $directClient -Url $url
        try {
            $null = Assert-HtmlResponse -Response $response -Url $url -ExpectedCanonical $url
        }
        finally {
            $response.Dispose()
        }
    }

    $robotsText = [System.Text.Encoding]::UTF8.GetString([byte[]]$resourceBodies['robots.txt'])
    Assert-True ($resourceMediaTypes['robots.txt'] -ceq 'text/plain') "robots.txt returned Content-Type '$($resourceMediaTypes['robots.txt'])', expected text/plain."
    $robotsPolicy = @($robotsText -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith('#')
    })
    $expectedRobotsPolicy = @('User-agent: *', 'Allow: /', 'Sitemap: https://wdt.digital/sitemap.xml')
    Assert-True ($robotsPolicy.Count -eq $expectedRobotsPolicy.Count) 'robots.txt contains crawler-specific or unexpected policy directives.'
    for ($index = 0; $index -lt $expectedRobotsPolicy.Count; $index++) {
        Assert-True ($robotsPolicy[$index] -ceq $expectedRobotsPolicy[$index]) "robots.txt line $($index + 1) is '$($robotsPolicy[$index])', expected '$($expectedRobotsPolicy[$index])'."
    }
    Assert-True ($robotsText -notmatch '(?im)^\s*Disallow\s*:') 'robots.txt contains a restrictive Disallow directive.'

    $productionHash = Get-Sha256 -Bytes ([byte[]]$resourceBodies['run.ps1'])
    $canonicalHash = (Get-FileHash -LiteralPath $CanonicalBootstrapPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ([string]::Equals($productionHash, $canonicalHash, [System.StringComparison]::Ordinal)) "Production bootstrap SHA-256 mismatch. Production: $productionHash; canonical: $canonicalHash"
}
finally {
    $directClient.Dispose()
    $redirectClient.Dispose()
}

$tcpClient = [System.Net.Sockets.TcpClient]::new()
try {
    $tcpClient.Connect($baseUri.Host, 443)
    $tlsStream = [System.Net.Security.SslStream]::new($tcpClient.GetStream(), $false)
    try {
        $tlsStream.AuthenticateAsClient($baseUri.Host)
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($tlsStream.RemoteCertificate)
        try {
            $now = [DateTime]::UtcNow
            $notBefore = $certificate.NotBefore.ToUniversalTime()
            $notAfter = $certificate.NotAfter.ToUniversalTime()
            Assert-True ($now -ge $notBefore) "TLS certificate is not valid before $($notBefore.ToString('u'))."
            Assert-True ($now -lt $notAfter) "TLS certificate expired at $($notAfter.ToString('u'))."
            Assert-True (($notAfter - $now).TotalDays -ge 14) "TLS certificate expires in less than 14 days: $($notAfter.ToString('u'))."
        }
        finally {
            $certificate.Dispose()
        }
    }
    finally {
        $tlsStream.Dispose()
    }
}
finally {
    $tcpClient.Dispose()
}

Write-Host "Production smoke test passed for $($crawlerUserAgents.Count) representative User-Agents and $($htmlUrls.Count) sitemap pages. Bootstrap SHA-256: $productionHash"
Write-Host "TLS certificate expires: $($notAfter.ToString('u'))"
