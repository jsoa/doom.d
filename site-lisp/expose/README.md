# Expose

Expose is a Doom Emacs helper package for showing code context and running focused AI-assisted code actions from a small `posframe` popup.

It combines hover documentation, diagnostics, semantic code context, Git diff context, and Codex-powered actions behind a single leader-key interface.

## What Expose Does

Expose gives you a lightweight code-context command center at point:

- Shows LSP hover information when available.
- Falls back to Eldoc when LSP hover is unavailable.
- Shows Flycheck diagnostics at point.
- Displays results in a small `posframe` popup.
- Runs Codex-backed code actions asynchronously.
- Captures popup history.
- Supports copy/open/log/debug commands.
- Supports quick hover scrolling with `C-j` / `C-k` while the popup is visible.
- Includes Git status and diff context for change-oriented actions.

The core idea is:

```text
source buffer at point
  -> build structured context
  -> render XML request document
  -> send to provider
  -> render Markdown response
  -> show result in popup
```

## Screens / Workflow

Typical workflow:

```text
hover code
  -> Expose popup shows docs / type info / diagnostics

SPC c h r
  -> run Review action

SPC c h g
  -> generate a commit message from current Git changes

SPC c h h
  -> open popup history

C-j / C-k
  -> scroll the visible popup without opening the leader menu
```

## Configuration

Common settings:

```elisp
(setq expose-key-prefix "c h"
      expose-hover-delay 0.25
      expose-popup-max-height 20
      expose-popup-max-width 120
      expose-provider-default 'codex
      expose-context-git-diff-max-length 20000)
```

Codex settings:

```elisp
(setq expose-provider-codex-command "codex"
      expose-provider-codex-arguments
      '("exec" "--skip-git-repo-check"))
```

Output formatting instruction:

```elisp
(setq expose-request-output-instruction
      "Return the response as concise Markdown. Do not return XML, HTML, JSON, or custom tags. Do not mirror the request document structure. Use headings, bullet lists, and fenced code blocks when useful.")
``


Expose installs bindings under `SPC c h` by default.

| Key         | Command                             | Description                               |
|-------------|-------------------------------------|-------------------------------------------|
| `SPC c h j` | `expose-popup-scroll-down`          | Scroll popup down                         |
| `SPC c h k` | `expose-popup-scroll-up`            | Scroll popup up                           |
| `SPC c h q` | `expose-close`                      | Close popup                               |
| `SPC c h r` | `expose-run-review`                 | Review current code                       |
| `SPC c h d` | `expose-run-diagnostics`            | Explain diagnostics                       |
| `SPC c h e` | `expose-run-explain`                | Explain symbol/construct                  |
| `SPC c h f` | `expose-run-fix`                    | Suggest a focused fix                     |
| `SPC c h R` | `expose-run-refactor`               | Suggest behavior-preserving refactor      |
| `SPC c h s` | `expose-run-security`               | Security review                           |
| `SPC c h p` | `expose-run-performance`            | Performance review                        |
| `SPC c h t` | `expose-run-tests`                  | Suggest tests                             |
| `SPC c h x` | `expose-run-edge-cases`             | Identify edge cases                       |
| `SPC c h w` | `expose-run-flow`                   | Explain execution flow                    |
| `SPC c h u` | `expose-run-usage`                  | Explain usage                             |
| `SPC c h D` | `expose-run-docstring`              | Suggest docstring/comment                 |
| `SPC c h m` | `expose-run-summary`                | Summarize code                            |
| `SPC c h T` | `expose-run-types`                  | Explain important types                   |
| `SPC c h C` | `expose-run-concurrency`            | Review concurrency/race risks             |
| `SPC c h i` | `expose-run-invariants`             | Identify invariants                       |
| `SPC c h !` | `expose-run-risks`                  | Identify practical risks                  |
| `SPC c h Y` | `expose-run-why`                    | Explain likely design intent              |
| `SPC c h M` | `expose-run-mental-model`           | Build a mental model                      |
| `SPC c h g` | `expose-run-commit-message`         | Generate commit message from Git changes  |
| `SPC c h n` | `expose-run-changelog`              | Generate changelog entry from Git changes |
| `SPC c h y` | `expose-popup-copy`                 | Copy popup contents                       |
| `SPC c h h` | `expose-history-open`               | Open popup history                        |
| `SPC c h o` | `expose-popup-open`                 | Open popup in a normal buffer             |
| `SPC c h l` | `expose-log-open`                   | Open Expose log                           |
| `SPC c h L` | `expose-log-clear`                  | Clear Expose log                          |
| `SPC c h ?` | `expose-hover-debug-current-buffer` | Debug current buffer hover state          |

## Quick Hover Scroll Keys

While an Expose popup is visible, Expose also installs a temporary emulation keymap:

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

## Context Collected

Expose builds a structured context object from the current buffer. Depending on the action, it may include:

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

Git context is opt-in per request type. It is included for change-oriented actions such as Review, Security, Performance, Risks, Commit Message, and Changelog.

## Current Limitations

- This is a local Doom-oriented package, not a polished MELPA package.
- Context extraction is best-effort and depends on Tree-sitter grammars.
- Git diff context is truncated to avoid huge prompts.
- Untracked file contents may not be included in Git diff context.
- Codex process failures should be hardened further for production use.
