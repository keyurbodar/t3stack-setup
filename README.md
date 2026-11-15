# t3stack-setup

One magpie hub, many machines. Install once per machine; after that a 3-minute
converge keeps the script, tools, plugins, dotfiles, models and config current.
No releases, no CDN, no prompts.

## Install (one line per machine)

```sh
git clone -q https://github.com/keyurbodar/t3stack-setup ~/.local/share/t3stack-setup && sh ~/.local/share/t3stack-setup/setup.sh
```

Already cloned? `git -C ~/.local/share/t3stack-setup pull -q && sh ~/.local/share/t3stack-setup/setup.sh`

It installs magpie and itself as `~/.local/bin/t3stack`, the basics (`curl gh
htop fastfetch node bun`), trusts the hub CA, runs the local gateway, adds the
hub as a provider, installs Claude Code + pi + the plugins in
`claude-plugins.txt`, and points every agent at the hub. Nothing is typed: hub,
join key and CA pin come from `t3stack.conf`.

## Everyday

```sh
t3stack                 # join / re-join (no args needed)
t3stack fleet           # every machine: version, last report, missing tools
t3stack status          # this machine: gateway, providers, agents
t3stack deps --check    # what is present / missing here
t3stack sync            # private config/skills backup
t3stack update          # refresh the command (the timer does this too)
t3stack dotfiles pull   # merge shared Claude/pi/T3 settings
t3stack dotfiles save   # publish this machine's extra settings
t3stack version
```

## How it converges

A systemd user timer runs every 3 minutes:

```
t3stack update → t3stack deps → magpie sync → t3stack sync → dotfiles pull → report
```

So editing this repo (script, `packages.txt`, `claude-plugins.txt`, `dotfiles/`,
`t3stack.conf`) or the hub (providers, keys, visibility) reaches every machine
within 3 minutes, with no commands anywhere.

## Adding things

- **A program** → a line in `packages.txt`.
- **A Claude Code plugin** → a line in `claude-plugins.txt` as `<marketplace>  <plugin@marketplace>`.
- **A shared agent setting** → `t3stack dotfiles save` (magpie-owned keys are skipped).
- **A provider / model / account** → on the hub only (`magpie provider add …`,
  `magpie accounts add …`); every machine sees it as `hub/…`.

## Notes

- This public repo is the distribution: the script, config, dotfiles and fleet
  reports. The sealed magpie backup and the hub CA live in the private
  `t3stack` repo.
- No GitHub Actions, no releases, no assets, no CDN — cloning is the update path.
- `sync` carries settings, profiles, agent picks and the Library, but **no API
  keys and no memory**. An MCP server whose env holds a token should be
  `magpie library mcp local <name> on`, so sync never carries it.
- The join key is public and capped on the hub; it cannot read provider keys.

MIT licensed.
