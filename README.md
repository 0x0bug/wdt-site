# Windows Diagnostics Toolkit website

This repository contains the standalone static website for [Windows Diagnostics Toolkit (WDT)](https://github.com/0x0bug/windows-diagnostics-toolkit).

Production: [https://wdt.digital/](https://wdt.digital/)

## Bootstrap ownership

The canonical bootstrap is [`scripts/bootstrap/run.ps1`](https://github.com/0x0bug/windows-diagnostics-toolkit/blob/main/scripts/bootstrap/run.ps1) in the main WDT repository. This website publishes a copy as `run.ps1`.

Do not edit `run.ps1` manually. Synchronize it from the canonical WDT bootstrap. The Pages deployment gate compares the two files byte for byte and prevents publication when their SHA-256 hashes differ.

## Repository structure

- Public HTML is discovered recursively; service, test, build, fixture, asset, and hidden directories are excluded.
- `assets/` contains the dependency-free CSS, JavaScript, and images.
- `cases/` contains the case index and diagnostic articles.
- `tests/` contains static site, artifact, bootstrap, and production smoke tests.
- `.github/workflows/` contains validation, drift monitoring, production monitoring, and Pages deployment workflows.
- `run.ps1` is the published copy of the canonical WDT bootstrap.

## Local checks

Run the dependency-free static checks with PowerShell:

```powershell
pwsh -NoProfile -File ./scripts/Generate-Sitemap.ps1
pwsh -NoProfile -File ./tests/sitemap.tests.ps1
pwsh -NoProfile -File ./tests/site-seo.tests.ps1
pwsh -NoProfile -File ./tests/site-assets.tests.ps1
```

`sitemap.xml` is committed. Pull-request CI regenerates it and fails when `git diff --exit-code -- sitemap.xml` finds drift. After merge, deployment regenerates it again from the resulting `main` history before packaging, which keeps squash-merge timestamps accurate.

## Adding an indexable page

Add the HTML file outside service, test, build, fixture, asset, hidden, `internal`, and `dev` directories. The page must:

- use one absolute HTTPS canonical on `wdt.digital` that matches its published path;
- avoid restrictive `noindex`, `nofollow`, or `none` robots directives;
- include the existing title, description, H1, Open Graph, Twitter, icon, navigation, and local-reference conventions;
- have an incoming internal link from another indexable page.

Root `index.html` maps to `https://wdt.digital/`; a directory `index.html` maps to a trailing-slash URL; other HTML filenames remain in the canonical URL. `404.html` and pages with `noindex` are never included in the sitemap.

Every sitemap `lastmod` is the W3C timestamp from the latest Git author commit for its HTML file. New pages therefore need Git history before sitemap generation. After committing a page change, regenerate `sitemap.xml` and include the updated file in the same PR (amend the commit or add a follow-up commit). Running the generator twice for the same repository state must produce identical bytes.

To preview the site locally:

```console
python -m http.server 8000
```

Then open `http://localhost:8000/`.

## Line endings

PowerShell files are stored and checked out with LF line endings (`.gitattributes`: `*.ps1 text eol=lf`). This keeps the byte-for-byte bootstrap SHA-256 comparison identical on Windows checkouts with `core.autocrlf=true`.

## License

The website source is available under the [MIT License](LICENSE).
