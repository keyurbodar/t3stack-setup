# t3stack-setup

One magpie hub, many machines — install once, then use the local `t3stack`
command. Nothing is fetched again unless you run `t3stack update`.

## Clients

```sh
curl -fsSL https://github.com/keyurbodar/t3stack-setup/releases/latest/download/setup.sh | sh
```

That installs magpie **and itself** as `~/.local/bin/t3stack`, trusts the hub
CA, runs the local gateway, adds the hub as a provider, installs Claude Code
and pi if they are missing, and points every agent magpie finds at the hub's
model. Then:

```sh
t3stack status                  # gateway, join key, providers, agents
t3stack join <key>              # re-join / switch hub (optional key)
t3stack sync                    # magpie's encrypted config + skills sync
t3stack update                  # refresh the local command
```

Flags: `--no-install` (don't install Claude Code/pi), `--no-wire` (leave every
agent's model exactly as it is), `--model hub/provider/model`, `--id`.

The default model is picked sensibly (`deepseek-v4.1-flash`, else a sonnet /
glm / kimi, else the first the hub serves).

### The join key

There is no key in this repository. A key is looked up in this order: the key
argument, `GATEWAY_KEY`, `KEY_FILE`, `~/.config/t3stack/gateway.key`, the private
repo `keyurbodar/t3stack` through `gh`, `ADMIN_KEY`/`ADMIN_KEY_FILE` (mints a
key named after the machine), then a prompt. It is short and private — keep it
in your password manager.

`join` checks the key against the hub before changing anything: `401/403` stops
with "the hub rejected this key", a network failure says so, and only then is
anything written.

## Hub

```sh
t3stack hub [--client NAME] [--host ADDR] [--port N]
```

Installs magpie, runs it as a user service (restarts on failure, starts at
boot), binds the gateway to the network and prints the join line. On macOS turn
on *Share on local network* in the app instead. Open the port in the host's
firewall. TLS: `magpie https on`.

## Sync

`t3stack sync [github://owner/repo]` turns on magpie's encrypted sync. It reuses
`gh auth token` and the passphrase magpie already saved, so on a synced machine
it needs no input. The repository must be **private**: magpie refuses to push to
a public one, since its history holds every sealed version.

## Notes

- Release assets are downloaded from `github.com` / `release-assets.githubusercontent.com`,
  not `raw.githubusercontent.com` — that host is blocked on some networks, and
  the CDN in front of it serves stale copies.
- With `--no-install`, only magpie and config are touched; nothing under
  `~/.claude` or `~/.pi` is installed.
- T3 Code is never pointed at the hub directly: its provider instance keeps
  `http://127.0.0.1:3425` and the local magpie forwards.

MIT licensed.
