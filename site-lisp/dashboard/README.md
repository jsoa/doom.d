# Dashboard

[![dashboard tests](https://github.com/jsoa/doom.d/actions/workflows/dashboard-tests.yml/badge.svg)](https://github.com/jsoa/doom.d/actions/workflows/dashboard-tests.yml)

A per-project command-center buffer for Doom Emacs. Opens in place of (or alongside) Doom's own switch-project flow and gives you a single screen with project info, Git status, LOC breakdown, diagnostics, TODOs, and quick actions -- without leaving Emacs or waiting on the project to "load."

## What It Shows

- **Project info** -- type (Python/Node/Angular/generic), file count, on-disk size, current branch, ahead/behind counts, uncommitted-change count, last commit, and (for Python projects) the active virtualenv.
- **Actions** -- numbered quick actions (Magit status, find file, project search, open README) bound to `1`-`9`.
- **Recently modified files** -- the last few files touched across recent commits, with commit message and age.
- **Diagnostics** -- Pyright (Python) or `tsc --noEmit` (Node/Angular) errors/warnings, with a clickable preview and a full grouped-by-file panel on demand.
- **Lines of code** -- a bar-chart breakdown by file extension, with each bar clickable to search that extension via `consult-ripgrep`.
- **Unstaged changes / recent commits** -- a compact Git summary.
- **TODOs** -- `TODO:`/`FIXME:`/`HACK:`/`NOTE:` markers across the project, grouped by kind.

Every file/commit/diagnostic reference is a clickable button that jumps straight to the right location.

## Performance

Anything that has to scan the whole project tree -- diagnostics (Pyright/`tsc`), the LOC breakdown, the TODO scan, and project disk size (`du -sh .`) -- runs asynchronously via `make-process`, so opening the dashboard never blocks Emacs waiting on a slow scan. Each section renders a "Scanning..." placeholder immediately and fills in the real result once its process exits, guarded by a per-render token so a stale scan from a previous render can't write into a buffer that's since moved on to a different project.

The handful of cheap Git calls (branch, ahead/behind, status, last commit) still run synchronously, since they're normally fast enough not to be worth the complexity of an async round-trip.

## Package Layout

```text
~/.doom.d/
  modules/
    +dashboard.el       # thin loader: load-path + (require 'dashboard)

  site-lisp/
    dashboard/
      dashboard.el       # the package itself
      README.md
      test/
        run-tests.el
        dashboard-test.el
        stubs/
          doom-macros.el # stand-ins for Doom's `map!'/`cmd!' outside Doom
```

`modules/+dashboard.el` adds `site-lisp/dashboard` to `load-path` and `require`s the package, mirroring how `+expose.el` loads the `expose` package. `config.el` loads it with `(load! "modules/+dashboard")`.

## Doom Setup

Wired in two places:

- `core/+bindings.el`: `SPC p t` runs `jsoa/project-dashboard`, which opens the dashboard for the current `projectile` project root.
- `modules/+projectile.el`: `+workspaces-switch-project-function` is set to `jsoa/project-command-center`, so switching projects (Doom's normal project-switch flow) opens the dashboard instead of just a file finder.

## Testing

```sh
cd site-lisp/dashboard
emacs -Q --batch -l test/run-tests.el
```

Pure logic (formatting, parsing, face selection) is tested directly. Git-backed functions run against real, disposable temp git repos rather than mocking Git. The async `du -sh .` path (see Performance above) has a regression test asserting the section returns immediately and that the async result correctly patches in later without disturbing content rendered after it. Rendering/UI (buttons, layout, colors) is not covered by ERT and is verified manually.

CI runs the suite on Emacs 29.4 and `snapshot` via `.github/workflows/dashboard-tests.yml`.
