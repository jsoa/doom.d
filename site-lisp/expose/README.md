# Expose

[![expose tests](https://github.com/jsoa/doom.d/actions/workflows/expose-tests.yml/badge.svg)](https://github.com/jsoa/doom.d/actions/workflows/expose-tests.yml)

Expose is a Doom Emacs helper package for showing code context, running focused AI-assisted code actions, and maintaining lightweight AI review state directly inside source buffers.

It combines hover documentation, diagnostics, semantic code context, Git diff context, provider-backed AI actions, review sessions, region reviews, background watch comments, inline continuation, popup history, and archive viewers behind a single leader-key interface.

## What Expose Does

Expose gives you a lightweight code-context command center at point:

- Shows LSP hover information when available.
- Falls back to Eldoc when LSP hover is unavailable.
- Shows Flycheck diagnostics at point.
- Displays a small `posframe` popup for hover, diagnostics, and Watch/Review comments.
- Shows Thing at Point action results and Region Review results in a persistent, colorized side window.
- Runs provider-backed code actions asynchronously.
- Supports Clipboard, Codex, Copilot, Claude Code, and other provider implementations.
- Captures popup history for Watch, Full Review, Region Review, and Thing at Point results.
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

### Where Expose shows things

Two things happen at point without a window of their own: the small `posframe` popup (hover, diagnostics, Watch/Review item comments -- ephemeral, gone when point moves) and inline continuation's ghost text.

Everything else that opens a real buffer -- a Thing at Point or Region Review result, the Full Review dashboard, popup history, the log, an ORM result, a Watch list, a review archive viewer, a Find Tests results list -- is placed beside whatever buffer it was invoked from: that buffer stays on the left wherever it started, the result lands in the window immediately to its right, splitting the frame if only one window was open. Re-derived fresh each time rather than tracked as state, so it self-corrects regardless of what happened between one open and the next. See `expose-side-panel-place`, shared by all of them.

Find Tests reuses the same left/right idea in reverse for one thing beyond just opening: the list itself keeps the fixed spot, on the right, and `RET` opens a test into the window to its *left* instead of replacing the list, so several tests can be visited in turn from the one search. See "Finding Tests" below.

The one exception is Diagrams, deliberately full-frame -- see "Diagrams" below.

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
      expose-action-buffer.el
      expose-side-panel.el
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

      expose-diagram.el
      expose-callers.el
      expose-find-tests.el
      expose-imports.el
      expose-migrations.el

      expose-orm.el
      expose-orm-plan.el
      expose-orm.py
```

`expose-orm.py` is the one non-Elisp file: it runs inside the *project's* Python, not Emacs, and is kept as a file rather than a string so it can be tested directly against a real Django project.

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
| `SPC c h b` | `expose-run-buffer-review`          | Review the current buffer's uncommitted changes |
| `SPC c h m` | `expose-run-merge-conflict`         | Explain and propose a resolution for the conflict at point |
| `SPC c h g` | `expose-run-commit-message`         | Insert generated commit message at point     |
| `SPC c h n` | `expose-run-changelog`              | Generate changelog entry from Git changes    |
| `SPC c h P` | `expose-run-pr-description`         | Write a PR description for the current branch |
| `SPC c h T` | `expose-run-explain-traceback`      | Explain a pasted error/traceback             |
| `SPC c h j` | `expose-popup-scroll-down`          | Scroll popup down                            |
| `SPC c h k` | `expose-popup-scroll-up`            | Scroll popup up                              |
| `SPC c h q` | `expose-popup-hide`                 | Close popup                                  |
| `SPC c h y` | `expose-popup-copy`                 | Copy popup contents                          |
| `SPC c h H` | `expose-history-open`               | Open popup history                           |
| `SPC c h o` | `expose-popup-open`                 | Open popup in a normal buffer                |
| `SPC c h l` | `expose-log-open`                   | Open Expose log                              |
| `SPC c h L` | `expose-log-clear`                  | Clear Expose log                             |
| `SPC c h t` | `expose-find-tests`                 | List the tests covering the code at point    |
| `SPC c h ?` | `expose-hover-debug-current-buffer` | Debug current buffer hover state             |
| `SPC c h h` | Thing at Point prefix               | Focused code-context actions                 |
| `SPC c h G` | Diagrams prefix                     | Rendered flow and call graphs                |
| `SPC c h D` | Django prefix                       | Queryset SQL, query plans, and Django-specific diagrams |
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
| `SPC c h h z` | `expose-run-dead-code-check`         | Is anything calling this at all?     |
| `SPC c h h n` | `expose-run-rename-impact`           | What would renaming this break?      |
| `SPC c h h ?` | `expose-hover-debug-current-buffer`  | Debug current buffer hover state     |

`expose-run-dead-code-check` and `expose-run-rename-impact` are not sent to a provider -- see [Dead Code Check & Rename Impact](#dead-code-check--rename-impact) below, alongside Finding Tests, whose side-panel results buffer they share the shape of.

A Thing at Point result does not show in the small hover popup -- these answers routinely ran longer than a hover has room for. Instead it opens in a persistent, colorized `*EXPOSE Action*` window: the buffer you actioned always ends up on the left, and the result always ends up in the window immediately to its right, splitting the frame if there was only one window open. It stays open, showing only the most recent action's result, until you close it (`q`) or run another action anywhere. Each result is also recorded to popup history (`SPC c h H`), same as before. Region Review's own results share this same window -- see "Region Reviews" below. Watch and Full Review are unaffected -- their hovers and source popups still work exactly as before.

It is an ordinary, read-only Evil-normal-state buffer -- navigate, search, and visually select in it the same as anywhere else. Extra keys:

| Key | Command                                | Description                                                      |
|-----|-----------------------------------------|-------------------------------------------------------------------|
| `y` | `expose-action-buffer-copy`            | Copy the whole buffer                                             |
| `c` | `expose-action-buffer-copy-code-at-point` | Copy the fenced code block at point (or the only one in the buffer) |
| `r` | `expose-commands-refine-action-buffer` | Refine the result with a follow-up instruction (see below)        |
| `q` | `quit-window`                          | Close it                                                           |

#### Refining a result

Experimental. `r` prompts for one line of free text -- e.g. "also add a test for the empty-list case" -- and rebuilds the same result with that folded in, on top of the exact code and context the action first ran against, not whatever point happens to be on now. It works on any successful `SPC c h h` result (Explain, Tests, Fix, all of them); a result that errored has nothing to build on and cannot be refined.

Every refinement you ask for is kept, including "undo that" or "nvm" -- there is no real undo, only another line appended to the list, sent back to the provider numbered and in order so it can work out for itself what "that" refers to and what the combined, final ask actually is. Be specific and reference the most recent request directly (the prompt shows this hint each time); a request several steps back, or one that only makes sense verbally in a longer conversation, is more likely to be misread. The full list-so-far is shown under the header. A refinement that fails leaves the buffer exactly as it was before you asked, so you can try again rather than losing the thread.

### Diagrams

| Key           | Command                             | Description                              |
|---------------|-------------------------------------|------------------------------------------|
| `SPC c h G c` | `expose-run-control-flow-diagram`   | Control flow of the code at point        |
| `SPC c h G C` | `expose-run-call-flow-diagram`      | What the code at point calls             |
| `SPC c h G d` | `expose-run-data-flow-diagram`      | How values move through the code         |
| `SPC c h G s` | `expose-run-side-effects-diagram`   | What this changes outside itself         |
| `SPC c h G m` | `expose-run-import-graph`           | What this file imports, transitively     |
| `SPC c h G t` | `expose-run-test-graph`             | Which tests reach the code at point      |
| `SPC c h G r` | `expose-run-reverse-call-graph`     | What calls the function at point         |

See [Diagrams](#diagrams-1) for what each one draws and how far to trust it.

### Django

Meaningless outside a Django project, so kept under its own prefix rather than crowding the generic keys above.

| Key           | Command                             | Description                                  |
|---------------|--------------------------------------|-----------------------------------------------|
| `SPC c h D s` | `expose-orm-inspect`                | SQL a Django queryset compiles to             |
| `SPC c h D p` | `expose-orm-explain`                | Query plan for the queryset at point          |
| `SPC c h D i` | `expose-orm-suggest-indexes`        | Which filters/ordering at point have no index |
| `SPC c h D n` | `expose-orm-detect-n-plus-one`      | N+1 check for the function at point           |
| `SPC c h D e` | `expose-run-er-diagram`             | Models and their relationships                |
| `SPC c h D h` | `expose-run-migration-history`      | How a Django model was shaped over time (`C-u` for all) |
| `SPC c h D R` | `expose-run-request-flow-diagram`   | Django request pipeline for a view            |
| `SPC c h D S` | `expose-run-signal-flow-diagram`    | What fires from a signal, and what responds   |
| `SPC c h D m` | `expose-run-middleware-diagram`     | The project's middleware stack, in request order |
| `SPC c h D u` | `expose-run-urls-diagram`           | The project's whole URL routing tree          |

See [Queryset SQL](#queryset-sql) and [Diagrams](#diagrams-1) -- the entity relations, migration history, and request flow diagrams are described there alongside the rest, even though their keys live here.

## Finding Tests

`SPC c h t` (`expose-find-tests`) answers "is this tested, and by what" as a side-panel results buffer, placed beside the code it was asked about the same way everything else in Expose is (see [Where Expose shows things](#where-expose-shows-things)):

```text
src/tests/test_events.py
142:def test_user_event_list(client):
167:def test_user_event_create(client):
src/tests/test_permissions.py
88:def test_permissions_denied(client):
```

Grouped under its file, the matching line shown in context. `TAB`/`S-TAB` move between tests, `RET` opens one to the *left* of the list rather than replacing it, so several tests found by the same search can be opened in turn without losing where they came from. `g` re-runs the search rather than redisplaying the old answer, and re-runs it *at the point the question was asked from*, not wherever the cursor sits in the results.

The same question as the [test graph](#diagrams-1), and the same computed answer — LSP call hierarchy falling back to `xref`, plus non-call references and, for Django, tests that reach a view only by `reverse()`-ing its URL name. Which one you want depends on what you are asking: the graph shows *how* a test gets here and through which intermediate functions, while this just takes you to the test.

Only tests are listed. The graph keeps the intermediate functions a test arrives through, which are the interesting part of a picture and noise in a list of somewhere to go. Each row shows the test's own source line, read from the buffer when one is visiting the file, so an unsaved test reads as it currently stands rather than as it is on disk.

When nothing reaches it, that is stated plainly rather than shown as an empty list — and it means no test reaches this within `expose-callers-max-depth` levels, not that the code is untested by every possible route.

A search the language server stopped answering says so instead of reporting a negative. "Nothing tests this" and "the search did not finish" are opposite answers, and the second passed off as the first is what somebody acts on before deleting code.

No AI: "which tests cover this" is worthless answered plausibly.

## Dead Code Check & Rename Impact

`SPC c h h z` (`expose-run-dead-code-check`) and `SPC c h h n` (`expose-run-rename-impact`) ask two different questions of the exact same search: the direct callers/references of the symbol at point, one level -- no further climbing, unlike the reverse call graph these share their walk with. Shown as a side-panel results buffer beside the source, same shape and keys as Finding Tests (`TAB`/`S-TAB` between call sites, `RET` opens one to the left without losing the list, `g` searches again).

**No AI in either.** Both need whole-project knowledge no provider has, and a confident, invented answer to "is this dead" or "what would this rename break" is worse than none -- same reasoning as the reverse call graph, which this is built on.

**Dead code check** asks whether anything calls or references the symbol at all:

```text
Dead code check: unused_helper

Nothing calls or references unused_helper within this project.

This only sees this project: a public API used elsewhere -- another
package, a different repo -- would not show up here either way.
```

Nothing found is the useful answer, not a failure -- but it only ever means *within this project*, stated plainly rather than implied, since a public API used from elsewhere is invisible to a search that only covers here.

**Rename impact** lists every call site before you commit to a rename, and marks the ones outside the symbol's own top-level directory as `OUTSIDE`:

```text
Rename impact: get_active_users

app/views.py
      12  def list_view(self):
OUTSIDE   app/other_package/tasks.py
      40      for u in get_active_users():
```

A caller inside the symbol's own directory is exactly what an editor-wide rename already catches for you; the ones marked `OUTSIDE` are not, and are worth a look by hand before the rename goes ahead.

### Full Review

| Key           | Command                           | Description                      |
|---------------|-----------------------------------|----------------------------------|
| `SPC c h R r` | `expose-review-open-or-start`     | Open or start full branch review |
| `SPC c h R d` | `expose-review-open-pr-diff`      | View diff against base branch, GitHub-PR style |
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

Rendered with Graphviz and shown as an SVG image in a full-frame buffer -- deliberately, and the one exception to the side-panel placement everything else in Expose uses (see "Where Expose shows things" above): these graphs get big, and a diagram squeezed into a side pane is unreadable in exactly the cases it's most needed. `q` restores whatever your window layout was before.

| Diagram            | Answers                                            | Source     | Key           |
|--------------------|-----------------------------------------------------|------------|---------------|
| Control flow       | Which paths run through this code                  | Provider   | `SPC c h G c` |
| Call flow          | What this code calls, and what those call          | Provider   | `SPC c h G C` |
| Data flow          | Where values come from, and where they end up      | Provider   | `SPC c h G d` |
| Side effects       | What this changes outside itself, and what survives a rollback | Provider | `SPC c h G s` |
| Import graph       | What this file imports, and its cycles             | Parsed     | `SPC c h G m` |
| Tests              | Which tests reach this code, and how               | LSP / xref | `SPC c h G t` |
| Reverse call graph | What calls this, transitively                      | LSP / xref | `SPC c h G r` |
| Request flow       | A Django request through its pipeline layers       | Provider   | `SPC c h D R` |
| Signal flow        | What fires a Django signal, and what each receiver does | Provider | `SPC c h D S` |
| Migration history  | How a Django model was shaped over time            | Parsed     | `SPC c h D h` |
| Query plan         | How the database will actually run this queryset   | Database   | `SPC c h D p` |
| Entity relations   | Which models exist and how they relate             | Provider   | `SPC c h D e` |
| Middleware         | The project's whole middleware stack, in request order | Parsed | `SPC c h D m` |
| URL routes         | The project's whole URL routing tree               | Parsed     | `SPC c h D u` |

The last seven are Django-specific and live under their own prefix (`SPC c h D`, see "Django" under Default Keybindings above) rather than crowding the generic ones -- everything below still applies to all of them equally, since the key prefix is the only thing that differs.

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

**Signal flow** traces what happens from a `.save()`/`.delete()` or an explicit `Signal().send()` through every receiver that responds, and what each receiver itself then does. This is the one link nothing else in Expose follows: a receiver connects to a signal by `@receiver(post_save, sender=Order)` or a plain `signal.connect(...)` call that routinely lives in a different app's `signals.py` than the model it watches, so reading the model or the `.save()` call alone shows none of it. Conditions that skip a receiver -- `raw=True`, a particular `sender`, `update_fields` -- are labelled on the edge into it rather than drawn as an unconditional response, for the same reason a rejection path matters on the request-flow diagram.

Run from inside a model, the model's own source has no visible connection to a receiver defined elsewhere -- so before asking a provider anything, this greps the whole project for `@receiver(...)` functions whose `sender=` names the model at point, and folds each one's *real* body into what gets sent, the same "computed, not generated" reflex the reverse call graph and test graph already apply to cross-file facts a provider cannot see on its own. Run from inside the receiver itself, its own `@receiver` is already part of the ordinary code at point and nothing further is added.

Textual, not a real parse: a `sender=` expressed any other way -- a variable holding the model class, a lazy string reference (`sender="app.Event"`) -- is not found, and neither is a receiver with no `sender=` at all (one that watches every model, an audit log say). Capped to `expose-signals-max-receivers` (8) receivers and `expose-signals-max-receiver-length` (4000) characters each, in case a heavily-watched model would otherwise mean sending a large multiple of its own code for one diagram.

Side effects answers a question none of the others quite do: if I call this, what happens to the world? Rows written, mail sent, jobs queued, services called — including effects several frames down, where the body is visible. Effects inside `transaction.atomic` are grouped in their own box, because the useful question is usually which of them survive a rollback: mail and queued tasks do, so a failure after that point leaves a notification about a row that no longer exists. Those keep their own shape inside the box rather than being redrawn as writes, so the hazard stays visible.

Data flow is the other inference-heavy one: it labels each edge with the operation, and states "mutated in place" explicitly, because rebinding a name and mutating the object behind it look nearly identical in source and behave nothing alike. That distinction is the reason to draw it, and also the thing most worth checking against the source.

**The tests graph** answers "is this tested, and by what" -- not a coverage percentage. It is the reverse call graph with its filter inverted: that one excludes tests so production paths stay readable, and this keeps only the half it discards. Callers no test goes through are pruned, so what remains is the routes tests take to reach the code, intermediate functions included. Static call paths alone would badly under-report on a Django project, so three weaker signals are added, each drawn differently so you can tell what you are looking at:

| Signal | Evidence | Drawn |
|--------|----------|-------|
| Call | The language server resolved a call | Solid |
| Reference | A real symbol usage, not a call | Dashed, amber |
| **Route** | A `reverse(...)` whose URL name resolves to this view | Solid, green, labelled with the name |
| Mention | The name appears in a test file's text | Dotted, grey |

The route is the important one for Django. A test calling `self.client.get(reverse("user-event-list"))` never names the view at all — the only true link is the URL name, which `urls.py` maps back to the viewset. Expose parses that mapping rather than running `manage.py show_urls`, which would be authoritative but needs settings, an app registry and usually a database — a running container, in a Dockerised project. DRF is not required — plain Django works the same way:

| Pattern | Example |
|---------|---------|
| Function view | `path("", views.post_list, name="post-list")` |
| Class-based view | `path("p/", PostDetailView.as_view(), name="post-detail")` |
| …with arguments | `path("a/", ArchiveView.as_view(paginate_by=10), name="archive")` |
| `re_path` / legacy `url()` | `url(r"^old/$", views.legacy, name="legacy")` |
| DRF router | `router.register("event", EventViewSet, basename="event")` |
| DRF router, no basename | derived from the queryset model — `EventHost` → `eventhost` |

`app_name = "shop"` namespaces are handled too: both `item-list` and `shop:item-list` are matched, since which one applies depends on how the module is `include()`d and that isn't visible from the file itself.

Note that the full route name is never written down anywhere: only the basename is, and DRF generates `-list`, `-detail` and any custom `@action` names from it. Expose reconstructs that rule rather than looking the names up, which is why custom actions are matched without knowing they exist.

The cost of parsing over running is the dynamic cases: `include()` namespaces and routers built in a loop are not followed.

Mentions also catch `@patch("app.tasks.send_email")`, which names its target in a string, and the `<Symbol>Test` naming convention.

When nothing at all reaches it, that is stated plainly rather than drawn as an empty graph.

**Migration history** reads a model's migrations and replays them, drawing the model's **state** at each step as a table of its fields, left to right from the initial shape to the current one — the same table form the entity graph uses. Each step tints only the rows that step changed: added fields green, altered amber, and removed fields shown one last time in red before they disappear from every table after. So the model as it stands today is the rightmost table, and what any one migration did to it is the colored rows in that column.

Fields carry their full definition, not just the class name. Most Django alterations change a keyword rather than the field type — `null=True`, a wider `max_length`, a different `default` — so `CharField` alone would render an altered row identical to the one before it, tinted amber with nothing to show for it.

An **altered row shows only the arguments that changed**, not the whole definition. A field keeps most of its definition through an alteration — the paragraph of `help_text` that was already there stays — so rendering all of it pushed the one argument that actually moved past the width limit, which is the argument you opened the diagram to find. A `default` moving 5 → 500 reads as `IntegerField(default=500)` regardless of how much untouched text surrounds it, and a dropped keyword shows as `-null`, since its absence is otherwise invisible. When several arguments change at once they are ordered shortest first, so a terse behavioural change isn't crowded out by a long prose one.

A changed row is also allowed to **run onto continuation rows**, one property per row, leaving the name column blank so the field still reads as one entry. Values are still truncated at `expose-migrations-max-definition-width` — a `choices=` list is not made readable by giving it six rows, and what you need from it is that `choices` is what moved. Splitting by property rather than reflowing the text matters: a line break falling wherever the width ran out puts half of `related_name` on one row and half on the next. Rows are capped by `expose-migrations-max-detail-lines`. A short definition splits the same way as a long one — splitting only what would overflow made a one-property change read differently from a four-property change, so the same kind of edit looked like two different things depending on how much text it happened to carry.

Expansion is withheld when a migration changed nearly everything, above `expose-migrations-max-expanded-fields`. `CreateModel` counts every field as added, so without that rule the very first table spells out the entire model and stands taller than the rest of the diagram — while singling nothing out, which is the only thing expansion is for.

Parsed, not generated: migration files are mechanically regular, a project accumulates dozens of them, and "when did this field become nullable" is a question where a plausible answer is worth nothing. Reading any one migration shows a single edit; what this adds is the accumulation, since a field added in `0004`, retyped in `0011` and dropped in `0032` lives in three files named after whatever else they happened to contain.

Long histories are trimmed to the most recent `expose-migrations-max-migrations` (24) — and the diagram says so, reading `last 24 of 301 migrations (277 earlier not shown)`, because a truncated history that looks complete is worse than no history. The newest are kept: the model's current shape is the part you can least afford to lose. The cap counts migrations rather than operations for the same reason it is stated at all — one migration routinely alters a dozen fields, so a budget expressed in operations silently drew five tables out of three hundred migrations.

**With a prefix argument (`C-u SPC c h D h`) it draws the complete history**, however long. The limit is a default, not a ceiling; set `expose-migrations-max-migrations` to nil to make that the normal behaviour. It exists because every table lists every field the model had at that point, so width grows with migrations and height with the model — three hundred of them is a picture to scroll rather than read, and the diagram buffer's zoom (`+`/`-`) is what makes it usable at all.

Django numbers migrations per app, so ordering is exact within an app but not comparable across them — `orders/0003` and `events/0032` carry no relative order in their names. Operations from different apps are therefore grouped rather than interleaved into a timeline that would be invented.

**The import graph has no AI in it either**, for the same reason: imports are trivially parseable, so asking a provider to describe them would trade an exact answer for a plausible one. It follows project-local imports and stops at the boundary — third-party and standard library packages are leaves, shown only with a prefix argument, since hiding them usually makes the project's own shape far easier to read. Python and TypeScript/JavaScript; tests, migrations and `node_modules` are excluded by `expose-imports-exclude-regexps`.

Its main reason to exist is **cycle detection**, drawn in red: an import cycle is invisible in any single file and in Python is a real failure rather than a style problem.

**Middleware has no AI in it either.** `MIDDLEWARE` is a literal Python list in the overwhelming common case, so "what order do these run in" is read, not guessed at from a settings file a provider may not even have been shown. Drawn as the onion it actually is, not a flat list: Django runs `MIDDLEWARE` in list order on the way *in* to a view and in *reverse* order on the way back *out*, so the first entry is the outermost layer — first to see the request, last to see the response. Two edges connect each adjacent pair, one each direction, rather than implying a single straight pipe. Project-local middleware are drawn with their own docstring when they have one; third-party and Django built-in middleware, not in the project's own tree to read, are named only. A `MIDDLEWARE` built up dynamically across more than one settings file (a `+=` in an environment-specific override) is read only as far as the one file its base list is actually declared in — a real, stated limit.

**The URL tree has no AI in it either.** Starts from `ROOT_URLCONF` and follows every `path()`/`re_path()`/`url()` entry, recursing through `include("app.urls")` from there, so the tree covers everywhere routing actually leads rather than just the one `urls.py` file you happen to have open. A DRF router's own `....register(...)` calls are read too, wherever they appear, and shown as their own nodes rather than as the `include(router.urls)` call site that mounts them — that call site names no view a parser could show, so drawing it literally would show the word "include" as if it were one. `include(router.urls)` and any other bare-identifier `include(...)` are left alone for the same reason: only the common string-argument form, `include("app.urls")`, names a module this can actually resolve and follow. Bounded by `expose-urls-max-depth` and `expose-urls-max-nodes`; a walk trimmed by either says so in the diagram's own title.

**The reverse call graph has no AI in it.** Finding callers needs whole-project knowledge that no provider has, and a fabricated answer to "is it safe to change this?" is worse than none, so its edges come from LSP call hierarchy — or `xref` when the server can't answer, which the graph says on its title since references are not the same as calls.

A language server that does not answer costs that branch, not the command. The walk makes one call-hierarchy request per node, and `lsp-request` signals on timeout, so a single slow answer used to abort everything and discard every caller already found — most likely on exactly the widely-called function whose callers you most wanted. Failed lookups are logged, and the graph's title says `(incomplete: 3 lookups failed)`, because a graph missing branches looks identical to a graph with nothing there, and this one is read to decide whether a change is safe.

It also includes non-call *references*, drawn dashed and labelled: a function that is only registered somewhere (`validators=[is_valid_member]`) has no callers at all and would otherwise read as dead code. Test files are excluded (`expose-callers-exclude-regexps`) because tests call everything and bury the production paths. The walk is bounded by `expose-callers-max-depth` and `expose-callers-max-nodes`; anything trimmed is marked on the graph rather than dropped silently.

Requires the `dot` binary; the commands say so plainly if it is missing.

## Queryset SQL

`SPC c h D s` (`expose-orm-inspect`) shows the SQL a Django queryset compiles to, and what about it will be slow. It uses the region when there is one, otherwise the whole statement at point — which is what you want for a chain wrapped over several lines, where the line under the cursor is a fragment that wouldn't parse.

**No AI, and no reconstruction.** The expression is handed to the project's own Python and compiled by Django itself, so the SQL is the SQL. Guessing at it from source would defeat the purpose: the questions worth asking a queryset — how many joins is this, does that filter hit an index — are worthless answered approximately.

**No database connection is opened, and this is enforced, not just intended.** `str(queryset.query)` compiles SQL through the backend without connecting, and every finding comes from the query object or the model's `_meta`. But a denylist of dangerous method *names* (below) can never be complete — Django's own contrib apps have methods that connect for real without looking dangerous (`ContentType.objects.get_for_model` looks up or creates a row), and any project's own custom manager/queryset method is unenumerable in advance. So real connections are refused outright for the duration of evaluation, at the one place every built-in backend actually opens one, regardless of what code path got there — not relying on recognizing the method by name at all. That is what makes this safe to point at a project whose `DB_HOST` is production, or whose database isn't running: an unrecognized method that would have connected now fails cleanly instead of quietly connecting anyway.

**Writes are refused, not executed.** The expression has to be *evaluated* to build the queryset, so a selection that reaches one line too far and catches `.delete()` would destroy data for real. Before anything is evaluated, the expression is parsed and rejected if it contains a write (`.delete()`, `.update()`, `.create()`, `.save()`, m2m `.add()`/`.clear()`) or something opaque enough not to trust (`raw()`, `execute()`). Method calls and builtins are told apart by call form rather than by name, since `qs.set(...)` is a related-manager write while `set(qs)` is an evaluation — and `.all()` is deliberately never refused, being both the most common call in any queryset and entirely lazy.

**Values it can't resolve — `self.request.user`, a local, `self.kwargs["id"]` — are mocked, not left dead**, since none of that changes the query's *shape*: which indexes it hits, what it joins, whether it's bounded. Mocked with a real value of the actual field's type, looked up from the model's own `_meta`, not a blind guess — see [Scope](#scope) below.

**A trailing read is rewritten, not refused.** `.get()`, `.exists()`, `.first()`, `.last()`, `.count()`, `.earliest()`/`.latest()` (and their `a`-prefixed async siblings) would connect to run for real — but each is just a filter chain plus that one read, and the filter chain underneath is exactly what `.query` can already show without connecting. So `Model.objects.get(pk=5)` is inspected as the `.filter(pk=5)` it already is under the hood (`QuerySet.get()` *is* `self.filter(...)` plus a single-row check — same SQL, not a reconstruction of it), and the result says as much: a note explains what the shown SQL leaves out (`.count()`'s `SELECT COUNT(*)` wrapper, `.first()`'s ordering and `LIMIT 1`, and so on). Only the *outermost* call is rewritten this way — one buried inside, building a filter argument (`qs.filter(pk=Other.objects.get(x=1).id)`), is still refused, same as any other real side effect this cannot safely evaluate around.

What it reports, all computed exactly:

- **Filters that no index will serve** — with the reason. A column with no index at all, and separately a column that is *only a non-leading member* of a composite index, which is the case most often gotten wrong: filtering on the second column of a two-column index scans anyway.
- **Lookups that defeat an index that does exist** — `icontains`, `endswith`, `regex` and friends compile to `LIKE` with a leading wildcard, so the column can be perfectly indexed and still be scanned.
- **Unbounded queries** — no `LIMIT`, which is fine until the table grows, and by then nobody is looking at the queryset.
- **N+1 risk** — the model's forward relations, when the queryset has no `select_related`. Raised only when nothing is being pulled in already, since a queryset that uses `select_related` has clearly had the thought.
- **Joins**, with type, and `distinct()` over a join, which often masks row duplication rather than fixing it.

Indexed filters are deliberately *not* listed. Findings only mean something when the list is short.

### Scope

The expression is evaluated in the namespace of the module it was written in, so every import and alias that file already has resolves — `Listing.objects.filter(state=ACTIVE)` works when `Listing` and `ACTIVE` are that module's own names. Every model is also bound by its own name, so an expression naming only a model works even from a file that fails to import.

What that cannot reach is **locals**: `request`, a loop variable, anything only ever assigned per-instance in `__init__`. Those exist only where the code runs, and cannot be resolved to a real value from here.

**A leading `self.` is the one local this resolves outright**, since `self.queryset.filter(...)` — the standard DRF/CBV shape — is ordinarily the exact same object as the class's own `queryset = Model.objects.filter(...)` attribute. Selecting from inside a method resolves that leading `self.` to its enclosing class before sending the expression, so `self.queryset.filter(status="open")` is inspected as `MyViewSet.queryset.filter(status="open")`. This assumes `queryset` really is set at the class level rather than only ever computed by a `get_queryset()` override or a `@property` — when it is not, the class-level lookup fails with its own clear error instead of pretending to work.

**A local that is itself just an alias for `self.ATTR` is resolved one hop further back**, the same way: `get_queryset` overrides very often start with `queryset = self.queryset` and narrow it from there, sometimes differently per branch --

```python
def get_queryset(self):
    queryset = self.queryset
    if condition:
        queryset = queryset.filter(x=1)
    else:
        queryset = queryset.filter(y=2)
    return queryset
```

-- and selecting any later statement using the bare `queryset` finds that original `queryset = self.queryset` line earlier in the same method and resolves through it, the same as if you had selected `self.queryset.filter(y=2)` directly. Only that one specific shape (`NAME = self.ATTR`, a bare attribute access, nothing chained onto it) is looked for — a *further* reassignment like `queryset = queryset.filter(x=1)` doesn't match it, so this always finds the original alias regardless of how many reassignments came after it, and is never confused by one. A local with no such assignment anywhere earlier in the method is unresolvable exactly as before.

**Everywhere else a local shows up as a `filter()`/`exclude()`/`get()` argument value, it's mocked, not refused** — `self.request.user`, `self.kwargs["id"]`, any name or expression that can't be resolved. The point of this tool was never the exact value a query runs with; it's the query's *shape* — which indexes it hits, what it joins, whether it's bounded — and none of that depends on which specific user or id it is. So the unresolvable value is replaced with a plausible one, of the *actual field's* type: an int for a `ForeignKey`, a string for `CharField`, an ISO date for `DateField`, and so on — looked up from the model's own `_meta`, the same "computed, not generated" rule everything else here follows, not a blind placeholder guessed without knowing what it's standing in for. `__in` wraps it in a list, `__isnull` stays a plain boolean regardless of the field. What got mocked, and with what, is always named in the result's note, so a real filter never quietly looks identical to a made-up one.

This reaches into a `Q(...)` too, however deeply combined with `|`/`&`/`~` — `filter(Q(a=1) | Q(b=self.request.user))` has its real field lookups one level down from `.filter()` itself, but they're the same kind of thing either way, so they're mocked the same way. A bare `Q(...)` with no `filter()`/`exclude()`/`get()` wrapping it at all is a different story — there's no queryset for it to belong to yet, so there's no model to mock against, same as any other unresolvable base.

Only an argument *value* is ever replaced — never the queryset itself. `some_local_queryset.filter(x=1)`, where the unresolvable name is what you're filtering rather than an argument to it, still reports the name it couldn't resolve; there's no field to mock a starting point against, only a different expression to select instead (`Model.objects.filter(x=1)`, say).

### Missing Indexes

`SPC c h D i` (`expose-orm-suggest-indexes`) runs on the same expression `expose-orm-inspect` does, and is not a second analysis -- `describe_filters`/`describe_ordering` already compute `indexed`/why for every filter and ordering term as part of `expose-orm-inspect`'s own output (see "What it reports" above). This just narrows that same, already-real data down to the terms with no index, instead of reading them out of a wall of SQL and joins:

```text
blog.Post

  ! filters blog_post.color (exact) -- no index
```

"Every filter and ordering term here is indexed" when there's nothing to report -- stated plainly, the same convention as everywhere else in Expose that computes something exact.

### N+1 Queries

`SPC c h D n` (`expose-orm-detect-n-plus-one`) checks the function at point -- or the region, when one is active -- for a `for` loop or comprehension whose body accesses an unfetched relation on the row it's iterating:

```python
for post in Post.objects.all():
    print(post.author.name)   # a query per row
```

```text
Checked 1 loop over a queryset

  ! line 2: `.author` inside the loop (starting line 1) -- add `select_related('author')` to avoid a query per row
```

**Computed against the model's real metadata, the same way the rest of Queryset SQL is.** The loop's own iterable is resolved exactly like any other queryset expression here -- refused if it's a real write or a real read (`.get()`, `.delete()`, and the rest of the same denylist `expose-orm-inspect` uses), never connecting for real either way (`connections_refused` applies here too) -- and each attribute access on the loop variable is checked against `_meta.get_field` to see whether it's a relation, and whether that relation is already covered by `select_related`/`prefetch_related` on the queryset being iterated.

**Only a single hop is checked** -- `row.category`, not `row.category.parent` -- a further hop is a question about `category`'s own model, not this loop.

**A loop whose iterable can't be resolved statically is counted, not silently skipped.** `for post in self.get_queryset():` depends on `self`, which only exists where the code actually runs, so it's reported as unresolved rather than folded into either "clean" or "found nothing" -- those are different answers, and only one of them means the code was actually looked at.

### Query plans

`SPC c h D p` (`expose-orm-explain`) draws the plan the database will actually use, as a graph. `C-u SPC c h D p` runs `EXPLAIN ANALYZE` instead, which **executes the query** and replaces the planner's estimates with what really happened.

This is the one command here that connects — a plan is the planner's opinion and only the planner holds it. It runs against `expose-orm-dsn` if set, otherwise the `expose-orm-database` alias, so you can take plans from a replica rather than whatever `DATABASES["default"]` points at. Either way the transaction is rolled back and `expose-orm-statement-timeout` (10s) bounds it, because explaining a slow query otherwise means waiting out the slow query. Writes are still refused before anything is evaluated.

Drawn bottom to top, the direction rows actually move: scans at the bottom feed joins feed the result at the top. That also suits the shape — plans are deep and narrow, and a deep tree laid out left to right is a ribbon.

**Red is rationed.** A sequential scan is not a problem by itself: over a small table it is the *correct* plan, and colouring every one of them red says only that the query touched a table. Red means the node did something worth looking at:

- **Rows read and then discarded** — the clearest possible statement that an index is missing, and unlike a cost number it needs no interpretation.
- **A row estimate that was badly wrong** — nearly every bad plan is a good plan chosen from a bad estimate, so this is the first thing to check when the shape looks reasonable but the query is slow. Reported only above `expose-orm-plan-misestimate-floor` rows: a ten-fold error on fifty rows is still fifty rows and cannot change which plan wins, and small tables throw large ratios constantly.
- **A sort that spilled to disk**, and scans that read more than `expose-orm-plan-large-scan-rows`.

Everything else is coloured structurally — index scans green, joins blue, sorts and hashes amber for the rows they buffer.

### Setup

Runs `manage.py shell` in the project root, found by locating `manage.py` above the current file. That is the whole setup for a project whose Python runs locally — there is nothing to configure.

To run inside a container, set it in the project's `.dir-locals.el`:

```elisp
((python-base-mode
  . ((expose-orm-container . "myproject-app-1"))))
```

`python-base-mode`, not `python-mode`: `python-mode` and `python-ts-mode` are siblings rather than parent and child, so a `python-mode` entry silently never applies in `python-ts-mode` buffers.

| Variable                        | Default                        | Purpose                                        |
|---------------------------------|--------------------------------|------------------------------------------------|
| `expose-orm-container`          | `jsoa/docker-jump-container`   | Container to run the project's Python in       |
| `expose-orm-workdir`            | the image's `WORKDIR`          | Where `manage.py` lives inside the container   |
| `expose-orm-python`             | `python`                       | Interpreter                                    |
| `expose-orm-database`           | `default`                      | `DATABASES` alias to take query plans from     |
| `expose-orm-dsn`                | unset                          | Connection string, bypassing `DATABASES`       |
| `expose-orm-statement-timeout`  | `10000`                        | Milliseconds before the database cancels a plan |

The container falls back to `jsoa/docker-jump-container`, so a project already configured for remote jump-to-definition needs no second setting. All of these are marked safe, so Emacs does not prompt for them.

A container name checked into `.dir-locals.el` is only as portable as everyone's `docker-compose` naming happens to be — if it doesn't exist on this machine, that's called out by name (which variable set it, and to what) rather than surfacing Docker's own "no such container" as an unexplained failure.

`expose-orm-database` and `expose-orm-dsn` are worth setting when the default connection is one you would rather not plan against: they only change which database the plan comes from, since the SQL is still compiled by the project's own Django.

The expression travels as a JSON environment variable rather than interpolated into a command line, so quoting inside it can't break anything, and the script's output is delimited by markers because `manage.py shell` prints banners and deprecation warnings around it.

## Buffer Review

`SPC c h b` (`expose-run-buffer-review`) reviews the current buffer's own uncommitted changes -- driven by the diff itself, not the code at point the way Thing at Point's own `SPC c h h r` (Review) is. For "is what I've just changed here any good", asked directly, without first selecting the change or navigating to it.

```text
SPC c h b
  -> git diff HEAD for this file only (or `--cached` under `expose-context-git-staged-only')
  -> review it for correctness, readability, maintainability, and potential bugs
  -> show the result in the action buffer, same as any other SPC c h h result
```

Refuses up front, rather than sending an empty diff, if the file has no uncommitted changes. Scoped to this file specifically (`git diff -- FILE`), not the whole project -- for that, use Full Review. The result is refinable the same way any other action-buffer result is (see "Refining a result" above).

## Merge Conflict Resolution

`SPC c h m` (`expose-run-merge-conflict`) explains both sides of the `<<<<<<< ... ======= ... >>>>>>>` hunk at point and proposes a resolution:

```text
SPC c h m
  -> find the <<<<<<</=======/>>>>>>> hunk enclosing point
  -> send both sides, their branch labels, and surrounding code
  -> explain what each side was trying to do, and propose a resolution
  -> show the result in the action buffer, same as any other SPC c h h result
```

Refuses up front, like Buffer Review, if point is not actually inside a conflict hunk -- rather than sending nothing real to explain. Advisory like Explain/Fix: it proposes a resolution in a fenced code block, it does not apply one -- nothing in the buffer changes until you make it. The result is refinable the same way any other action-buffer result is (see "Refining a result" above).

## Traceback Explanation

`SPC c h T` (`expose-run-explain-traceback`) is the one Expose action whose input is not the buffer at all: a traceback is pasted text, which has no natural single-line prompt the way a refinement's one-line `read-string` has. It opens a scratch buffer to paste into -- `C-c C-c` sends it, `C-c C-k` cancels without sending anything.

**Every `File "...", line N` frame found in the pasted text is resolved against the current project and its real source read directly off disk**, sent alongside the raw traceback text rather than left for the model to guess at code it was never shown -- Expose can read the project's files and the model cannot, so whatever this can resolve locally travels as fact. A frame whose file can't be found locally (moved, renamed, inside a container with a different path) is still included, file and line named, just without a snippet.

Python tracebacks only -- that frame format (`File "...", line N, in ...`) is Python's own. Capped to `expose-traceback-max-frames` (12) frames, keeping the ones nearest either end of the stack when there are more than that, since that's usually where the interesting code is on a long one.

## Commit Message Insertion

`expose-run-commit-message` uses the normal commit-message request flow, but it does not show a loading popup.

Instead:

```text
SPC c h g
  -> generate commit message from current Git changes
  -> insert returned text at the point where the command was invoked
```

This is useful inside Magit commit buffers or any scratch/edit buffer where you want the commit message placed directly into the buffer.

## PR Description

`SPC c h P` (`expose-run-pr-description`) writes a GitHub pull request description for the whole current branch, shown in the action buffer like Changelog rather than inserted anywhere -- there's no natural buffer for a PR description the way a commit message has one.

```text
SPC c h P
  -> detect the base branch (main/master/develop, or `expose-review-base-branch')
  -> git diff BASE...HEAD, and the branch's own commit subjects (BASE..HEAD)
  -> write a summary, a "How to test" section, and a note of risk
  -> show the result in the action buffer, same as any other SPC c h h result
```

**Scoped to the whole branch against its base, not the working tree.** This is the one difference from Commit Message and Changelog, which both describe uncommitted/staged changes -- a PR is about everything the branch has added since it forked, so this reuses the exact base-branch detection and merge-base diff range `expose-review-open-pr-diff` already shows locally as a Magit diff (three dots: `BASE...HEAD` compares against the merge-base, so commits landed on `BASE` after the fork don't show up as this branch's own changes).

**The commit log travels alongside the diff, not instead of it.** A commit message routinely states intent a diff of the end result cannot, especially once a rebase or a run of `fixup!` commits has flattened the actual path taken -- so both are sent, and the instruction asks for the diff as the primary source of truth for *what* changed, the log as a second signal for *why*.

Refuses up front, like Buffer Review, if no base branch could be detected or the branch has no changes relative to it -- rather than sending an empty diff and getting back a description of nothing. The result is refinable the same way any other action-buffer result is (see "Refining a result" above).

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

A full review collects branch and Git context, sends a strict JSON review request, parses review items, and displays them in a dashboard buffer -- placed beside whatever buffer it was opened from (splitting if only one window was open), the same left/right arrangement as an action-buffer result, rather than replacing it outright. Unlike that buffer, opening a review moves focus into the dashboard, since it's somewhere you're going to read and act on rather than glance at.

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

`SPC c h R d` (`expose-review-open-pr-diff`) is the non-AI sibling of the above: a Magit diff of the current branch against its detected base, foldable by file the way GitHub's PR "Files changed" view is, entirely local and requiring no GitHub access. Same base-branch detection as `SPC c h R r`.

## Region Reviews

Region Review is a persistent selected-region review workflow.

```text
select region
SPC c h M m
  -> review selected source range
  -> show full review in the persistent action buffer when ready
  -> keep source markers active until completed/canceled
```

Region Review behavior:

- Reviews only the selected range.
- Includes surrounding context and symbol/type context.
- Persists the active review session.
- Rejects overlapping active region reviews in the same file.
- Shows a subtle active-region indicator.
- Shows right-fringe markers for active review ranges.
- Shows item hovers only on concrete review item lines, in the small hover popup.
- Does not auto-popup merely by moving through the active region.
- Can be completed or canceled from the source buffer.

The review's own results -- the "Reviewing..." message shown as soon as it starts, and the full review once it completes, fails, or times out -- open in the same persistent `*EXPOSE Action*` window Thing at Point results use, placed and recorded to history the same way. Only the per-item hover (resting on a single flagged line) stays in the small popup; Full Review's source hover is unaffected by any of this.

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


