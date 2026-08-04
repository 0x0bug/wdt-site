(() => {
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

  const announce = (target, message) => {
    if (!target) {
      return;
    }

    target.textContent = '';
    window.setTimeout(() => {
      target.textContent = message;
    }, 0);
  };

  const header = document.querySelector('.hdr, .site-header, body > header');
  const navToggle = document.querySelector('.wnav-toggle, .nav-toggle');
  const navLinks = document.querySelector('#site-nav, #primary-links');

  if (header && navToggle && navLinks) {
    const getFocusable = () => [
      navToggle,
      ...navLinks.querySelectorAll('a[href], button:not([disabled])')
    ].filter((element) => !element.hasAttribute('hidden'));

    const closeNavigation = ({ restoreFocus = false } = {}) => {
      header.setAttribute('data-open', '0');
      navLinks.classList.remove('is-open');
      navToggle.setAttribute('aria-expanded', 'false');
      if (restoreFocus) {
        navToggle.focus();
      }
    };

    const openNavigation = () => {
      header.setAttribute('data-open', '1');
      navLinks.classList.add('is-open');
      navToggle.setAttribute('aria-expanded', 'true');
      const firstLink = navLinks.querySelector('a[href]');
      firstLink?.focus();
    };

    navToggle.addEventListener('click', () => {
      if (navToggle.getAttribute('aria-expanded') === 'true') {
        closeNavigation({ restoreFocus: true });
      } else {
        openNavigation();
      }
    });

    navLinks.addEventListener('click', (event) => {
      if (event.target instanceof HTMLAnchorElement) {
        closeNavigation();
      }
    });

    document.addEventListener('pointerdown', (event) => {
      if (
        navToggle.getAttribute('aria-expanded') === 'true' &&
        event.target instanceof Node &&
        !header.contains(event.target)
      ) {
        closeNavigation();
      }
    });

    document.addEventListener('keydown', (event) => {
      if (navToggle.getAttribute('aria-expanded') !== 'true') {
        return;
      }

      if (event.key === 'Escape') {
        event.preventDefault();
        closeNavigation({ restoreFocus: true });
        return;
      }

      if (event.key !== 'Tab') {
        return;
      }

      const focusable = getFocusable();
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    });

    window.addEventListener('resize', () => {
      if (window.innerWidth > 860) {
        closeNavigation();
      }
    });
  }

  document.querySelectorAll('[data-copy-target]').forEach((button) => {
    button.addEventListener('click', async () => {
      const targetId = button.getAttribute('data-copy-target');
      const target = targetId ? document.getElementById(targetId) : null;
      const statusId = button.getAttribute('data-copy-status');
      const status = statusId
        ? document.getElementById(statusId)
        : document.getElementById('site-status');
      const copyLabel = button.getAttribute('data-copy-label') || 'PowerShell command';
      const text = target?.textContent?.replace(/^PS>\s?/gm, '').trim();

      if (!text) {
        announce(status, `No ${copyLabel.toLowerCase()} is available to copy.`);
        return;
      }

      try {
        await navigator.clipboard.writeText(text);
        announce(status, `${copyLabel} copied to the clipboard.`);
        const originalLabel = button.textContent;
        button.textContent = 'COPIED';
        button.classList.add('is-copied');
        window.setTimeout(() => {
          button.textContent = originalLabel;
          button.classList.remove('is-copied');
        }, 1800);
      } catch {
        const range = document.createRange();
        range.selectNodeContents(target);
        const selection = window.getSelection();
        selection?.removeAllRanges();
        selection?.addRange(range);
        announce(status, `Clipboard access failed. The ${copyLabel.toLowerCase()} is selected for manual copying.`);
      }
    });
  });

  const terminal = document.querySelector('[data-phase][data-tab]');
  if (terminal) {
    const moduleRows = [...terminal.querySelectorAll('[data-tui-module]')];
    const optionRows = [...terminal.querySelectorAll('[data-tui-option]')];
    const tabsContainer = terminal.querySelector('[data-tui-tabs]');
    const tabs = [...terminal.querySelectorAll('[data-tui-tab]')];
    const panels = [...terminal.querySelectorAll('[data-panel]')];
    const panelByTab = new Map(tabs.map((tab) => [
      tab,
      document.getElementById(tab.getAttribute('aria-controls'))
    ]));
    const countLabels = [...terminal.querySelectorAll('[data-tui-count]')];
    const phaseLabel = terminal.querySelector('[data-tui-phase]');
    const progressLabel = terminal.querySelector('[data-tui-progress]');
    const railSegments = [...terminal.querySelectorAll('.rail i')];
    const log = terminal.querySelector('[data-tui-log]');
    const live = terminal.querySelector('[data-tui-live]');
    const runButton = terminal.querySelector('[data-tui-action="run"]');
    const allButton = terminal.querySelector('[data-tui-action="all"]');
    const recommendedButton = terminal.querySelector('[data-tui-action="recommended"]');
    const resetButton = terminal.querySelector('[data-tui-action="reset"]');
    const timers = [];
    const compactTui = window.matchMedia('(max-width: 860px)');
    let phase = 'idle';

    const statusByModule = {
      Security: ['warn', '[WARN]', 'Firewall profile deserves review'],
      Disk: ['warn', '[WARN]', 'System volume below sample threshold'],
      Updates: ['warn', '[WARN]', 'Sample reboot indicator reported'],
      Crashes: ['err', '[ERROR]', 'Repeated recent BugChecks reported']
    };

    const clearTimers = () => {
      while (timers.length) {
        window.clearTimeout(timers.pop());
      }
    };

    const selectedRows = () => moduleRows.filter(
      (row) => row.getAttribute('aria-pressed') === 'true'
    );

    const updateCount = () => {
      const label = `${selectedRows().length} of ${moduleRows.length} selected`;
      countLabels.forEach((element) => {
        element.textContent = label;
      });
      if (runButton) {
        runButton.disabled = selectedRows().length === 0;
        runButton.setAttribute('aria-disabled', String(phase === 'running' || selectedRows().length === 0));
      }
    };

    const setSelected = (row, selected) => {
      row.setAttribute('aria-pressed', String(selected));
      const mark = row.querySelector('.mark');
      if (mark) {
        mark.textContent = selected ? '[x]' : '[ ]';
      }
    };

    const setOption = (row, selected) => {
      row.setAttribute('aria-pressed', String(selected));
      const mark = row.querySelector('.mark');
      if (mark) {
        mark.textContent = selected ? '[x]' : '[ ]';
      }
    };

    const isCompactLayout = () => terminal.dataset.layout === 'compact';

    const setTab = (name, focus = false) => {
      terminal.setAttribute('data-tab', name);
      tabs.forEach((tab) => {
        const active = tab.dataset.tuiTab === name;
        if (isCompactLayout()) {
          tab.setAttribute('aria-selected', String(active));
          tab.tabIndex = active ? 0 : -1;
        }
        if (active && focus) {
          tab.focus();
        }
      });
      panels.forEach((panel) => {
        panel.hidden = isCompactLayout() && panel.dataset.panel !== name;
      });
    };

    const focusPanel = (panel) => {
      if (!panel) {
        return;
      }
      const hadTabIndex = panel.hasAttribute('tabindex');
      if (!hadTabIndex) {
        panel.tabIndex = -1;
        panel.addEventListener('blur', () => panel.removeAttribute('tabindex'), { once: true });
      }
      panel.focus();
    };

    const syncTabSemantics = () => {
      const wasCompact = isCompactLayout();
      const compact = compactTui.matches;
      const activeElement = document.activeElement;
      const activeTab = tabs.find((tab) => tab.dataset.tuiTab === terminal.dataset.tab) || tabs[0];
      const activePanel = panelByTab.get(activeTab);
      const focusInTabs = Boolean(activeElement && tabsContainer?.contains(activeElement));
      const focusOnTransferredPanel = Boolean(!wasCompact && activeElement === activePanel);

      if (wasCompact && !compact && focusInTabs) {
        focusPanel(activePanel);
      }

      terminal.dataset.layout = compact ? 'compact' : 'wide';
      terminal.dataset.tabsReady = 'true';
      if (compact) {
        tabsContainer?.setAttribute('role', 'tablist');
        tabsContainer?.setAttribute('aria-label', 'Dashboard panels');
      } else {
        tabsContainer?.removeAttribute('role');
        tabsContainer?.removeAttribute('aria-label');
      }
      tabs.forEach((tab) => {
        if (compact) {
          tab.setAttribute('role', 'tab');
        } else {
          tab.removeAttribute('role');
          tab.removeAttribute('aria-selected');
          tab.removeAttribute('tabindex');
        }
      });
      panels.forEach((panel) => {
        if (compact) {
          panel.setAttribute('role', 'tabpanel');
        } else {
          panel.removeAttribute('role');
          panel.hidden = false;
        }
      });
      setTab(terminal.dataset.tab || 'checks');
      if (!wasCompact && compact && focusOnTransferredPanel) {
        activeTab?.focus();
      }
    };

    const setModuleTabStop = (activeRow, focus = false) => {
      moduleRows.forEach((row) => {
        row.tabIndex = row === activeRow ? 0 : -1;
      });
      if (focus) {
        activeRow.focus();
      }
    };

    const makeLogRow = (kind, tag, text) => {
      const row = document.createElement('div');
      row.className = 'log-row';
      row.dataset.k = kind;
      const badge = document.createElement('span');
      badge.className = 'wtag';
      badge.dataset.k = kind;
      badge.textContent = tag;
      const message = document.createElement('span');
      message.className = 'm';
      message.textContent = text;
      row.append(badge, message);
      return row;
    };

    const setProgress = (done, total, label) => {
      const safeTotal = Math.max(total, 1);
      const filled = Math.round((done / safeTotal) * 12);
      if (progressLabel) {
        progressLabel.textContent =
          `[${'█'.repeat(filled)}${'░'.repeat(12 - filled)}] ${label}`;
      }
      railSegments.forEach((segment, index) => {
        segment.dataset.on = String(index < filled ? 1 : 0);
      });
    };

    const setControlsDisabled = (running) => {
      moduleRows.forEach((row) => {
        row.disabled = running;
      });
      optionRows.forEach((row) => {
        row.disabled = running;
      });
      if (allButton) {
        allButton.disabled = running;
      }
      if (recommendedButton) {
        recommendedButton.disabled = running;
      }
      if (runButton) {
        runButton.setAttribute('aria-disabled', String(running));
      }
    };

    const reset = ({ announceReset = true } = {}) => {
      clearTimers();
      phase = 'idle';
      terminal.dataset.phase = phase;
      moduleRows.forEach((row) => {
        setSelected(row, row.dataset.recommended === 'true');
        row.dataset.state = '';
        const tag = row.querySelector('.sel-tag');
        if (tag) {
          tag.textContent = row.dataset.recommended === 'true' ? 'RECOMMENDED' : 'OPTIONAL';
        }
      });
      optionRows.forEach((row) => setOption(row, true));
      setControlsDisabled(false);
      if (phaseLabel) {
        phaseLabel.textContent = 'System ready';
      }
      if (runButton) {
        runButton.textContent = 'ENTER · RUN';
      }
      setProgress(0, 0, 'idle');
      if (log) {
        log.replaceChildren(makeLogRow('dim', '>', 'Ready.'));
      }
      setTab('checks');
      updateCount();
      if (announceReset) {
        announce(live, 'Simulation reset. Seven recommended diagnostics selected.');
      }
    };

    const run = () => {
      if (phase === 'running' || selectedRows().length === 0) {
        return;
      }

      clearTimers();
      const activeRows = selectedRows();
      phase = 'running';
      terminal.dataset.phase = phase;
      setControlsDisabled(true);
      moduleRows.forEach((row) => {
        row.dataset.state = row.getAttribute('aria-pressed') === 'true' ? 'queued' : '';
        const tag = row.querySelector('.sel-tag');
        if (tag) {
          tag.textContent = row.getAttribute('aria-pressed') === 'true'
            ? 'QUEUED'
            : row.dataset.recommended === 'true' ? 'RECOMMENDED' : 'OPTIONAL';
        }
      });
      if (phaseLabel) {
        phaseLabel.textContent = 'Running';
      }
      if (runButton) {
        runButton.textContent = 'RUNNING…';
      }
      if (log) {
        log.replaceChildren(
          makeLogRow('dim', '>', 'Collecting sample/demo data locally in this browser simulation.')
        );
      }
      setProgress(0, activeRows.length, `0 of ${activeRows.length} checks`);
      setTab('output');
      announce(live, `Simulation started with ${activeRows.length} diagnostics. Nothing is running on your PC.`);

      const pace = reducedMotion.matches ? 20 : 320;
      activeRows.forEach((row, index) => {
        const startTimer = window.setTimeout(() => {
          row.dataset.state = 'active';
          const tag = row.querySelector('.sel-tag');
          if (tag) {
            tag.textContent = 'RUNNING';
          }
          if (phaseLabel) {
            phaseLabel.textContent = `Running · ${row.querySelector('.sel-name')?.textContent || row.dataset.tuiModule}`;
          }
        }, pace * index);
        timers.push(startTimer);

        const finishTimer = window.setTimeout(() => {
          const result = statusByModule[row.dataset.tuiModule] || [
            'ok',
            '[OK]',
            'Sample check completed normally'
          ];
          row.dataset.state = result[0];
          const tag = row.querySelector('.sel-tag');
          if (tag) {
            tag.textContent = result[1];
          }
          log?.append(makeLogRow(result[0], result[1], `${row.querySelector('.sel-name')?.textContent}: ${result[2]}`));
          if (log) {
            log.scrollTop = log.scrollHeight;
          }
          const done = index + 1;
          setProgress(done, activeRows.length, `${done} of ${activeRows.length} checks`);
        }, pace * index + Math.max(15, pace - 45));
        timers.push(finishTimer);
      });

      const completeTimer = window.setTimeout(() => {
        phase = 'done';
        terminal.dataset.phase = phase;
        const completedResults = activeRows.map((row) => statusByModule[row.dataset.tuiModule]?.[0] || 'ok');
        const warningCount = completedResults.filter((result) => result === 'warn').length;
        const errorCount = completedResults.filter((result) => result === 'err').length;
        const warningLabel = `${warningCount} warning${warningCount === 1 ? '' : 's'}`;
        const errorLabel = `${errorCount} error${errorCount === 1 ? '' : 's'}`;
        setControlsDisabled(false);
        if (phaseLabel) {
          phaseLabel.textContent = 'Complete · sample data';
        }
        if (runButton) {
          runButton.textContent = 'RUN AGAIN';
        }
        log?.append(
          makeLogRow('dim', '--', `elapsed 2.4s · ${warningLabel} · ${errorLabel}`),
          makeLogRow('dim', '>', '.\\WindowsDiagnosticsReports\\WindowsDiagnosticsReport-DEMO.txt'),
          ...(optionRows.find((row) => row.dataset.tuiOption === 'markdown')?.getAttribute('aria-pressed') === 'true'
            ? [makeLogRow('dim', '>', '.\\WindowsDiagnosticsReports\\WindowsDiagnosticsReport-DEMO.md')]
            : [])
        );
        if (log) {
          log.scrollTop = log.scrollHeight;
        }
        setProgress(activeRows.length, activeRows.length, `${activeRows.length} of ${activeRows.length} checks`);
        updateCount();
        announce(live, `Simulation complete. Sample result: ${warningLabel} and ${errorLabel}. No diagnostics ran on your PC.`);
      }, pace * activeRows.length + 40);
      timers.push(completeTimer);
    };

    moduleRows.forEach((row) => {
      row.addEventListener('click', () => {
        setModuleTabStop(row);
        if (phase !== 'running') {
          setSelected(row, row.getAttribute('aria-pressed') !== 'true');
          updateCount();
        }
      });
      row.addEventListener('focus', () => setModuleTabStop(row));
      row.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          row.click();
          return;
        }
        if (!['ArrowUp', 'ArrowDown', 'Home', 'End'].includes(event.key)) {
          return;
        }
        event.preventDefault();
        const index = moduleRows.indexOf(row);
        const nextIndex = event.key === 'Home'
          ? 0
          : event.key === 'End'
            ? moduleRows.length - 1
            : (index + (event.key === 'ArrowDown' ? 1 : -1) + moduleRows.length) % moduleRows.length;
        setModuleTabStop(moduleRows[nextIndex], true);
      });
    });

    optionRows.forEach((row) => {
      row.addEventListener('click', () => {
        if (phase !== 'running') {
          setOption(row, row.getAttribute('aria-pressed') !== 'true');
        }
      });
    });

    tabs.forEach((tab, index) => {
      tab.addEventListener('click', () => setTab(tab.dataset.tuiTab));
      tab.addEventListener('keydown', (event) => {
        if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) {
          return;
        }
        event.preventDefault();
        const nextIndex = event.key === 'Home'
          ? 0
          : event.key === 'End'
            ? tabs.length - 1
            : (index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
        setTab(tabs[nextIndex].dataset.tuiTab, true);
      });
    });
    compactTui.addEventListener('change', syncTabSemantics);

    allButton?.addEventListener('click', () => {
      moduleRows.forEach((row) => setSelected(row, true));
      updateCount();
    });
    recommendedButton?.addEventListener('click', () => {
      moduleRows.forEach((row) => setSelected(row, row.dataset.recommended === 'true'));
      updateCount();
    });
    resetButton?.addEventListener('click', () => reset());
    runButton?.addEventListener('click', run);
    runButton?.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        run();
      }
    });

    terminal.addEventListener('keydown', (event) => {
      if (event.altKey || event.ctrlKey || event.metaKey) {
        return;
      }
      const target = event.target;
      const targetIsEditable = target instanceof HTMLInputElement ||
        target instanceof HTMLTextAreaElement ||
        target instanceof HTMLSelectElement ||
        (target instanceof HTMLElement && target.isContentEditable);
      if (targetIsEditable) {
        return;
      }
      if (event.key.toLowerCase() === 'a' && phase !== 'running') {
        event.preventDefault();
        moduleRows.forEach((row) => setSelected(row, true));
        updateCount();
      } else if (event.key.toLowerCase() === 'r' && phase !== 'running') {
        event.preventDefault();
        moduleRows.forEach((row) => setSelected(row, row.dataset.recommended === 'true'));
        updateCount();
      } else if (event.key === 'Escape') {
        event.preventDefault();
        reset();
      }
    });

    syncTabSemantics();
    reset({ announceReset: false });
  }

  if ('IntersectionObserver' in window) {
    try {
      const revealTargets = [...document.querySelectorAll('[data-reveal="scroll"]')];
      const revealObserver = new IntersectionObserver((entries, observer) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.dataset.reveal = 'in';
            observer.unobserve(entry.target);
          }
        });
      }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
      revealTargets.forEach((element) => revealObserver.observe(element));
      document.documentElement.classList.add('wdt-motion');

      const heroSequence = [...document.querySelectorAll('#wdt-hero [data-seq="wait"]')];
      const sequenceStep = reducedMotion.matches ? 0 : 55;
      heroSequence.forEach((element, index) => {
        window.setTimeout(() => {
          element.dataset.seq = 'in';
        }, index * sequenceStep);
      });
    } catch {
      document.documentElement.classList.remove('wdt-motion');
    }
  }
})();
