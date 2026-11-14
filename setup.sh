#!/bin/sh
# t3stack — magpie hub + client setup.
#
# A thin wrapper over magpie's own commands. It keeps no config of its own,
# creates no routing groups, and stores no keys in this repository.
#
#   ./setup.sh hub  [--client NAME] [--port N]    make this machine the shared hub
#                    [--host ADDR] [--tls] [--page]
#   ./setup.sh join [hub-url] [gateway-key]      join a hub (default: HUB_DEFAULT)
#                    [--no-agents] [--model M]   key from gateway.key / private repo / ADMIN_KEY
#                    [--install-agents]          install Claude Code and pi first
#   ./setup.sh sync [github://owner/repo]         keep machines in sync
#   ./setup.sh status                             what is here
#
# Environment:
#   ID=hub                remote provider id on this machine
#   MODEL=<provider/model>  force the model magpie writes into agents
#   AGENTS=claude,pi,t3code  limit which agents get wired
#   ADMIN_KEY=…  /  ADMIN_KEY_FILE=<path>   mint this machine's gateway key
#   GITHUB_TOKEN + SYNC_PASSPHRASE  non-interactive sync

set -eu

REPO_DEFAULT="github://keyurbodar/t3stack"
HUB_DEFAULT="https://43.128.89.110:3425"
PORT=3425
ID=${ID:-hub}

export PATH="$HOME/.local/bin:$HOME/.pi/agent/bin:$PATH"
[ -n "${T3STACK_DEBUG:-}" ] && set -x

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

usage() {
	cat <<'EOF'
t3stack — magpie hub + client setup

  ./setup.sh hub  [--client NAME] [--port N]   make this machine the shared hub
                  [--host ADDR] [--tls] [--page]
  ./setup.sh join [hub-url] [gateway-key]      join a hub (hub defaults to this setup's)
                  [--no-agents] [--install-agents] [--model M]
                                               no key? read from ~/.config/t3stack/
                                               gateway.key or the private repo via gh,
                                               else minted with ADMIN_KEY (or asked)
  ./setup.sh sync [github://owner/repo]        keep machines in sync
  ./setup.sh status                            what is here

The hub serves providers, accounts and groups; every machine still runs its
own magpie so it can wire its own agents. Tokens and passphrases are asked for
by magpie itself, never stored here.
EOF
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

# On Linux a server needs its user services to survive logout.
linger() {
	command -v loginctl >/dev/null 2>&1 && loginctl enable-linger "$USER" >/dev/null 2>&1 || true
}

gateway_up() { magpie healthcheck >/dev/null 2>&1; }

# Wait a moment after starting the service.
wait_gateway() {
	i=0
	while ! gateway_up; do
		i=$((i + 1))
		[ "$i" -ge 10 ] && return 1
		sleep 1
	done
}

hub() {
	client="" host="" tls="" page=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--client) client=${2:?--client needs a name}; shift 2 ;;
		--port) PORT=${2:?--port needs a number}; shift 2 ;;
		--host) host=${2:?--host needs an address}; shift 2 ;;
		--tls) tls=1; shift ;;
		--page) page=1; shift ;;
		*) die "hub: unknown argument $1" ;;
		esac
	done

	install_magpie
	case "$(uname -s)" in
	Linux)
		linger
		magpie daemon install
		# Serve the gateway to the network; the admin page stays on loopback
		# unless --page asks for it.
		dir="$HOME/.config/systemd/user/magpie.service.d"
		mkdir -p "$dir"
		printf '[Service]\nEnvironment=MAGPIE_ADDR=0.0.0.0:%s\n' "$PORT" >"$dir/addr.conf"
		systemctl --user daemon-reload
		systemctl --user restart magpie
		wait_gateway || die "the gateway is not answering: magpie daemon status"
		;;
	Darwin)
		# The menu bar app serves the gateway; sharing is a switch in its window.
		info "! macOS: open magpie and turn on Settings → Network and sharing → Share on local network."
		;;
	*) die "unsupported platform: $(uname -s)" ;;
	esac

	[ -n "$host" ] || host=$(local_ip)
	[ -n "$host" ] || die "could not find this machine's address; pass --host"

	scheme=http
	if [ -n "$tls" ]; then
		magpie https on >/dev/null
		scheme=https
	fi

	info ""
	info "hub    $scheme://$host:$PORT"
	if [ -n "$tls" ]; then
		info "ca     $scheme://$host:$PORT/magpie-ca.crt   (trust it once per client)"
	fi
	if [ -n "$page" ]; then
		out=$(magpie daemon web on --lan 2>&1 || true)
		key=$(printf '%s\n' "$out" | grep -o '\?k=[A-Za-z0-9]*' | head -n1)
		[ -n "$key" ] && info "page   $scheme://$host:3430/$key"
		info "! the page can change magpie and show its keys: keep the link private."
	fi
	if [ -n "$client" ]; then
		id=$(magpie gateway-key list 2>/dev/null | awk -v n="$client" '$2 == n { print $1; exit }')
		if [ -n "$id" ]; then
			key=$(magpie gateway-key rotate "$id" | tail -n1)
		else
			key=$(magpie gateway-key add "$client" | tail -n1)
		fi
		info "key    $key"
		info "join   ./setup.sh join $scheme://$host:$PORT $key"
	else
		info "key    magpie gateway-key add <client name>"
	fi
	info ""
	info "Open $PORT in this machine's firewall; only gateway keys get in."
}

# install_agent_binaries installs Claude Code and pi when they are missing;
# magpie still writes their config afterwards like any other agent.
install_agent_binaries() {
	if ! command -v claude >/dev/null 2>&1; then
		info "installing Claude Code"
		curl -fsSL https://claude.ai/install.sh | bash
	fi
	if ! command -v pi >/dev/null 2>&1; then
		info "installing pi"
		curl -fsSL https://pi.dev/install.sh | sh
	fi
}

# resolve_key finds this machine's gateway key: an explicit one, GATEWAY_KEY,
# a saved file, the private repo through gh, a mint with ADMIN_KEY, or a prompt.
resolve_key() {
	[ -n "${GATEWAY_KEY:-}" ] && { printf '%s' "$GATEWAY_KEY"; return 0; }
	for f in "${KEY_FILE:-}" "$HOME/.config/t3stack/gateway.key"; do
		if [ -n "$f" ] && [ -f "$f" ]; then tr -d '\r\n' <"$f"; return 0; fi
	done
	if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
		k=$(gh api "repos/keyurbodar/t3stack/contents/hub/client.key" \
			-H 'Accept: application/vnd.github.raw' 2>/dev/null | tr -d '\r\n') || true
		case "$k" in
		"" | *[[:space:]]* | *"{"* | *"message"*) ;;
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

join() {
	url=$HUB_DEFAULT
	case "${1:-}" in
	http://* | https://*) url=$1 && shift ;;
	esac
	key=""
	case "${1:-}" in
	"" | --*) ;;
	*) key=$1; shift ;;
	esac
	model="" noagents="" install_agents=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--model) model=${2:?--model needs a value}; shift 2 ;;
		--id) ID=${2:?--id needs a value}; shift 2 ;;
		--no-agents) noagents=1; shift ;;
		--install-agents) install_agents=1; shift ;;
		*) die "join: unknown argument $1" ;;
		esac
	done
	[ "${AGENTS:-}" = none ] && noagents=1

	install_magpie
	[ -n "$install_agents" ] && install_agent_binaries
	# An https hub signs with its own CA; trust it here once, before asking it
	# for anything.
	case "$url" in
	https://*)
		info "trusting the hub CA (sudo may ask for your password)"
		trust_hub_ca
		;;
	esac
	if [ -z "$key" ]; then
		key=$(resolve_key) || die "join: no gateway key (log in with gh, pass one, or set ADMIN_KEY)"
	fi
	case "$key" in
	*[[:space:]]*) die "join: the gateway key has whitespace in it" ;;
	esac
	[ "${#key}" -ge 8 ] && [ "${#key}" -le 256 ] ||
		die "join: a gateway key is 8–256 characters, this one is ${#key}"
	mkdir -p "$HOME/.config/t3stack"
	printf '%s\n' "$key" >"$HOME/.config/t3stack/gateway.key"
	chmod 600 "$HOME/.config/t3stack/gateway.key"
	# This machine's own gateway is what its agents talk to; the hub only
	# supplies the models behind it.
	case "$(uname -s)" in
	Linux)
		linger
		info "starting the local gateway service"
		magpie daemon install >/dev/null
		wait_gateway || die "local gateway is not answering: magpie daemon status"
		;;
	Darwin)
		gateway_up || info "! macOS: open magpie once; it serves the gateway from the menu bar."
		;;
	esac

	info "adding the hub as provider $ID"
	if magpie provider "$ID" >/dev/null 2>&1; then
		magpie provider set "$ID" url="$url" key="$key" >/dev/null
	else
		magpie provider add remote-magpie "$key" url="$url" id="$ID" >/dev/null
	fi

	if [ -z "$noagents" ]; then
		pick_model() { magpie models 2>/dev/null | awk -v p="$ID/" 'index($0, p) == 3 { print $1; exit }'; }
		[ -n "$model" ] || model=${MODEL:-$(pick_model)}
		if [ -z "$model" ]; then
			magpie sync >/dev/null 2>&1 || true
			model=$(pick_model)
		fi
		[ -n "$model" ] || die "no models came from $url — check the URL and the gateway key (magpie provider rm $ID to drop it)"

		agents=${AGENTS:-}
		if [ -z "$agents" ]; then
			command -v claude >/dev/null 2>&1 && agents="$agents claude"
			command -v pi >/dev/null 2>&1 && agents="$agents pi"
			[ -f "$HOME/.t3/userdata/settings.json" ] && agents="$agents t3code"
		fi
		for agent in $agents; do
			magpie "$agent" "$model" >/dev/null
		done
	fi

	info ""
	info "joined $url"
	[ -n "$noagents" ] && info "models  left as they are (--no-agents)" || info "model  ${model:-none}"
	info "agents${agents:- none}"
	magpie ls
}

# mint_key asks the hub for a gateway key named after this machine, using an
# admin key passed in once. KEY_NAME= overrides the name.
mint_key() {
	name=${KEY_NAME:-$(hostname 2>/dev/null || echo machine)}
	out=$(curl -fsS -X POST "${url%/}/v1/magpie/admin/gateway-keys/add-key" \
		-H "Authorization: Bearer $ADMIN_KEY" -H 'Content-Type: application/json' \
		-d "{\"name\":\"$name\"}") || return 1
	printf '%s' "$out" | sed -n 's/.*"secret":"\([^"]*\)".*/\1/p'
}

# fetch_repo_file gets a file from this repo over whichever mirror answers:
# GitHub raw, jsDelivr, then the API. Some networks block raw.githubusercontent.
fetch_repo_file() {
	_dest=$1 _p=$2
	for _u in \
		"https://raw.githubusercontent.com/keyurbodar/t3stack-setup/main/$_p" \
		"https://cdn.jsdelivr.net/gh/keyurbodar/t3stack-setup@main/$_p" \
		"https://api.github.com/repos/keyurbodar/t3stack-setup/contents/$_p"; do
		case "$_u" in
		https://api.github.com/*)
			curl -fsSL --connect-timeout 5 --max-time 20 -H 'Accept: application/vnd.github.raw' "$_u" -o "$_dest" && return 0
			;;
		*)
			curl -fsSL --connect-timeout 5 --max-time 30 "$_u" -o "$_dest" && return 0
			;;
		esac
	done
	return 1
}

# trust_hub_ca puts the hub's CA in this machine's trust store, so magpie and
# curl reach an https:// gateway. CA_FILE= overrides the download.
trust_hub_ca() {
	ca=${CA_FILE:-}
	if [ -z "$ca" ]; then
		ca=$(mktemp)
		fetch_repo_file "$ca" hub-ca.crt ||
			die "could not download the hub CA; pass CA_FILE=<path>"
	fi
	if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$ca" | cut -d' ' -f1)
	else got=$(shasum -a 256 "$ca" | cut -d' ' -f1); fi
	[ "$got" = 'bcab9c27858d71b651ee8f31f9066a5c28cf0fa007a6b057fcf01b0c6946c9a9' ] || die "hub CA checksum mismatch (got $got)"
	case "$(uname -s)" in
	Linux)
		sudo cp "$ca" /usr/local/share/ca-certificates/t3stack-hub.crt
		sudo update-ca-certificates >/dev/null
		;;
	Darwin)
		sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$ca"
		;;
	*) info "! trust $ca by hand in this machine's trust store" ;;
	esac
}

sync() {
	repo=${1:-$REPO_DEFAULT}
	install_magpie
	[ -n "${GITHUB_TOKEN:-}" ] || GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
	if [ -z "${SYNC_PASSPHRASE:-}" ] && [ -f "$HOME/.config/magpie/sync.json" ]; then
		SYNC_PASSPHRASE=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("passphrase",""))' \
			"$HOME/.config/magpie/sync.json" 2>/dev/null || true)
	fi
	if magpie github 2>/dev/null | head -n1 | grep -q "${repo#github://}"; then
		magpie github now
	elif [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${SYNC_PASSPHRASE:-}" ]; then
		# magpie's piped order: token first, passphrase second.
		printf '%s\n%s\n' "$GITHUB_TOKEN" "$SYNC_PASSPHRASE" | magpie github on "$repo"
	else
		info "magpie asks for a token (Contents: read/write) and the sync passphrase:"
		magpie github on "$repo"
	fi
}

status() {
	command -v magpie >/dev/null 2>&1 || die "magpie is not installed"
	magpie status
	magpie github | head -n1
	magpie providers
	magpie ls
}

cmd=${1:-join}
[ $# -gt 0 ] && shift
case "$cmd" in
hub) hub "$@" ;;
join) join "$@" ;;
sync) sync "$@" ;;
status) status ;;
help | -h | --help | usage) usage ;;
*) usage >&2; die "unknown command: $cmd" ;;
esac
