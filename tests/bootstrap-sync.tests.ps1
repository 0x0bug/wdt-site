[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PublishedPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CanonicalPath
)

$ErrorActionPreference = 'Stop'

foreach ($path in @($PublishedPath, $CanonicalPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Bootstrap is missing: $path"
    }
}

$publishedHash = (Get-FileHash -LiteralPath $PublishedPath -Algorithm SHA256).Hash.ToLowerInvariant()
$canonicalHash = (Get-FileHash -LiteralPath $CanonicalPath -Algorithm SHA256).Hash.ToLowerInvariant()

if (-not [string]::Equals($publishedHash, $canonicalHash, [System.StringComparison]::Ordinal)) {
    throw "Bootstrap SHA-256 mismatch. Published: $publishedHash; canonical: $canonicalHash"
}

Write-Host "Bootstrap files are byte-for-byte equal: $publishedHash"
