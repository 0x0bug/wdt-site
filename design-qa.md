# Design QA — WDT Industry implementation

## Source of truth

- Approved archive: `C:\Users\Alivka\Documents\WDT\Industry-handoff.zip`
- Rendered source: `WdtSite.dc.html` from the archive, served locally before implementation.
- Primary reference screenshot: `C:\Users\Alivka\.codex\visualizations\2026\07\31\019fb7cc-636a-7491-b15b-eed7c6a8ebe5\wdt-design-qa\reference-home-desktop.png`
- Primary implementation screenshot: `C:\Users\Alivka\.codex\visualizations\2026\07\31\019fb7cc-636a-7491-b15b-eed7c6a8ebe5\wdt-design-qa\implementation-home-desktop.png`
- Side-by-side comparison: `C:\Users\Alivka\.codex\visualizations\2026\07\31\019fb7cc-636a-7491-b15b-eed7c6a8ebe5\wdt-design-qa\comparison-home-desktop.png`

## Coverage

### Viewports and dimensions

- 320 × 568: checked; document `clientWidth` and `scrollWidth` both 305 px after scrollbar allocation.
- 375 × 812: checked; no horizontal overflow; mobile navigation and compact TUI tabs exercised.
- 768 × 1024: checked; no horizontal overflow.
- 1366 × 768: checked against the rendered source; desktop navigation, hero, screenshots, guides, articles, and TUI exercised.
- 1920 × 1080: checked; no horizontal overflow or stretched content.
- 683 × 384: checked as the CSS-pixel equivalent of a 1366 × 768 viewport at 200% zoom; no horizontal overflow.

### States and interactions

- Homepage: desktop and mobile layouts.
- Mobile navigation: open, Escape close, focus returned to the toggle.
- TUI: initial, running, complete, reset, rerun, mobile Options tab, automatic switch to Output, and arrow-key tab navigation.
- TUI results: `QUEUED`, `RUNNING`, `[OK]`, `[WARN]`, and `[ERROR]` are represented by the simulation.
- Copy controls: homepage and article commands announce success through polite live regions.
- Guides: index and article layouts at desktop and mobile sizes.
- Reduced motion: CSS and JavaScript branches verified statically; the selected browser surface did not expose media-feature emulation.

## Evidence

- Home desktop comparison: `C:\Users\Alivka\.codex\visualizations\2026\07\31\019fb7cc-636a-7491-b15b-eed7c6a8ebe5\wdt-design-qa\comparison-home-desktop.png`
- Home mobile comparison: `C:\Users\Alivka\.codex\visualizations\2026\07\31\019fb7cc-636a-7491-b15b-eed7c6a8ebe5\wdt-design-qa\comparison-home-mobile.png`
- Mobile menu comparison: `C:\Users\Alivka\.codex\visualizations\2026\07\31\019fb7cc-636a-7491-b15b-eed7c6a8ebe5\wdt-design-qa\comparison-mobile-menu.png`
- TUI initial/running/complete: `comparison-tui-initial.png`, `comparison-tui-running.png`, and `comparison-tui-complete.png` in the same evidence directory.
- Guides and article comparisons: `comparison-guides.png` and `comparison-article.png` in the same evidence directory.
- Narrow and wide implementation evidence: `implementation-home-320.png` and `implementation-home-1920.png` in the same evidence directory.

## Iteration history

### Pass 1

- P2: the article breadcrumb and article shell both applied full top padding, shifting the content down from the reference. Fixed by separating breadcrumb and article spacing.
- P2: the 320 px layout overflowed because grid minimums were wider than the available content box. Fixed with bounded `minmax()` values and a stacked comparison matrix below 640 px.
- P2: the legacy guide index did not match the approved guide route. Rebuilt it from the rendered source while retaining static URLs and factual metadata.
- P2: the social preview retained the old cyan/grid visual language. Recolored it to the approved green system and regenerated the PNG.

### Pass 2

- No actionable P0, P1, or P2 findings remained.
- P3 accepted difference: system font fallbacks replace the prototype's external font CDN to keep production pages self-contained.
- Intentional content differences: production copy, routes, version status, module names, commands, privacy wording, and report behavior follow the current repositories rather than inaccurate prototype text.

## Final result

final result: passed
