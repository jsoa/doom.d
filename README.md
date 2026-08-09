# Doom Emacs Config

A high-performance, modular configuration for Doom Emacs designed for speed, clarity, and workflow efficiency.

> Build an editor that works for you—not the other way around.

---

## Philosophy

At some point, you stop choosing tools. You start building them.

This config is built around a few core principles:

- Every addition must reduce friction or compress a common task.
- Automation (including AI) is opt-in, not intrusive.
- Configuration is split into focused, reusable modules.
- Fast feedback loops are essential for productivity.
- Your editor should grow as your workflow improves.

---

## Disclaimer

The code here is written by AI with my guidance.

## Structure

```
. 
├── core/               # foundational configuration 
├── modules/            # language + tooling modules 
├── site-lisp/          # custom local packages
├── private/vars.el     # private variables (must be defined if needed)
├── config.el           # user configuration 
├── init.el             # module declarations 
└── packages.el         # package definitions
```

---

## Site-lisp Libraries

Custom local packages under `site-lisp/`, each with its own README and ERT test suite run in CI.

| Library                                      | Status                                                                                                                                                          | Description                                                             |
|-----------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------|
| [expose](site-lisp/expose/README.md)         | [![expose tests](https://github.com/jsoa/doom.d/actions/workflows/expose-tests.yml/badge.svg)](https://github.com/jsoa/doom.d/actions/workflows/expose-tests.yml)         | Code context, AI-assisted actions, review sessions, and background Watch mode directly in source buffers. |
| [dashboard](site-lisp/dashboard/README.md)   | [![dashboard tests](https://github.com/jsoa/doom.d/actions/workflows/dashboard-tests.yml/badge.svg)](https://github.com/jsoa/doom.d/actions/workflows/dashboard-tests.yml) | Per-project command-center buffer: project info, Git summary, LOC breakdown, diagnostics, and TODOs. |

---

## Per-project setup (`.dir-locals.el`)

Nothing here requires per-project configuration — every feature falls back to
working locally. What `.dir-locals.el` buys you is reaching a project that runs
somewhere else, typically in Docker.

Drop this at the root of a Python project:

```elisp
((python-base-mode
  . ((jsoa/docker-jump-container . "myproject-app-1")
     (jsoa/docker-jump-site-packages . "/usr/local/lib/python3.11/site-packages"))))
```

| Variable                          | What it does                                                                 |
|-----------------------------------|------------------------------------------------------------------------------|
| `jsoa/docker-jump-container`      | Container to resolve `gd` into when the definition is outside the project     |
| `jsoa/docker-jump-site-packages`  | Absolute path of `site-packages` inside that container                        |

`python-base-mode`, **not** `python-mode`. `python-mode` and `python-ts-mode` are
siblings rather than parent and child, so a `python-mode` entry silently never
applies in `python-ts-mode` buffers, and vice versa. `python-base-mode` is the
actual shared parent of both, and getting this wrong looks exactly like the
feature not working.

Expose's Django queryset commands (`SPC c h s`, `SPC c h G p`) reuse that same
container, so a project configured as above needs nothing further. Override any
of it only if the defaults don't fit:

```elisp
((python-base-mode
  . ((expose-orm-container . "myproject-app-1")   ; defaults to the docker-jump one
     (expose-orm-workdir . "/code")               ; defaults to the image's WORKDIR
     (expose-orm-python . "python")
     (expose-orm-database . "replica")            ; DATABASES alias to take plans from
     (expose-orm-dsn . "postgresql://...")))) ; or bypass DATABASES entirely
```

`expose-orm-database` and `expose-orm-dsn` exist so query plans can come from a
replica or a dev copy rather than whatever `DATABASES["default"]` points at —
worth setting if the default connection is production. All of these are marked
safe, so Emacs won't prompt for them. See the
[expose README](site-lisp/expose/README.md#queryset-sql) for what the commands do
with them.

---

## Installation

```bash
git clone <your-repo-url> ~/.doom.d
doom sync
```

---

## Font

https://www.jetbrains.com/lp/mono/

---

## Additional packages

- avy (https://github.com/abo-abo/avy)
- consult (https://github.com/minad/consult)
- embark (https://github.com/oantolin/embark)

---

## License

MIT

## Other Information

- This config was tested on Emacs 29, that was built from source on Ubuntu 22

## Tree Sitter language grammar install

- M-x treesit-install-language-grammar
