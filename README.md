# agent-shell-follow-edits

An extension package for [agent-shell](https://github.com/xenodium/agent-shell) that automatically follows agent edits in real-time.


## Installation

### Using `use-package`

```emacs-lisp
(use-package agent-shell-follow-edits
  :vc (:url "https://github.com/cmacrae/agent-shell-follow-edits")
  :after agent-shell
  :hook (agent-shell-mode . agent-shell-follow-edits-mode))
```

### Manual Installation

Clone the repository and add to your load path:

```emacs-lisp
(add-to-list 'load-path "/path/to/agent-shell-follow-edits")
(require 'agent-shell-follow-edits)
(agent-shell-follow-edits-mode 1)
```

## Usage

Enable the mode globally:

```elisp
(agent-shell-follow-edits-mode 1)
```

Or toggle it on the fly:

```
M-x agent-shell-follow-edits-toggle
```

## Configuration

### Variables

- `agent-shell-follow-edits-enabled` - Whether to automatically follow edits (default: `nil`)
- `agent-shell-follow-edits-delay` - Delay in seconds before following (default: `0.3`)
- `agent-shell-follow-edits-highlight` - Whether to highlight edited regions (default: `t`)
- `agent-shell-follow-edits-highlight-face` - Face used for highlighting (default: `'lazy-highlight`)

### Faces

- `agent-shell-follow-edits-highlight-face` - Face for pulsing highlight of changes (default: inherits from `lazy-highlight`)
- `agent-shell-follow-edits-diff-removed-face` - Face for removed lines in diffs (default: inherits from `diff-refine-removed`)
- `agent-shell-follow-edits-diff-added-face` - Face for added lines in diffs (default: inherits from `diff-refine-added`)

## Requirements

- Emacs 29.1+
- [agent-shell](https://github.com/xenodium/agent-shell) 0.17.2+

## License

GPL-3.0-or-later
