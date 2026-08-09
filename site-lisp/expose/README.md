# Expose

[![expose tests](https://github.com/jsoa/doom.d/actions/workflows/expose-tests.yml/badge.svg)](https://github.com/jsoa/doom.d/actions/workflows/expose-tests.yml)

Expose is a Doom Emacs helper package for showing code context, running focused AI-assisted code actions, and maintaining lightweight AI review state directly inside source buffers.

It combines hover documentation, diagnostics, semantic code context, Git diff context, provider-backed AI actions, review sessions, region reviews, background watch comments, inline continuation, popup history, and archive viewers behind a single leader-key interface.

## What Expose Does

Expose gives you a lightweight code-context command center at point:

- Shows LSP hover information when available.
- Falls back to Eldoc when LSP hover is unavailable.
- Shows Flycheck diagnostics at point.
- Displays focused action results in a small `posframe` popup.
- Runs provider-backed code actions asynchronously.
- Supports Clipboard, Codex, Copilot, Claude Code, and other provider implementations.
- Captures popup history for final action responses.
- Supports copy/open/log/debug commands.
- Supports quick hover scrolling with `C-j` / `C-k` while the popup is visible.
- Includes Git status and diff context for change-oriented actions.
- Supports persistent full-branch review sessions.
- Supports persistent selected-region reviews with source hovers.
- Supports read-only archive viewers for completed/canceled reviews.
- Supports inline continuation at point.
- Supports background Watch mode for changed hunks in selected buffers.

The core popup/action flow is:

```text
source buffer at point
  -> build structured context
  -> render XML request document
  -> send to provider
  -> render Markdown response
  -> show result in popup/history
```

The review-session flow is:

```text
project / branch / selected region / changed hunk
  -> collect Git + source context
  -> send strict JSON review request
  -> parse review items
  -> persist session state under .git/expose
  -> show source fringe markers
  -> show item details on hover
```

## Package Layout

Typical local layout:

```text
~/.doom.d/
  modules/
    +expose.el

  site-lisp/
    expose/
      expose.el
      expose-popup.el
      expose-history.el
      expose-hover.el
      expose-log.el
      expose-document.el
      expose-request.el
      expose-context.el
      expose-xml.el
      expose-transport.el
      expose-provider.el
      expose-clipboard.el
      expose-codex.el
      expose-copilot.el
      expose-claude.el
      expose-commands.el
      expose-review.el
      expose-review-store.el
      expose-review-context.el
      expose-review-request.el
      expose-review-buffer.el
      expose-review-source.el
      expose-review-region.el
      expose-review-archive.el
      expose-watch.el
      expose-continue.el
```

## Doom Setup

In `~/.doom.d/modules/+expose.el`:

```elisp
;;; modules/+expose.el -*- lexical-binding: t; -*-

(add-to-list
 'load-path
 (expand-file-name "site-lisp/expose" doom-user-dir))

(setq expose-hover-delay 0.25
      expose-popup-min-width 80
      expose-popup-max-width 160
      expose-popup-min-height 1
      expose-popup-max-height 30
      expose-popup-scroll-lines 1
      expose-provider-default 'codex
      expose-context-git-diff-max-length 20000)

(require 'expose)

(expose-mode 1)
```

`expose-mode` enables:

```text
expose-hover-mode
expose-review-source-global-mode
expose-review-region-source-global-mode
expose-watch-global-mode
```

## Configuration

Common settings:

```elisp
(setq expose-key-prefix "c h"
      expose-hover-delay 0.25
      expose-popup-min-width 80
      expose-popup-max-width 160
      expose-popup-min-height 1
      expose-popup-max-height 30
      expose-popup-scroll-lines 1
      expose-provider-default 'codex
      expose-context-git-diff-max-length 20000)
```

Codex settings:

```elisp
(setq expose-provider-codex-command "codex"
      expose-provider-codex-arguments
      '("exec" "--skip-git-repo-check"))
```

Claude Code settings:

```elisp
(setq expose-provider-claude-command "claude"
      expose-provider-claude-arguments
      '("-p" "--permission-mode" "plan"))
```

`-p` is Claude Code's print/non-interactive mode. `--permission-mode plan`
keeps the call read/analysis-only, since Expose already embeds all relevant
context in the request document and does not expect the provider to read or
modify the project itself. Verify these flags against your installed CLI
version with `M-x expose-provider-claude-version` or `claude --help`.

Output formatting instruction for normal popup actions:

```elisp
(setq expose-request-output-instruction
      "Return the response as concise Markdown. Do not return XML, HTML, JSON, or custom tags. Do not mirror the request document structure. Use headings, bullet lists, and fenced code blocks when useful.")
```

Watch mode-line icon:

```elisp
(setq expose-watch-mode-line-icon "nf-fa-eye")
```

`nerd-icons` is optional. If available, Watch uses a Nerd Font eye icon in the mode line.

Watch hover delay:

```elisp
(setq expose-watch-source-hover-delay 0.20)
```

Idle delay, in seconds, before an Expose Watch comment hover appears when point rests on a flagged line.

## Default Keybindings

Expose installs bindings under `SPC c h` by default.

### Top-level Expose keys

| Key         | Command                             | Description                                  |
|-------------|-------------------------------------|----------------------------------------------|
| `SPC c h c` | `expose-continue-at-point`          | Inline continuation at point                 |
| `SPC c h g` | `expose-run-commit-message`         | Insert generated commit message at point     |
| `SPC c h n` | `expose-run-changelog`              | Generate changelog entry from Git changes    |
| `SPC c h j` | `expose-popup-scroll-down`          | Scroll popup down                            |
| `SPC c h k` | `expose-popup-scroll-up`            | Scroll popup up                              |
| `SPC c h q` | `expose-popup-hide`                 | Close popup                                  |
| `SPC c h y` | `expose-popup-copy`                 | Copy popup contents                          |
| `SPC c h H` | `expose-history-open`               | Open popup history                           |
| `SPC c h o` | `expose-popup-open`                 | Open popup in a normal buffer                |
| `SPC c h l` | `expose-log-open`                   | Open Expose log                              |
| `SPC c h L` | `expose-log-clear`                  | Clear Expose log                             |
| `SPC c h ?` | `expose-hover-debug-current-buffer` | Debug current buffer hover state             |
| `SPC c h h` | Thing at Point prefix               | Focused code-context actions                 |
| `SPC c h G` | Diagrams prefix                     | Rendered flow, ER and call graphs            |
| `SPC c h R` | Full Review prefix                  | Persistent branch/session reviews            |
| `SPC c h M` | Region Review prefix                | Persistent selected-region reviews           |
| `SPC c h W` | Watch prefix                        | Background review for watched source buffers |

### Thing at Point

These actions use the active region when one is selected, falling back to the point-based symbol/expression/construct otherwise -- select a range first for a more precise target than whatever the point-based heuristic would have picked.

| Key           | Command                              | Description                          |
|---------------|--------------------------------------|--------------------------------------|
| `SPC c h h r` | `expose-run-review`                  | Review current code                  |
| `SPC c h h d` | `expose-run-diagnostics`             | Explain diagnostics                  |
| `SPC c h h e` | `expose-run-explain`                 | Explain symbol/construct             |
| `SPC c h h f` | `expose-run-fix`                     | Suggest a focused fix                |
| `SPC c h h R` | `expose-run-refactor`                | Suggest behavior-preserving refactor |
| `SPC c h h s` | `expose-run-security`                | Security review                      |
| `SPC c h h p` | `expose-run-performance`             | Performance review                   |
| `SPC c h h t` | `expose-run-tests`                   | Suggest tests                        |
| `SPC c h h x` | `expose-run-edge-cases`              | Identify edge cases                  |
| `SPC c h h F` | `expose-run-flow`                    | Explain execution flow               |
| `SPC c h h u` | `expose-run-usage`                   | Explain usage                        |
| `SPC c h h D` | `expose-run-docstring`               | Suggest docstring/comment            |
| `SPC c h h S` | `expose-run-summary`                 | Summarize code                       |
| `SPC c h h T` | `expose-run-types`                   | Explain important types              |
| `SPC c h h c` | `expose-run-concurrency`             | Review concurrency/race risks        |
| `SPC c h h i` | `expose-run-invariants`              | Identify invariants                  |
| `SPC c h h !` | `expose-run-risks`                   | Identify practical risks             |
| `SPC c h h y` | `expose-run-why`                     | Explain likely design intent         |
| `SPC c h h m` | `expose-run-mental-model`            | Build a mental model                 |
| `SPC c h h ?` | `expose-hover-debug-current-buffer`  | Debug current buffer hover state     |

### Diagrams

| Key           | Command                             | Description                              |
|---------------|-------------------------------------|------------------------------------------|
| `SPC c h G c` | `expose-run-control-flow-diagram`   | Control flow of the code at point        |
| `SPC c h G C` | `expose-run-call-flow-diagram`      | What the code at point calls             |
| `SPC c h G d` | `expose-run-data-flow-diagram`      | How values move through the code         |
| `SPC c h G R` | `expose-run-request-flow-diagram`   | Django request pipeline for a view       |
| `SPC c h G m` | `expose-run-import-graph`           | What this file imports, transitively     |
| `SPC c h G t` | `expose-run-test-graph`             | Which tests reach the code at point      |
| `SPC c h G e` | `expose-run-er-diagram`             | Models and their relationships           |
| `SPC c h G r` | `expose-run-reverse-call-graph`     | What calls the function at point         |

See [Diagrams](#diagrams-1) for what each one draws and how far to trust it.

### Full Review

| Key           | Command                           | Description                      |
|---------------|-----------------------------------|----------------------------------|
| `SPC c h R r` | `expose-review-open-or-start`     | Open or start full branch review |
| `SPC c h R a` | `expose-review-archive-open-full` | Open full review archive viewer  |

### Region Review

| Key           | Command                                    | Description                       |
|---------------|--------------------------------------------|-----------------------------------|
| `SPC c h M m` | `expose-review-region`                     | Review selected region            |
| `SPC c h M v` | `expose-review-region-show-full-at-point`  | View full region review at point  |
| `SPC c h M c` | `expose-review-region-complete-at-point`   | Complete/archive region review    |
| `SPC c h M q` | `expose-review-region-cancel-at-point`     | Cancel/archive region review      |
| `SPC c h M a` | `expose-review-archive-open-region`        | Open region review archive viewer |

### Watch

| Key           | Command                               | Description                             |
|---------------|---------------------------------------|-----------------------------------------|
| `SPC c h W w` | `expose-watch-current-buffer`         | Watch current buffer                    |
| `SPC c h W u` | `expose-watch-unwatch-current-buffer` | Unwatch current buffer                  |
| `SPC c h W r` | `expose-watch-review-current-buffer`  | Review changed hunks now                |
| `SPC c h W l` | `expose-watch-open-list`              | Open Watch list buffer                  |
| `SPC c h W c` | `expose-watch-clear-current-buffer`   | Clear Watch comments for current buffer |
| `SPC c h W C` | `expose-watch-clear-project`          | Clear Watch comments for current project |
| `SPC c h W a` | `expose-watch-toggle-project-auto`    | Toggle auto-arm for current project     |
| `SPC c h W A` | `expose-watch-open-active-list`       | Open active Watch items for current project |
| `SPC c h W h` | `expose-watch-toggle-hidden`          | Toggle inline markers hidden/shown (all buffers) |

## Quick Hover Scroll Keys

While an Expose popup is visible, Expose installs a temporary emulation keymap:

| Key   | Command                    | Description                   |
|-------|----------------------------|-------------------------------|
| `C-j` | `expose-popup-scroll-down` | Scroll the visible popup down |
| `C-k` | `expose-popup-scroll-up`   | Scroll the visible popup up   |

These keys are active only while `expose-popup-visible` is non-nil. When the popup is hidden, normal `C-j` / `C-k` behavior is restored.

## Action Lenses

Expose actions are intentionally small, focused lenses over the current code context.

| Action         | Focus                                                            |
|----------------|------------------------------------------------------------------|
| Review         | Correctness, readability, maintainability, bugs                  |
| Diagnostics    | Current Flycheck/LSP diagnostics                                 |
| Explain        | Selected symbol or construct                                     |
| Fix            | Smallest safe fix                                                |
| Refactor       | Behavior-preserving cleanup                                      |
| Security       | Auth, permissions, injection, secrets, data exposure             |
| Performance    | N+1s, blocking I/O, unnecessary work, rendering, caching         |
| Tests          | Practical test cases and examples                                |
| Edge Cases     | Boundary inputs, empty states, malformed data, external failures |
| Flow           | Step-by-step execution flow                                      |
| Usage          | How to use the selected symbol/construct                         |
| Docstring      | Concise useful docstring/comment                                 |
| Summary        | Brief purpose and dependencies                                   |
| Types          | Declared/inferred types and mismatch risks                       |
| Concurrency    | Race conditions, ordering, retries, locks, transactions          |
| Invariants     | What must remain true before/during/after execution              |
| Risks          | Practical operational and maintenance risks                      |
| Why            | Likely design intent and tradeoffs                               |
| Mental Model   | Conceptual map for reasoning about the code                      |
| Commit Message | Conventional-style commit message from Git diff/status           |
| Changelog      | User/developer-facing changelog entry from Git diff/status       |

## Diagrams

Four graphs, rendered with Graphviz and shown as an SVG image in a full-frame buffer. Graphviz because `dot` needs no extra toolchain; SVG because Emacs renders it natively, so zooming stays sharp.

| Diagram            | Answers                                            | Source     |
|--------------------|----------------------------------------------------|------------|
| Control flow       | Which paths run through this code                  | Provider   |
| Call flow          | What this code calls, and what those call          | Provider   |
| Data flow          | Where values come from, and where they end up      | Provider   |
| Request flow       | A Django request through its pipeline layers       | Provider   |
| Import graph       | What this file imports, and its cycles             | Parsed     |
| Tests              | Which tests reach this code, and how               | LSP / xref |
| Entity relations   | Which models exist and how they relate             | Provider   |
| Reverse call graph | What calls this, transitively                      | LSP / xref |

Nodes are colored by what they represent — entry, condition, error, exit, external dependency, I/O — classified from the shapes each request asks for rather than from colors chosen by the provider, which vary run to run. Relationship edges in the ER diagram are colored by kind (foreign key, many-to-many, one-to-one), and the model you invoked it from is outlined.

### Reading the diagram buffer

| Key     | Action                                        |
|---------|-----------------------------------------------|
| `+` `-` | Zoom in / out                                 |
| `0`     | Fit the whole graph to the window             |
| `1`     | Actual size                                   |
| `H` `L` | Pan left / right                              |
| `s`     | Show the DOT source behind the image          |
| `g`     | Regenerate                                    |
| `w`     | Write to a file (`.svg`, `.png`, `.jpg`, `.pdf`) |
| `q`     | Quit, restoring the previous window layout    |

### How far to trust them

The first three are provider-generated and advisory, like the rest of Expose. A picture reads as more authoritative than a paragraph, so `s` is worth using: it shows the exact DOT the image was built from. The ER diagram is the most reliable of the three — relationships are declared in the source rather than inferred. Call flow is the least, since a model asked what something "calls" will readily describe a dependency it was never shown; callees it cannot see are drawn dashed.

Request flow groups the same territory as call flow into the layers a request passes through -- view, permissions, validation, domain, data, response -- drawn as labelled boxes. Order and layering are the point: a missing layer reads as an absence, so a view with no permission gate, or one reaching straight into the ORM, is visible as a gap rather than something you have to notice isn't there. Gates that can reject the request are drawn as conditions and their failure paths are asked for explicitly, since a gate shown with only its success edge is worse than not drawing it.

Routing is included only when the URL configuration is in the code being looked at, which from a views module it usually isn't. Rather than inventing a plausible route, it starts at the view -- use the reverse call graph to find what actually routes there, which reports the `urls.py` reference as a module-level usage.

Data flow is the other inference-heavy one: it labels each edge with the operation, and states "mutated in place" explicitly, because rebinding a name and mutating the object behind it look nearly identical in source and behave nothing alike. That distinction is the reason to draw it, and also the thing most worth checking against the source.

**The tests graph** answers "is this tested, and by what" -- not a coverage percentage. It is the reverse call graph with its filter inverted: that one excludes tests so production paths stay readable, and this keeps only the half it discards. Callers no test goes through are pruned, so what remains is the routes tests take to reach the code, intermediate functions included. When nothing reaches it, that is stated plainly rather than drawn as an empty graph -- though it means "no test reaches this within `expose-callers-max-depth` levels", not "this is untested by every possible route".

**The import graph has no AI in it either**, for the same reason: imports are trivially parseable, so asking a provider to describe them would trade an exact answer for a plausible one. It follows project-local imports and stops at the boundary — third-party and standard library packages are leaves, shown only with a prefix argument, since hiding them usually makes the project's own shape far easier to read. Python and TypeScript/JavaScript; tests, migrations and `node_modules` are excluded by `expose-imports-exclude-regexps`.

Its main reason to exist is **cycle detection**, drawn in red: an import cycle is invisible in any single file and in Python is a real failure rather than a style problem.

**The reverse call graph has no AI in it.** Finding callers needs whole-project knowledge that no provider has, and a fabricated answer to "is it safe to change this?" is worse than none, so its edges come from LSP call hierarchy — or `xref` when the server can't answer, which the graph says on its title since references are not the same as calls.

It also includes non-call *references*, drawn dashed and labelled: a function that is only registered somewhere (`validators=[is_valid_member]`) has no callers at all and would otherwise read as dead code. Test files are excluded (`expose-callers-exclude-regexps`) because tests call everything and bury the production paths. The walk is bounded by `expose-callers-max-depth` and `expose-callers-max-nodes`; anything trimmed is marked on the graph rather than dropped silently.

Requires the `dot` binary; the commands say so plainly if it is missing.

## Commit Message Insertion

`expose-run-commit-message` uses the normal commit-message request flow, but it does not show a loading popup.

Instead:

```text
SPC c h g
  -> generate commit message from current Git changes
  -> insert returned text at the point where the command was invoked
```

This is useful inside Magit commit buffers or any scratch/edit buffer where you want the commit message placed directly into the buffer.

## Inline Continuation

`expose-continue-at-point` requests a project-aware continuation at point.

```text
SPC c h c
  -> send continuation request
  -> show inline ghost text
  -> accept or dismiss the suggestion
```

Continuation runs from the project root so provider-side files like `.codex` are not accidentally created in nested source directories.

## Full Review Sessions

Full Review is a persistent branch/session review workflow.

```text
SPC c h R r
  -> open existing review session for the current branch
  -> or start a new async review
```

A full review collects branch and Git context, sends a strict JSON review request, parses review items, and displays them in a dashboard buffer.

The dashboard supports:

- Review status and progress.
- Git input/context sections.
- Parsed review items.
- Source navigation for review items.
- Source overlays and right-fringe markers.
- Hovers in source buffers with review comment details.
- Completing/archiving review sessions.

Active and historical full reviews are stored under:

```text
.git/expose/reviews/<branch-slug>/active.eld
.git/expose/reviews/<branch-slug>/history/<timestamp>.eld
```

## Region Reviews

Region Review is a persistent selected-region review workflow.

```text
select region
SPC c h M m
  -> review selected source range
  -> show full review popup when ready
  -> keep source markers active until completed/canceled
```

Region Review behavior:

- Reviews only the selected range.
- Includes surrounding context and symbol/type context.
- Persists the active review session.
- Rejects overlapping active region reviews in the same file.
- Shows a subtle active-region indicator.
- Shows right-fringe markers for active review ranges.
- Shows item hovers only on concrete review item lines.
- Does not auto-popup merely by moving through the active region.
- Can be completed or canceled from the source buffer.

Active and historical region reviews are stored under:

```text
.git/expose/region-reviews/active/<sha>.eld
.git/expose/region-reviews/history/<timestamp>-<sha>.eld
```

## Review Archive Viewers

Expose includes read-only archive viewers for completed/canceled reviews.

```text
SPC c h R a
  -> full review archives

SPC c h M a
  -> region review archives
```

Archive viewer keys:

| Key     | Description                 |
|---------|-----------------------------|
| `TAB`   | Expand/collapse one entry   |
| `S-TAB` | Expand/collapse all entries |
| `q`     | Quit archive buffer         |

Archive viewers are intentionally non-actionable:

- They do not jump to files.
- They do not apply patches.
- They do not mutate stored archive entries.
- They are for reading historical review context only.

Expanded archive entries are colorized with severity, metadata, location, comments, anchors, suggestions, and patches.

Archive buffers set `default-directory` to the displayed project root, so project-aware commands like Magit open against the correct repository.

## Watch Mode

Watch mode is a background reviewer for changed hunks in buffers you explicitly opt into.

```text
SPC c h W w
  -> watch current buffer
```

After that:

```text
edit watched file
save file
  -> Expose gets current git diff hunks for this file
  -> skips hunks already reviewed by hash
  -> reviews only new/changed hunks
  -> stores comments
  -> underlines the flagged code
```

Each Watch comment shows up directly in the source buffer, GitHub-PR-review style:

- The flagged code gets a squiggly underline (doom-one magenta, `expose-watch-item-face`), trimmed to the real code on each line -- indentation, trailing whitespace, and blank lines in a multi-line range are not underlined. Region review and full review use the same style, in blue and teal respectively, so which feature flagged a given line is visible at a glance.
- Resting point on a flagged line (idle for `expose-watch-source-hover-delay`), or `C-<tab>`/a click anywhere on the flagged line, opens the full comment -- severity, category, title, comment, suggestion, and patch -- in Expose's normal shared popup, with all of its usual behavior: auto-hides on unrelated commands, `C-j`/`C-k` scrolling, copy, open-in-buffer.
- Right-fringe markers are optional and off by default (`expose-watch-show-fringe-markers`).

Watch mode is designed to stay out of the way:

- It does not block editing.
- It does not open loading popups.
- It does not highlight entire source lines -- only the actual flagged code.
- Nothing sits permanently inline; the full comment only appears on hover or explicit request, via the shared popup.
- It keeps historical comments in the Watch list.
- It only shows source markers for hunks that still exist in the current working-tree diff.

This means if you remove or rewrite code that produced a Watch comment, the old comment stays available historically in `*EXPOSE Watch*`, but the underline disappears after save.

### Catching Up on Existing Changes

If you enable Watch (explicitly, or via auto-arm) on a file that already has a backlog of uncommitted changes, the first save reviews the *whole* current backlog in one combined request, instead of the normal `expose-watch-max-hunks-per-run'-hunk cap trickling it in across several saves:

```text
watch a file with pre-existing uncommitted changes
save the file (the first save since watching)
  -> one request covering every unreviewed hunk, not just a capped batch
subsequent saves
  -> back to reviewing one capped batch per save, as usual
```

`expose-watch-max-items-per-run' (the findings-per-run cap) is a fixed number baked into every request regardless of hunk count, so bundling a large backlog into one request without adjusting it would silently shrink coverage as the backlog grows. The catch-up request instead scales its findings budget to roughly the same findings-per-hunk density as a normal run (`expose-watch-catch-up-item-cap'), with the normal default as a floor -- a catch-up request never asks for fewer findings than a normal one would, only more as the backlog grows.

If the catch-up request fails, it isn't retried automatically; the next save (or a manual "Review changed hunks now") picks up wherever the live diff still shows unreviewed hunks.

### Watch Mode Line

Watched buffers show a compact mode-line indicator using Nerd Icons when available:

```text
eye icon       watched / idle
eye icon …     currently reviewing changed hunks
eye icon :2    watched with two active comments
eye icon !     last watch run failed
eye icon :2⊘   two active comments, inline markers currently hidden
```

The idle/running/error states use different faces so active processing is visible without adding source-buffer noise.

### Hiding Inline Markers

```text
SPC c h W h
  -> toggle Expose Watch's inline markers hidden/shown, across every watched buffer
```

Useful for decluttering a large change: hide the squiggly underlines while skimming a big diff, then reveal them again once ready to work through the comments.

Hiding only suppresses the in-buffer rendering:

- Watch keeps reviewing changed hunks and storing comments normally in the background.
- The mode-line count keeps updating, so you still know something is there.
- `expose-watch-open-active-list` (`SPC c h W A`) reads stored state directly and is unaffected either way, so it stays a good way to see what Watch has found while markers are hidden.

### Watch List

```text
SPC c h W l
  -> open *EXPOSE Watch*
```

The Watch list shows accumulated comments by project and file.

It includes:

- Watched files.
- Enabled/disabled state.
- Reviewed hunks.
- Stored comments.
- No-comment saves.
- Failed watch runs.

Watch state is stored under:

```text
.git/expose/watch/active.eld
```

## Context Collected

Expose builds structured context from the current buffer. Depending on the action, it may include:

- Project name
- Language
- Relative file path
- Symbol at point
- Focused identifier/expression/construct
- Enclosing semantic scope
- Parent semantic scope
- Imports
- Diagnostics
- Current code
- Git status
- Git diff
- Selected region
- Changed hunks
- Surrounding source context
- LSP/Eldoc symbol/type context

Git context is opt-in per request type. It is included for change-oriented actions such as Review, Security, Performance, Risks, Commit Message, Changelog, Full Review, Region Review, and Watch.

## Providers

Expose uses a provider layer so UI, request building, and transport stay separate.

Provider boundary:

```text
expose-context.el
  builds semantic context

expose-request.el
  selects context and defines action prompts

expose-document.el / expose-xml.el
  renders request documents

expose-transport.el
  sends requests to providers

expose-provider.el
  dispatches provider calls

expose-popup.el
  displays final popup responses
```

Provider implementations include:

- Clipboard provider for debugging/manual workflows.
- Codex provider for async CLI-backed requests.
- Copilot provider for async CLI-backed requests.
- Claude Code provider for async CLI-backed requests.
- Other provider modules when available.

## Storage

Expose stores persistent review/watch state inside the Git repository:

```text
.git/expose/
  reviews/
    <branch-slug>/
      active.eld
      history/
        <timestamp>.eld

  region-reviews/
    active/
      <sha>.eld
    history/
      <timestamp>-<sha>.eld

  watch/
    active.eld
```

Files are written as Lisp data using `prin1`/`read`, not loaded as code.

## Testing

```sh
cd site-lisp/expose
emacs -Q --batch -l test/run-tests.el
```

The suite covers redaction, XML rendering, review-request parsing, transport, commands, and Watch (project auto-arm state, active-entry filtering). It runs against real, disposable temp Git repos where relevant rather than mocking Git away.

Rendering/UI code -- the popup, hover, and Watch's source overlays (overlays, faces, the shared-popup integration) -- needs a real display and a real `posframe` frame, so it's deliberately not covered by this suite; those paths are instead verified manually and with ad hoc scripts that stub `posframe-show`/`posframe-hide` in batch mode.

CI runs the suite on Emacs 29.4 and `snapshot` via `.github/workflows/expose-tests.yml`.

## Troubleshooting

### Keybindings did not install

Expose only installs Doom leader bindings when `map!` is available. Check the log:

```text
SPC c h l
```

If the prefix conflicts with another non-prefix binding, Expose logs and skips installation.

### Hover does not appear

Check:

```text
SPC c h ?
```

Common causes:

- Buffer mode is disabled in `expose-hover-disabled-modes`.
- Buffer name matches `expose-hover-disabled-buffer-name-regexps`.
- No LSP hover and no Eldoc source is available.
- Point is in an internal/special buffer.
- A review/region/watch hover owns the current source location.

### Codex action hangs on Loading

Check:

```elisp
M-x expose-provider-codex-version
```

Then inspect:

```text
SPC c h l
```

Common causes:

- `codex` is not on `PATH` inside Emacs.
- Codex command/arguments are wrong.
- Codex failed before writing the output file.

### Git diff is too large

Reduce:

```elisp
(setq expose-context-git-diff-max-length 10000)
```

### Watch comments appear stale

Watch source markers only appear for reviewed hunks whose hash still exists in the current working-tree diff.

If stale markers remain, save the file or run:

```elisp
M-x expose-watch-review-current-buffer
```

or:

```elisp
M-x expose-watch-clear-current-buffer
```

## Current Limitations

- This is a local Doom-oriented package, not a polished MELPA package.
- Context extraction is best-effort and depends on Tree-sitter grammars.
- Git diff context is truncated to avoid huge prompts.
- Untracked file contents may not be included in Git diff context.
- Full Review, Region Review, and Watch depend on Git repositories.
- Watch dedupes by hunk hash, so meaningful edits to the same area create a new review opportunity.
- Provider process failures should be hardened further for production use.
- Archive viewers are read-only and intentionally do not apply suggestions or patches.


