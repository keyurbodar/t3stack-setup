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
#   t3stack dotfiles [pull|save]   merge/save dotfile fragments for Claude, pi, T3
#   t3stack deps                   install curl, gh, htop, fastfetch, node, bun
#   t3stack github [token|--token-file F]  store a GitHub token for this machine
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

export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.pi/agent/bin:$PATH"
# A stored token makes gh, git and the private-repo clone work with no login.
GH_TOKEN_FILE="$HOME/.config/t3stack/github.token"
if [ -z "${GH_TOKEN:-}" ] && [ -f "$GH_TOKEN_FILE" ]; then
	GH_TOKEN=$(tr -d '\r\n' <"$GH_TOKEN_FILE")
	export GH_TOKEN
fi
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
  t3stack deps                            install curl, gh, htop, fastfetch, node, bun
  t3stack github [token]                  store a GitHub token (no gh login/OTP again)
  t3stack dotfiles pull                   merge shared Claude/pi/T3 settings here
  t3stack dotfiles save [message]         capture this machine's extra keys, commit, push
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

# fetch_asset gets a file fresh: the API first (no CDN in front of it, so a
# just-published change is there at once), then the release asset.
fetch_asset() { # dest path-in-repo
	if curl -fsSL --connect-timeout 8 --max-time 30 \
		-H 'Accept: application/vnd.github.raw' \
		"https://api.github.com/repos/keyurbodar/t3stack-setup/contents/$2?x=$(date +%s)" -o "$1" 2>/dev/null; then
		return 0
	fi
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

# The backup repo's token travels encrypted with the join key, so a machine
# that has joined can sync without anyone typing a token.
decrypt_github_token() {
	jk=""
	for f in "${KEY_FILE:-}" "$HOME/.config/t3stack/gateway.key"; do
		if [ -n "$f" ] && [ -f "$f" ]; then jk=$(tr -d '\r\n' <"$f"); break; fi
	done
	[ -n "$jk" ] || return 1
	command -v openssl >/dev/null 2>&1 || return 1
	tmp=$(mktemp)
	if ! fetch_asset "$tmp" hub/github.token.enc 2>/dev/null; then
		rm -f "$tmp"
		return 1
	fi
	out=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -base64 -pass "pass:$jk" -in "$tmp" 2>/dev/null) || out=""
	rm -f "$tmp"
	[ -n "$out" ] && printf '%s' "$out"
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

# A timer that refreshes model lists even if magpie's own tick is stale; it
# also writes the new list into the agents (T3, Claude Code, pi).
install_timer() {
	[ "$(uname -s)" = "Linux" ] || return 0
	command -v systemctl >/dev/null 2>&1 || return 0
	bin=$(command -v magpie 2>/dev/null) || return 0
	dir="$HOME/.config/systemd/user"
	mkdir -p "$dir"
	changed=""
	cat >"$dir/t3stack-models.service.new" <<EOF
[Unit]
Description=Refresh magpie model lists and shared dotfiles
[Service]
Type=oneshot
ExecStart=/bin/sh -c '$SELF update >/dev/null 2>&1 || true; $bin sync; $SELF dotfiles pull'
EOF
	cat >"$dir/t3stack-models.timer.new" <<EOF
[Unit]
Description=Refresh magpie model lists every 10 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Unit=t3stack-models.service
[Install]
WantedBy=timers.target
EOF
	for f in t3stack-models.service t3stack-models.timer; do
		if cmp -s "$dir/$f.new" "$dir/$f"; then
			rm -f "$dir/$f.new"
		else
			mv "$dir/$f.new" "$dir/$f"
			changed=1
		fi
	done
	if [ -n "$changed" ]; then
		systemctl --user daemon-reload >/dev/null 2>&1 || return 0
		systemctl --user enable --now t3stack-models.timer >/dev/null 2>&1 || true
	fi
}

# ---- dependencies -----------------------------------------------------------
pkg_install() {
	if command -v apt-get >/dev/null 2>&1; then
		sudo apt-get update -qq >/dev/null 2>&1 || true
		sudo apt-get install -y "$@" >/dev/null 2>&1 || info "! could not install: $*"
	elif command -v dnf >/dev/null 2>&1; then
		sudo dnf install -y "$@" >/dev/null 2>&1 || info "! could not install: $*"
	elif command -v pacman >/dev/null 2>&1; then
		sudo pacman -S --needed --noconfirm "$@" >/dev/null 2>&1 || info "! could not install: $*"
	elif command -v brew >/dev/null 2>&1; then
		brew install "$@" >/dev/null 2>&1 || info "! could not install: $*"
	else
		info "! install by hand: $*"
	fi
}

install_node() {
	command -v node >/dev/null 2>&1 && return 0
	case "$(uname -m)" in
	x86_64 | amd64) a=x64 ;;
	aarch64 | arm64) a=arm64 ;;
	*) pkg_install nodejs && return 0 ;;
	esac
	if [ "$(uname -s)" = "Darwin" ]; then
		pkg_install node
		return 0
	fi
	command -v python3 >/dev/null 2>&1 || { pkg_install nodejs; return 0; }
	info "installing node"
	ver=$(curl -fsSL --max-time 20 https://nodejs.org/dist/index.json |
		python3 -c 'import json,sys;v=[x["version"] for x in json.load(sys.stdin) if x.get("lts")];print(v[0].lstrip("v"))' 2>/dev/null) || return 0
	tmp=$(mktemp -d)
	curl -fsSL --max-time 180 "https://nodejs.org/dist/v$ver/node-v$ver-linux-$a.tar.gz" -o "$tmp/n.tar.gz" || { rm -rf "$tmp"; return 0; }
	mkdir -p "$HOME/.local/node"
	tar -xzf "$tmp/n.tar.gz" -C "$HOME/.local/node" --strip-components=1
	for b in node npm npx; do
		ln -sfn "$HOME/.local/node/bin/$b" "$HOME/.local/bin/$b"
	done
	rm -rf "$tmp"
}

install_bun() {
	command -v bun >/dev/null 2>&1 && return 0
	info "installing bun"
	curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 || info "! bun install failed"
}

install_deps() {
	command -v curl >/dev/null 2>&1 || pkg_install curl
	install_gh
	command -v htop >/dev/null 2>&1 || pkg_install htop
	if ! command -v fastfetch >/dev/null 2>&1 && ! command -v neofetch >/dev/null 2>&1; then
		pkg_install fastfetch
		command -v fastfetch >/dev/null 2>&1 || pkg_install neofetch
	fi
	install_node
	install_bun
}

# ---- dotfiles --------------------------------------------------------------
# Only the keys magpie does not own are shared; magpie's keys are stripped from
# the fragment on the way in and out, so the two never fight.
DF_REPO="$HOME/.local/share/t3stack-setup"
DF_URL="https://github.com/keyurbodar/t3stack-setup.git"
DF_CLAUDE="$HOME/.claude/settings.json"
DF_PI="$HOME/.pi/agent/settings.json"
DF_T3="$HOME/.t3/userdata/settings.json"
DF_PROTECT_CLAUDE='model,modelPicker,env.ANTHROPIC_*,env.ANTHROPIC_AUTH_TOKEN,env.ANTHROPIC_DEFAULT_HAIKU_MODEL,env.ANTHROPIC_DEFAULT_SONNET_MODEL,env.ANTHROPIC_DEFAULT_OPUS_MODEL,env.ANTHROPIC_SMALL_FAST_MODEL,env.CLAUDE_CODE_MODEL_CAPABILITIES,env.ENABLE_TOOL_SEARCH,env.CLAUDE_CODE_AUTO_MODE_SERVER,env.CLAUDE_CODE_AUTO_COMPACT_WINDOW,env.CLAUDE_CODE_MAX_OUTPUT_TOKENS'
DF_PROTECT_PI='defaultProvider,defaultModel,lastChangelogVersion'
DF_PROTECT_T3='providerInstances'

df_repo() {
	command -v git >/dev/null 2>&1 || die "dotfiles: git is not installed"
	if [ -d "$DF_REPO/.git" ]; then
		git -C "$DF_REPO" pull --ff-only -q 2>/dev/null || info "! dotfiles: pull failed (network)"
	else
		mkdir -p "$(dirname "$DF_REPO")"
		git clone -q "$DF_URL" "$DF_REPO" 2>/dev/null ||
			die "dotfiles: cannot clone $DF_URL"
	fi
}

# df_json <merge|save> <local-file> <fragment-file> <protected-paths>
df_json() {
	command -v python3 >/dev/null 2>&1 || die "dotfiles: python3 is not installed"
	python3 - "$@" <<'PYEOF'
import json, sys
mode, local_p, frag_p, protected = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
prot = [p for p in protected.split(",") if p]

def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}

def drop(d, path):
    cur = d
    parts = path.split(".")
    for p in parts[:-1]:
        if not isinstance(cur, dict) or p not in cur:
            return
        cur = cur[p]
    if not isinstance(cur, dict):
        return
    last = parts[-1]
    if last.endswith("*"):
        for k in [k for k in cur if k.startswith(last[:-1])]:
            del cur[k]
    else:
        cur.pop(last, None)

def prune(d):
    if isinstance(d, dict):
        for k in [k for k, v in d.items() if isinstance(v, dict) and not v]:
            del d[k]
        for v in d.values():
            prune(v)
    return d

def merge(a, b):
    if isinstance(a, dict) and isinstance(b, dict):
        out = dict(a)
        for k, v in b.items():
            out[k] = merge(a[k], v) if k in a else v
        return out
    return b

local = load(local_p)
if not isinstance(local, dict):
    sys.exit(0)

if mode == "save":
    frag = json.loads(json.dumps(local))
    for p in prot:
        drop(frag, p)
    prune(frag)
    with open(frag_p, "w") as f:
        json.dump(frag, f, indent=2, sort_keys=True)
        f.write("\n")
    sys.exit(0)

frag = load(frag_p)
for p in prot:
    drop(frag, p)
merged = merge(local, frag)
if merged == local:
    sys.exit(0)
with open(local_p + ".bak", "w") as f:
    json.dump(local, f, indent=2, sort_keys=True)
    f.write("\n")
with open(local_p, "w") as f:
    json.dump(merged, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"updated {local_p}")
PYEOF
}

df_each() { # <merge|save>
	for pair in "claude:$DF_CLAUDE:$DF_PROTECT_CLAUDE" "pi:$DF_PI:$DF_PROTECT_PI" "t3:$DF_T3:$DF_PROTECT_T3"; do
		name=${pair%%:*}
		rest=${pair#*:}
		file=${rest%%:*}
		prot=${rest#*:}
		[ -f "$file" ] || continue
		mkdir -p "$DF_REPO/dotfiles"
		df_json "$1" "$file" "$DF_REPO/dotfiles/$name.json" "$prot"
	done
}

dotfiles() {
	action=${1:-pull}
	case "$action" in
	pull)
		df_repo
		df_each merge
		;;
	save)
		shift
		msg=${1:-dotfiles: update from $(hostname 2>/dev/null || echo machine)}
		df_repo
		df_each save
		# The fragments live in a public repo: refuse to publish anything that
		# looks like a credential, unless --force is given.
		if [ "${1:-}" != "--force" ] && ! python3 - "$DF_REPO/dotfiles" <<'PYEOF'
import json, os, re, sys
pat = re.compile(r"(sk-|sk_|ghp_|github_pat_|xox[bap]-|AKIA|[A-Za-z0-9_\-]{40,})")
bad = []
d = sys.argv[1]
for name in os.listdir(d) if os.path.isdir(d) else []:
    p = os.path.join(d, name)
    if not name.endswith(".json"):
        continue
    try:
        data = json.load(open(p))
    except Exception:
        continue
    def walk(o, path=""):
        if isinstance(o, dict):
            for k, v in o.items():
                if any(w in k.lower() for w in ("token", "secret", "password", "apikey", "api_key")):
                    bad.append(f"{name}:{path}{k}")
                walk(v, f"{path}{k}.")
        elif isinstance(o, list):
            for i, v in enumerate(o):
                walk(v, f"{path}{i}.")
        elif isinstance(o, str) and pat.search(o):
            bad.append(f"{name}:{path.rstrip('.')}")
    walk(data)
if bad:
    print("refusing to publish: " + ", ".join(bad))
    sys.exit(1)
PYEOF
		then
			info "! dotfiles: looks like a credential above; fix it or rerun with --force"
			return 1
		fi
		git -C "$DF_REPO" add dotfiles >/dev/null 2>&1
		if git -C "$DF_REPO" diff --cached --quiet 2>/dev/null; then
			info "dotfiles: nothing to save"
		else
			git -C "$DF_REPO" commit -q -m "$msg"
			git -C "$DF_REPO" pull --rebase -q 2>/dev/null || true
			git -C "$DF_REPO" push -q 2>/dev/null || info "! dotfiles: push failed (auth?)"
			info "dotfiles: saved and pushed"
		fi
		;;
	status)
		[ -d "$DF_REPO/.git" ] || { info "dotfiles: no local repo ($DF_REPO)"; return 0; }
		git -C "$DF_REPO" log --oneline -1
		git -C "$DF_REPO" status --short | head -20
		;;
	*) die "dotfiles: pull | save [message] | status" ;;
	esac
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
	install_deps
	# A GH_TOKEN from the bootstrap is stored here, so dotfiles and the private
	# repo work afterwards with no login.
	if [ -n "${GH_TOKEN:-}" ] && [ ! -f "$GH_TOKEN_FILE" ]; then
		github_cmd >/dev/null 2>&1 || true
	fi
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
		install_timer
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
	install_timer
	[ -n "${GITHUB_TOKEN:-}" ] || GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
	[ -n "${GITHUB_TOKEN:-}" ] || GITHUB_TOKEN=$(decrypt_github_token || true)
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
	if ! fetch_asset "$SELF.new" setup.sh; then
		rm -f "$SELF.new"
		die "t3stack update: could not download the release asset"
	fi
	if [ -x "$SELF" ] && cmp -s "$SELF.new" "$SELF"; then
		rm -f "$SELF.new"
		info "t3stack is current"
		return 0
	fi
	mv "$SELF.new" "$SELF"
	chmod +x "$SELF"
	install_timer
	info "updated $SELF"
}

cmd=${1:-join}
[ $# -gt 0 ] && shift
case "$cmd" in
join) join "$@" ;;
dotfiles) dotfiles "$@" ;;
github) github_cmd "$@" ;;
deps) install_deps; info "deps: curl gh htop fastfetch/neofetch node bun" ;;
sync) sync "$@" ;;
status) status ;;
hub) hub "$@" ;;
update) update_self ;;
help | -h | --help | usage) usage ;;
*) usage >&2; die "unknown command: $cmd" ;;
esac
