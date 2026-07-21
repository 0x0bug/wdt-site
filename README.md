# Windows Diagnostics Toolkit website

Static website for [Windows Diagnostics Toolkit](https://github.com/0x0bug/windows-diagnostics-toolkit).

The production domain is `https://wdt.digital/`. During repository migration, GitHub Pages is staged on the repository's standard project-site URL before any custom-domain switch.

## Bootstrap ownership

The canonical bootstrap is `scripts/bootstrap/run.ps1` in `0x0bug/windows-diagnostics-toolkit`. This repository publishes a copy at `/run.ps1`; CI compares it with the canonical file from the current WDT `main` branch without executing either script.
