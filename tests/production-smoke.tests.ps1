[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CanonicalBootstrapPath,

    [ValidateNotNullOrEmpty()]
    [string]$BaseUrl = 'https://wdt.digital/'
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-SiteHttpClient {
    param([bool]$AllowAutoRedirect)

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $AllowAutoRedirect
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('wdt-production-smoke/1.0')
    return $client
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

$directClient = New-SiteHttpClient -AllowAutoRedirect $false
$redirectClient = New-SiteHttpClient -AllowAutoRedirect $true
try {
    $apexResponse = Get-SiteResponse -Client $directClient -Url $BaseUrl
    try {
        Assert-True ([int]$apexResponse.StatusCode -eq 200) "Apex returned HTTP $([int]$apexResponse.StatusCode), expected 200."
    }
    finally {
        $apexResponse.Dispose()
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
    foreach ($relativePath in @('run.ps1', 'robots.txt', 'sitemap.xml', 'assets/style.css', 'assets/site.js')) {
        $resourceUrl = [uri]::new($baseUri, $relativePath).AbsoluteUri
        $response = Get-SiteResponse -Client $directClient -Url $resourceUrl
        try {
            Assert-True ([int]$response.StatusCode -eq 200) "$resourceUrl returned HTTP $([int]$response.StatusCode), expected 200."
            $resourceBodies[$relativePath] = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        }
        finally {
            $response.Dispose()
        }
    }

    $sitemapText = [System.Text.Encoding]::UTF8.GetString([byte[]]$resourceBodies['sitemap.xml'])
    [xml]$sitemap = $sitemapText
    $sitemapUrls = @($sitemap.urlset.url | ForEach-Object { [string]$_.loc })
    Assert-True ($sitemapUrls.Count -gt 0) 'Production sitemap contains no URLs.'

    $htmlUrls = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $null = $htmlUrls.Add($BaseUrl)
    $null = $htmlUrls.Add([uri]::new($baseUri, 'cases/').AbsoluteUri)
    foreach ($url in $sitemapUrls) {
        $uri = [uri]$url
        Assert-True ($uri.IsAbsoluteUri) "Sitemap URL is not absolute: $url"
        Assert-True ($uri.Scheme -ceq 'https') "Sitemap URL does not use HTTPS: $url"
        Assert-True ($uri.Host -ceq 'wdt.digital') "Sitemap URL uses an unexpected host: $url"
        Assert-True ($url -notmatch '0x0bug\.github\.io') "Sitemap contains the old Pages host: $url"
        Assert-True ($uri.AbsolutePath -notmatch '/windows-diagnostics-toolkit/') "Sitemap contains the legacy project path: $url"
        $null = $htmlUrls.Add($uri.AbsoluteUri)
    }

    foreach ($url in $htmlUrls) {
        $response = Get-SiteResponse -Client $directClient -Url $url
        try {
            Assert-True ([int]$response.StatusCode -eq 200) "$url returned HTTP $([int]$response.StatusCode), expected 200."
        }
        finally {
            $response.Dispose()
        }
    }

    $robotsText = [System.Text.Encoding]::UTF8.GetString([byte[]]$resourceBodies['robots.txt'])
    Assert-True ($robotsText -match '(?im)^User-agent:\s*\*\s*$') 'robots.txt has no wildcard user-agent policy.'
    Assert-True ($robotsText -match '(?im)^Allow:\s*/\s*$') 'robots.txt does not allow indexing.'
    Assert-True ($robotsText -notmatch '(?im)^Disallow:\s*/\s*$') 'robots.txt blocks indexing.'
    Assert-True ($robotsText -match '(?im)^Sitemap:\s*https://wdt\.digital/sitemap\.xml\s*$') 'robots.txt does not reference the production sitemap.'

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

Write-Host "Production smoke test passed. Bootstrap SHA-256: $productionHash"
Write-Host "TLS certificate expires: $($notAfter.ToString('u'))"
