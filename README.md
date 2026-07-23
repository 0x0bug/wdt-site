# Windows Diagnostics Toolkit website

This repository contains the standalone static website for [Windows Diagnostics Toolkit (WDT)](https://github.com/0x0bug/windows-diagnostics-toolkit).

Production: [https://wdt.digital/](https://wdt.digital/)

## Bootstrap ownership

The canonical bootstrap is [`scripts/bootstrap/run.ps1`](https://github.com/0x0bug/windows-diagnostics-toolkit/blob/main/scripts/bootstrap/run.ps1) in the main WDT repository. This website publishes a copy as `run.ps1`.

Do not edit `run.ps1` manually. Synchronize it from the canonical WDT bootstrap. The Pages deployment gate compares the two files byte for byte and prevents publication when their SHA-256 hashes differ.

## Repository structure

- Root HTML files contain the homepage and fallback page.
- `assets/` contains the dependency-free CSS, JavaScript, and images.
- `cases/` contains the case index and diagnostic articles.
- `tests/` contains static site, artifact, bootstrap, and production smoke tests.
- `.github/workflows/` contains validation, drift monitoring, production monitoring, and Pages deployment workflows.
- `run.ps1` is the published copy of the canonical WDT bootstrap.

## Local checks

Run the dependency-free static checks with PowerShell:

```powershell
pwsh -NoProfile -File ./tests/site-seo.tests.ps1
pwsh -NoProfile -File ./tests/site-assets.tests.ps1
```

To preview the site locally:

```console
python -m http.server 8000
```

Then open `http://localhost:8000/`.

## License

The website source is available under the [MIT License](LICENSE).
