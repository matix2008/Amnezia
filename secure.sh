#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

log()
{
    local level="$1"
    shift
    printf '%s [%s] [%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$SCRIPT_NAME" \
        "$level" \
        "$*"
}

die()
{
    log ERROR "$*" >&2
    exit 1
}

on_error()
{
    local exit_code=$?
    local line_no="$1"
    local command="$2"

    log ERROR "line ${line_no}: ${command} (code ${exit_code})" >&2
    exit "$exit_code"
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

log START "Script started."

[[ "${EUID}" -eq 0 ]] || die "secure.sh must be run as root"
[[ $# -eq 1 ]] || die "Usage: $0 <AWG_PORT>"

AWG_PORT="$1"

if ! [[ "$AWG_PORT" =~ ^[0-9]+$ ]] ||
   (( AWG_PORT < 1 || AWG_PORT > 65535 )); then
    die "Invalid AWG port: $AWG_PORT"
fi

[[ -s /root/.ssh/authorized_keys ]] || \
    die "/root/.ssh/authorized_keys is missing or empty"

log OK "Root authorized_keys exists and is non-empty."

log INFO "Applying SSH key-only hardening."
SSH_DROPIN="/etc/ssh/sshd_config.d/00-amnezia-hardening.conf"

cat >"$SSH_DROPIN" <<'SSH_EOF'
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
SSH_EOF

chmod 644 "$SSH_DROPIN"
sshd -t

EFFECTIVE="$(sshd -T)"

grep -q '^passwordauthentication no$' <<<"$EFFECTIVE" || \
    die "Effective PasswordAuthentication is not 'no'"

grep -q '^kbdinteractiveauthentication no$' <<<"$EFFECTIVE" || \
    die "Effective KbdInteractiveAuthentication is not 'no'"

grep -Eq '^permitrootlogin (prohibit-password|without-password)$' \
    <<<"$EFFECTIVE" || \
    die "Effective PermitRootLogin is incorrect"

systemctl reload ssh
log OK "SSH configuration validated and reloaded."

log INFO "Configuring Fail2Ban for SSH."
cat >/etc/fail2ban/jail.d/sshd.local <<'FAIL2BAN_EOF'
[sshd]
enabled = true
backend = systemd
FAIL2BAN_EOF

systemctl enable --now fail2ban
systemctl restart fail2ban
systemctl is-active --quiet fail2ban
log OK "Fail2Ban is active."

log INFO "Configuring automatic security updates."
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'APT_EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT_EOF

systemctl enable --now apt-daily.timer >/dev/null 2>&1 || true
systemctl enable --now apt-daily-upgrade.timer >/dev/null 2>&1 || true
log OK "Automatic update timers configured."

log INFO "Configuring UFW: deny incoming, allow outgoing, allow SSH and AWG UDP port $AWG_PORT."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow "${AWG_PORT}/udp"
ufw --force enable
ufw reload
log OK "UFW configuration applied."
ufw status | grep -q '^Status: active' || die "UFW is not active after configuration"
ufw status | grep -Eq '(^|[[:space:]])'"${AWG_PORT}"'/udp([[:space:]]|$)' || \
    die "UFW rule for ${AWG_PORT}/udp was not found after configuration"
log OK "UFW active state and AWG UDP rule verified."

# UFW reload may rebuild filter rules.
log INFO "Restarting awg-iptables.service after UFW reload."
systemctl restart awg-iptables.service

log INFO "Verifying final security state."
ufw status

systemctl is-active --quiet fail2ban
systemctl is-active --quiet awg-iptables.service
systemctl is-active --quiet awg-quick@awg0.service

log OK "Fail2Ban, awg-iptables and awg0 services are active."
log OK "SECURE_OK"
log DONE "Script completed successfully."
