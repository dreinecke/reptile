# Reptile

Reptile (re-tile) is a panel for the [Omarchy](https://omarchy.org) Quickshell bar
that records what each desk holds — which windows, where, how big — and puts a desk
back to its recording on demand. Open the panel to see every desk's recording drawn
as blocks: drag to swap, drag the line to resize, `x` removes, `+` adds. Every
change is saved as you go and applied on the desk's next visit.

It was built by a Claude Code agent on the author's machine, extracted from the
machine-configuration repo it grew up in (19 commits of history carried over).
Its sibling is [Barbarian](https://github.com/dreinecke/barbarian), the bar arranger.

## What's inside

- **`plugin/`** — the Quickshell bar widget (`tinkerbell.reptile`). Zero width on
  the bar; it exists to host the panel and its IPC target, toggled with
  `qs -p /usr/share/omarchy/shell ipc call tinkerbell.reptile toggle`. While a desk
  is being laid out, a card at the bottom of the screen says so — the panel's only
  voice, driven by the engine through IPC.
- **`engine/ws-layout`** — the engine: record (`ws-layout snapshot`), restore
  (`ws-layout restore`), rearrange into equal columns, and the edit commands the
  panel sends. Recordings live at `~/.config/omarchy/workspace-layout/snapshots/`
  and are machine-local — nothing here re-asserts them.

## Requirements

- Omarchy (built against its Quattro-era shell: the QML imports `qs.Commons` and
  `qs.Ui`, which only exist inside the Omarchy shell)
- The plugin must be **listed in `shell.json`'s right section** to load at all —
  Omarchy keeps that file machine-local, so add the id by hand after installing.

## Install

```sh
git clone https://github.com/dreinecke/reptile
cd reptile && ./install.sh
```

Installs user-space only: the plugin to
`~/.config/omarchy/plugins/tinkerbell.reptile/`, the engine to
`~/.config/omarchy/workspace-layout/ws-layout`. Idempotent — re-running is the
repair. The plugin id stays `tinkerbell.reptile` for history's sake; it is
load-bearing in `shell.json`, keybinds and the engine's IPC callback, so it was
left alone through the extraction.

## License

MIT — see [LICENSE](./LICENSE).
