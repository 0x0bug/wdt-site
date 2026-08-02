# Design QA — WDT Industry production implementation

## Source of truth

- Approved archive: `C:\Users\Alivka\Documents\WDT\Industry-handoff.zip`
- Rendered source: `industry/project/templates/wdt-site/WdtSite.dc.html`, served locally from a temporary extraction outside the repository.
- Production implementation: the static multipage site in this repository, served locally without a build step.
- QA evidence directory: `C:\Users\Alivka\.codex\visualizations\2026\07\21\019f85e8-dcee-7c52-b7c6-bdaa35de4894\wdt-industry-final`.

## Normalization

- Desktop browser viewport: 1366 × 768 CSS px, `devicePixelRatio=1` for both source and implementation.
- Desktop screenshot pixels: 1351 × 760 for each side; the 15 px width difference from the requested viewport is the browser scrollbar allocation.
- Mobile browser viewport: 375 × 812 CSS px, `devicePixelRatio=1` for both source and implementation.
- Mobile screenshot pixels: 360 × 780 for each side, with the same scrollbar/browser-chrome allocation.
- Every side-by-side comparison uses equal source and implementation pixel dimensions. No density resampling was required.

## Comparison evidence

Full-view comparisons:

- `comparison-home-desktop-final.png`
- `comparison-home-mobile-final.png`
- `comparison-mobile-menu-final.png`
- `comparison-tui-initial-final.png`
- `comparison-tui-running-final.png`
- `comparison-tui-complete-final.png`
- `comparison-guides-final.png`
- `comparison-article-final.png`

Focused comparison was required for the TUI because status labels, progress, output paths and controls are too small to judge from the homepage hero. The three dedicated TUI comparisons cover initial, running and complete states. Mobile navigation is likewise isolated in its own comparison.

## Browser and responsive coverage

- Homepage, guides index and article checked at 320 × 568, 375 × 812, 768 × 1024, 1366 × 768 and 1920 × 1080.
- A 683 × 384 viewport was checked as the CSS-pixel equivalent of a 1366 × 768 layout at 200% zoom.
- `documentElement.scrollWidth` equalled `clientWidth` on all three routes at every tested viewport.
- Mobile navigation opened, closed with Escape and restored focus to its toggle.
- TUI covered recommended selection, Options and Output tabs, arrow-key tab navigation, run, disabled controls while running, completion, reset and rerun.
- TUI states observed: `QUEUED`, `RUNNING`, `[OK]`, `[WARN]`, `[ERROR]` and the final sample summary.
- Copy control announced success through its polite live region. The fallback selection path is present and covered by the static test; clipboard failure was not forced in the browser.
- Browser console reported no errors or warnings on the exercised homepage, mobile and content flows.
- Reduced-motion CSS and JavaScript branches were verified statically. The selected browser surface did not expose media-feature emulation.

## Required fidelity surfaces

- Fonts and typography: the display/terminal hierarchy, mono labels and sans-serif prose match the source. Production intentionally uses system font stacks instead of the source's external font CDN.
- Spacing and layout rhythm: hero split, capped content width, section rhythm, terminal panels, guide grid, article column, square borders and compact controls match the source direction at desktop and mobile sizes.
- Colors and visual tokens: dark neutral surfaces, green accent, muted borders and literal green/amber/red status labels match the approved token system. The former cyan/glow/scanline layer is absent.
- Image quality and asset fidelity: the supplied real WDT screenshots remain sharp, linked to their full-size originals and clearly separated from the browser simulation. The green social preview replaces the old cyan visual.
- Copy and content: production preserves the archive's hierarchy and tone while using verified WDT facts, static URLs, honest release status, current module selection and explicit simulation disclosures.
- Icons and controls: the source primarily uses terminal glyphs and text controls; production retains that vocabulary without introducing a mismatched icon family.

## Iteration history

### Pass 1

- P2: article breadcrumb and shell spacing doubled the top offset. Fixed by separating breadcrumb and article spacing.
- P2: 320 px layouts overflowed because grid minimums exceeded the content box. Fixed with bounded `minmax()` values and a stacked comparison matrix below 640 px.
- P2: guide index did not match the approved route. Rebuilt it while retaining all static URLs and factual metadata.
- P2: social preview retained the legacy cyan visual language. Recolored the source and regenerated the PNG.

### Pass 2

- No actionable P0, P1 or P2 visual findings remained.
- P3 accepted difference: system font fallbacks replace the prototype's external font CDN.
- Intentional content differences: production routes, version status, module names, default selection, commands, privacy wording and report behavior follow the current repositories rather than inaccurate prototype values.

### Pass 3

- P2 content accuracy: the simulation said `current directory`, but the interactive TUI defaults to `.\WindowsDiagnosticsReports`. Corrected the visible option, generated demo paths, FAQ and FAQ structured data.
- P2 SEO contract: the support-report guide exposed only `HowTo` structured data. Added a matching `TechArticle` entity and a regression check covering every article.
- Post-fix comparisons at normalized desktop and mobile sizes found no remaining actionable P0, P1 or P2 visual differences.

## Intentional production differences

- Static files and real URLs replace the prototype's hash router and component runtime.
- System mono/sans stacks replace external JetBrains Mono and IBM Plex Sans downloads.
- The live production clone workflow remains the primary CTA because no beta GitHub Release ZIP is published.
- Recommended diagnostics are System, Security, Performance, Network, Time, Disk and Updates, matching current manifests rather than the archive's sample selection.
- Browser output and values are explicitly sample/demo data; real WDT screenshots are retained as separate evidence.

## Final result

final result: passed
