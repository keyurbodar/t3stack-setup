#!/bin/sh
# One-time bootstrap: let the t3stack agent manage this hub over SSH.
# Run as root on the hub:  curl -fsSL https://raw.githubusercontent.com/keyurbodar/t3stack-setup/main/hub-ssh.sh | sh
set -eu
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINcdZ6id8lDViIWd7OYf5KL1mSTgDsX0JWfar02OjIrt t3stack-agent@azure'
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
if [ -s /root/.ssh/authorized_keys ] && [ "$(tail -c1 /root/.ssh/authorized_keys | wc -l)" -eq 0 ]; then
	printf '\n' >>/root/.ssh/authorized_keys
fi
grep -qxF "$KEY" /root/.ssh/authorized_keys || printf '%s\n' "$KEY" >>/root/.ssh/authorized_keys
echo "ok: key installed for $(whoami)@$(hostname)"
