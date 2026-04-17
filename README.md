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

## Structure

```
. 
├── core/               # foundational configuration 
├── modules/            # language + tooling modules 
├── private/vars.el     # private variables (must be defined if needed)
├── config.el           # user configuration 
├── init.el             # module declarations 
└── packages.el         # package definitions
```

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
- copilot (https://github.com/copilot-emacs/copilot.el)

---

## AI Setup (Optional)

```
M-x copilot-login
```

---

## License

MIT

## Other Information

- This config was tested on Emacs 29, that was built from source on Ubuntu 22

## Tree Sitter language grammar install

- M-x treesit-install-language-grammar
