# t3stack-setup

One magpie, many machines — no VPN required. A small shell wrapper over
[magpie](https://usemagpie.ai)'s own commands: one hub that serves models, and
clients that join it.

- No config files of its own, no routing groups, no secrets in this repository.
- A client keeps its gateway on `127.0.0.1:3425`; agents (Claude Code, Pi,
  T3 Code, …) never talk to the hub directly.
- The hub's admin page stays on loopback unless you explicitly ask for it.

## Hub

```sh
curl -fsSL https://raw.githubusercontent.com/keyurbodar/t3stack-setup/main/setup.sh \
  | sh -s -- hub --host 203.0.113.7 --client laptop
```

It installs magpie, runs it as a user service, binds the gateway to the network
and prints a key plus the join line. `--host` is the address clients dial
(public IP, DNS name, Tailscale IP — whatever `nslookup`/`curl` reaches).

Flags:

| Flag | What |
| --- | --- |
| `--host ADDR` | address clients use (default: this machine's) |
| `--port N` | gateway port (default 3425) |
| `--client NAME` | make/rotate a gateway key for that client, print the join line |
| `--tls` | `magpie https on`: serve `https://` with magpie's own CA |
| `--page` | also expose the web page (port 3430, `?k=` link) |

The hub's own magpie keeps serving its local agents over `http://127.0.0.1`.
Only port `3425` needs to be reachable; remote callers must present an enabled
gateway key. Open that port in the machine's firewall.

## Clients

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/keyurbodar/t3stack-setup@main/setup.sh \
  | sh -s -- join <short-key>
```

or run `sh setup.sh join` and paste the key at the prompt. Nothing else: it
installs magpie, trusts the hub CA, runs the local gateway and adds the hub as a
provider. Add `--install-agents` to install Claude Code and pi first.

There is no key in this repository. The join key is short and private — kept in
the password manager, or in the private repo where `gh auth login` lets `join`
find it silently (`GATEWAY_KEY=…` and `~/.config/t3stack/gateway.key` work too).

## Sync

`./setup.sh sync [github://owner/repo]` turns on magpie's encrypted sync. It
reuses `gh auth token` and the passphrase magpie already saved, so on a synced
machine it needs no input. The repository must be **private**: magpie refuses
to push to a public one, since its history holds every sealed version.

The shared client key in this repo (`hub/client.key`, private) means one key
is used by every machine that joins this way. Rotate it with
`magpie gateway-key rotate <id>` on the hub and update that file; machines
already joined keep working with the key they saved.

## Notes

- With `--tls`, each client trusts the hub's CA once:
  `curl -k -O https://<hub>:3425/magpie-ca.crt`, then
  `sudo cp magpie-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates` (Debian),
  `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain magpie-ca.crt` (macOS),
  `certutil -addstore -f Root magpie-ca.crt` (Windows, as administrator).
- `--page` is the old `http://<hub>:3430/?k=…` convenience. That link can
  change magpie and see its keys — keep it private, and prefer not to expose it
  on the open internet.
- `hub --tls` plus `magpie mtls on` (client certificates) is the hardened
  variant if the hub has to live on a public IP.

MIT licensed.
