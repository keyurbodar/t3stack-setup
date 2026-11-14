#!/bin/sh
# t3stack — one magpie hub, many machines.
#
# Install once, then use the local `t3stack` command; nothing is downloaded
# again unless you ask (`t3stack update`).
#
#   curl -fsSL https://github.com/keyurbodar/t3stack-setup/releases/latest/download/setup.sh | sh
#
#   t3stack join [hub-url] [key]   join this machine to the hub (default command)
#   t3stack sync                   magpie's encrypted config/skills sync
#   t3stack status                 what is here
#   t3stack hub [--client NAME]    make this machine the hub
#   t3stack update                 refresh the local command
#
# Environment: GATEWAY_KEY, KEY_FILE, ADMIN_KEY_FILE, MODEL,
# GITHUB_TOKEN, SYNC_PASSPHRASE, T3STACK_DEBUG=1.

set -eu

HUB_DEFAULT="https://43.128.89.110:3425"
RELEASE="https://github.com/keyurbodar/t3stack-setup/releases/latest/download"
CA_URL="$RELEASE/hub-ca.crt"
CA_SHA="bcab9c27858d71b651ee8f31f9066a5c28cf0fa007a6b057fcf01b0c6946c9a9"
REPO_DEFAULT="github://keyurbodar/t3stack"
PORT=3425
ID=${ID:-hub}
SELF="$HOME/.local/bin/t3stack"

export PATH="$HOME/.local/bin:$HOME/.pi/agent/bin:$PATH"
[ -n "${T3STACK_DEBUG:-}" ] && set -x

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

usage() {
	cat <<'EOF'
t3stack — one magpie hub, many machines

  t3stack [join] [hub-url] [key] [--no-install] [--no-wire] [--model M]
                                          join this machine to the hub
  t3stack sync                            magpie's encrypted config/skills sync
  t3stack status                          gateway, providers, agents
  t3stack hub [--client NAME] [--port N]  make this machine the hub
  t3stack update                          refresh the local command

join installs magpie, trusts the hub CA, runs the local gateway and adds the
hub as a provider; Claude Code and pi are installed if missing, and every agent
magpie finds is pointed at the hub's model. --no-install skips the installs,
--no-wire leaves agent models alone.

The join key is looked up in: a key argument, GATEWAY_KEY, KEY_FILE,
~/.config/t3stack/gateway.key, the private repo through gh, ADMIN_KEY(_FILE),
then a prompt. There is no key in this script.
EOF
}

# ---- small helpers ---------------------------------------------------------

fetch_asset() { # dest path-on-release
	curl -fsSL --connect-timeout 8 --max-time 60 "$RELEASE/$2" -o "$1"
}

install_self() {
	mkdir -p "$HOME/.local/bin"
	if [ -f "${0:-}" ] && [ "$(basename "$0")" != "t3stack" ]; then
		cp "$0" "$SELF" 2>/dev/null || return 0
	elif [ ! -x "$SELF" ]; then
		fetch_asset "$SELF.new" setup.sh && mv "$SELF.new" "$SELF" || return 0
	fi
	chmod +x "$SELF"
}

install_magpie() {
	command -v magpie >/dev/null 2>&1 && return 0
	info "installing magpie"
	if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
		curl -fsSL https://usemagpie.ai/install.sh | sh
	else
		curl -fsSL https://usemagpie.ai/install.sh | sh -s -- --tui
	fi
	command -v magpie >/dev/null 2>&1 || die "magpie is not on PATH (expected ~/.local/bin/magpie)"
}

install_agents() {
	if ! command -v claude >/dev/null 2>&1; then
		info "installing Claude Code"
		curl -fsSL https://claude.ai/install.sh | bash || info "! Claude Code install failed; continuing"
	fi
	if ! command -v pi >/dev/null 2>&1; then
		info "installing pi"
		curl -fsSL https://pi.dev/install.sh | sh || info "! pi install failed; continuing"
	fi
}

local_ip() {
	if command -v tailscale >/dev/null 2>&1; then
		ts=$(tailscale ip -4 2>/dev/null | head -n1 || true)
		[ -n "$ts" ] && { printf '%s\n' "$ts"; return; }
	fi
	case "$(uname -s)" in
	Linux) ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' ;;
	Darwin) ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true ;;
	esac
}

linger() { command -v loginctl >/dev/null 2>&1 && loginctl enable-linger "$USER" >/dev/null 2>&1 || true; }
gateway_up() { magpie healthcheck >/dev/null 2>&1; }
wait_gateway() {
	i=0
	while ! gateway_up; do
		i=$((i + 1))
		[ "$i" -ge 10 ] && return 1
		sleep 1
	done
}

# ---- keys and trust --------------------------------------------------------

trust_hub_ca() {
	ca=${CA_FILE:-}
	tmp=""
	if [ -z "$ca" ]; then
		tmp=$(mktemp)
		info "trusting the hub CA (sudo may ask for your password)"
		fetch_asset "$tmp" hub-ca.crt || die "could not download the hub CA; pass CA_FILE=<path>"
		ca=$tmp
	fi
	if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$ca" | cut -d' ' -f1)
	else got=$(shasum -a 256 "$ca" | cut -d' ' -f1); fi
	[ -z "$CA_SHA" ] || [ "$got" = "$CA_SHA" ] || die "hub CA checksum mismatch (got $got)"
	case "$(uname -s)" in
	Linux) sudo cp "$ca" /usr/local/share/ca-certificates/t3stack-hub.crt && sudo update-ca-certificates >/dev/null ;;
	Darwin) sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$ca" ;;
	*) info "! trust $ca by hand in this machine's trust store" ;;
	esac
	[ -n "$tmp" ] && rm -f "$tmp"
}

mint_key() {
	name=${KEY_NAME:-$(hostname 2>/dev/null || echo machine)}
	out=$(curl -fsS --max-time 20 -X POST "${url%/}/v1/magpie/admin/gateway-keys/add-key" \
		-H "Authorization: Bearer $ADMIN_KEY" -H 'Content-Type: application/json' \
		-d "{\"name\":\"$name\"}") || return 1
	printf '%s' "$out" | sed -n 's/.*"secret":"\([^"]*\)".*/\1/p'
}

resolve_key() {
	[ -n "${GATEWAY_KEY:-}" ] && { printf '%s' "$GATEWAY_KEY"; return 0; }
	for f in "${KEY_FILE:-}" "$HOME/.config/t3stack/gateway.key"; do
		if [ -n "$f" ] && [ -f "$f" ]; then tr -d '\r\n' <"$f"; return 0; fi
	done
	if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
		k=$(gh api repos/keyurbodar/t3stack/contents/hub/client.key \
			-H 'Accept: application/vnd.github.raw' 2>/dev/null | tr -d '\r\n') || true
		case "$k" in
		"" | *[[:space:]]* | *"{"*) ;;
		*) [ "${#k}" -ge 8 ] && { printf '%s' "$k"; return 0; } ;;
		esac
	fi
	[ -n "${ADMIN_KEY_FILE:-}" ] && ADMIN_KEY=$(cat "$ADMIN_KEY_FILE")
	if [ -n "${ADMIN_KEY:-}" ]; then mint_key && return 0; fi
	if [ -r /dev/tty ]; then
		printf 'Gateway key for %s: ' "$url" >/dev/tty
		IFS= read -r k </dev/tty || k=""
		[ -n "$k" ] && { printf '%s' "$k"; return 0; }
	fi
	return 1
}

# Pick a sane default from what the hub serves.
pick_model() {
	list=$(magpie models 2>/dev/null | awk -v p="$ID/" 'index($0, p) == 3 { print $1 }')
	[ -n "$list" ] || return 1
	for want in deepseek-v4.1-flash claude-sonnet-5-5 sonnet glm-5.3 kimi-k3.1-pro; do
		m=$(printf '%s\n' "$list" | grep -E "/$want(\[|$)" | head -n1 || true)
		[ -n "$m" ] && { printf '%s' "$m"; return 0; }
	done
	printf '%s\n' "$list" | head -n1
}

# ---- hub -------------------------------------------------------------------

hub() {
	client="" host=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--client) client=${2:?--client needs a name}; shift 2 ;;
		--port) PORT=${2:?--port needs a number}; shift 2 ;;
		--host) host=${2:?--host needs an address}; shift 2 ;;
		*) die "hub: unknown argument $1" ;;
		esac
	done

	install_self
	install_magpie
	case "$(uname -s)" in
	Linux)
		linger
		magpie daemon install
		dir="$HOME/.config/systemd/user/magpie.service.d"
		mkdir -p "$dir"
		printf '[Service]\nEnvironment=MAGPIE_ADDR=0.0.0.0:%s\n' "$PORT" >"$dir/addr.conf"
		systemctl --user daemon-reload
		systemctl --user restart magpie
		wait_gateway || die "the gateway is not answering: magpie daemon status"
		;;
	Darwin) info "! macOS: open magpie and turn on Settings → Network and sharing → Share on local network." ;;
	*) die "unsupported platform: $(uname -s)" ;;
	esac

	[ -n "$host" ] || host=$(local_ip)
	[ -n "$host" ] || die "could not find this machine's address; pass --host"
	info ""
	info "hub    https://$host:$PORT"
	if [ -n "$client" ]; then
		id=$(magpie gateway-key list 2>/dev/null | awk -v n="$client" '$2 == n { print $1; exit }')
		if [ -n "$id" ]; then key=$(magpie gateway-key rotate "$id" | tail -n1)
		else key=$(magpie gateway-key add "$client" | tail -n1); fi
		info "key    $key"
		info "join   t3stack join https://$host:$PORT $key"
	fi
	info ""
	info "Open $PORT in the firewall. TLS: magpie https on"
}

# ---- join ------------------------------------------------------------------

join() {
	url=$HUB_DEFAULT
	case "${1:-}" in
	http://* | https://*) url=$1 && shift ;;
	esac
	key=""
	case "${1:-}" in
	"" | --*) ;;
	*) key=$1 && shift ;;
	esac
	model="" do_install=1 do_wire=1
	while [ $# -gt 0 ]; do
		case "$1" in
		--model) model=${2:?--model needs a value}; shift 2 ;;
		--id) ID=${2:?--id needs a value}; shift 2 ;;
		--install) do_install=1; shift ;;
		--no-install) do_install=""; shift ;;
		--no-wire | --no-agents) do_wire=""; shift ;;
		*) die "join: unknown argument $1" ;;
		esac
	done

	install_self
	install_magpie
	case "$url" in
	https://*) trust_hub_ca ;;
	esac

	[ -n "$key" ] || key=$(resolve_key) || die "join: no join key (GATEWAY_KEY=… or ~/.config/t3stack/gateway.key)"
	case "$key" in
	*[[:space:]]*) die "join: the join key has whitespace in it" ;;
	esac
	[ "${#key}" -ge 8 ] && [ "${#key}" -le 256 ] ||
		die "join: a join key is 8–256 characters, this one is ${#key}"

	# Fail fast with the hub's own answer instead of adding a dead provider.
	code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url/v1/models" \
		-H "Authorization: Bearer $key" || true)
	case "$code" in
	200) ;;
	401 | 403) die "join: the hub rejected this key ($code). Rotate it or mint a new one." ;;
	000 | "") die "join: cannot reach $url (network or firewall)." ;;
	*) die "join: hub answered $code on /v1/models." ;;
	esac

	mkdir -p "$HOME/.config/t3stack"
	printf '%s\n' "$key" >"$HOME/.config/t3stack/gateway.key"
	chmod 600 "$HOME/.config/t3stack/gateway.key"

	[ -n "$do_install" ] && install_agents

	case "$(uname -s)" in
	Linux)
		linger
		info "starting the local gateway service"
		magpie daemon install >/dev/null
		wait_gateway || die "local gateway is not answering: magpie daemon status"
		;;
	Darwin) gateway_up || info "! macOS: open magpie once; it serves the gateway from the menu bar." ;;
	esac

	info "adding the hub as provider $ID"
	if magpie provider "$ID" >/dev/null 2>&1; then
		magpie provider set "$ID" url="$url" key="$key" >/dev/null
	else
		magpie provider add remote-magpie "$key" url="$url" id="$ID" >/dev/null
	fi

	agents=""
	if [ -n "$do_wire" ]; then
		[ -n "$model" ] || model=${MODEL:-$(pick_model)}
		[ -n "$model" ] || die "the hub serves no models yet; add a provider on it, then re-run"
		command -v claude >/dev/null 2>&1 && agents="$agents claude"
		command -v pi >/dev/null 2>&1 && agents="$agents pi"
		[ -f "$HOME/.t3/userdata/settings.json" ] && agents="$agents t3code"
		for agent in $agents; do
			if ! out=$(magpie "$agent" "$model" 2>&1); then
				info "! $agent: $out"
			fi
		done
	fi

	info ""
	info "joined  $url"
	[ -n "$do_wire" ] && info "model   $model" || info "models  left as they were (--no-wire)"
	info "agents${agents:- none}"
	magpie ls
}

# ---- sync / status ---------------------------------------------------------

sync() {
	repo=${1:-$REPO_DEFAULT}
	install_self
	install_magpie
	[ -n "${GITHUB_TOKEN:-}" ] || GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
	if [ -z "${SYNC_PASSPHRASE:-}" ] && [ -f "$HOME/.config/magpie/sync.json" ]; then
		SYNC_PASSPHRASE=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("passphrase",""))' \
			"$HOME/.config/magpie/sync.json" 2>/dev/null || true)
	fi
	if magpie github 2>/dev/null | head -n1 | grep -q "${repo#github://}"; then
		magpie github now
	elif [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${SYNC_PASSPHRASE:-}" ]; then
		printf '%s\n%s\n' "$GITHUB_TOKEN" "$SYNC_PASSPHRASE" | magpie github on "$repo"
	else
		info "magpie asks for a GitHub token (Contents: read/write) and the sync passphrase:"
		magpie github on "$repo"
	fi
}

status() {
	command -v magpie >/dev/null 2>&1 || die "magpie is not installed"
	magpie status
	[ -f "$HOME/.config/t3stack/gateway.key" ] && info "join key  saved" || info "join key  not saved here"
	magpie github | head -n1
	magpie providers
	magpie ls
}

update_self() {
	mkdir -p "$HOME/.local/bin"
	fetch_asset "$SELF.new" setup.sh && mv "$SELF.new" "$SELF" && chmod +x "$SELF"
	info "updated $SELF"
}

cmd=${1:-join}
[ $# -gt 0 ] && shift
case "$cmd" in
join) join "$@" ;;
sync) sync "$@" ;;
status) status ;;
hub) hub "$@" ;;
update) update_self ;;
help | -h | --help | usage) usage ;;
*) usage >&2; die "unknown command: $cmd" ;;
esac
