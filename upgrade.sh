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

[[ "${EUID}" -eq 0 ]] || die "upgrade.sh must be run as root"

# shellcheck disable=SC1091
source /etc/os-release

[[ "${ID:-}" == "ubuntu" ]] || die "Ubuntu is required"
[[ "${VERSION_ID:-}" == "24.04" ]] || \
    die "Ubuntu 24.04 is required; found ${VERSION_ID:-unknown}"

log INFO "OS: ${PRETTY_NAME}"
log INFO "Kernel before upgrade: $(uname -r)"

log INFO "Setting apt/dpkg lock timeout."
cat >/etc/apt/apt.conf.d/00-amnezia-lock-timeout <<'APT_LOCK_EOF'
DPkg::Lock::Timeout "300";
APT_LOCK_EOF

# dpkg itself has no lock timeout: wait for a previous apt/dpkg run
# (for example one left over after a dropped SSH session) to finish.
for _ in $(seq 1 60); do
    fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 || break
    sleep 5
done
fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 && \
    die "dpkg lock is still held after 300s"

log INFO "Repairing interrupted dpkg state, if any."
DEBIAN_FRONTEND=noninteractive dpkg --configure -a
log OK "dpkg state is consistent."

log INFO "Running apt-get update."
apt-get update
log OK "apt-get update completed."

log INFO "Running dist-upgrade."
DEBIAN_FRONTEND=noninteractive \
apt-get dist-upgrade -y \
    -o APT::Get::Always-Include-Phased-Updates=true
log OK "dist-upgrade completed."

log INFO "Installing required common packages."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    gnupg2 \
    software-properties-common \
    python3-launchpadlib \
    ufw \
    fail2ban \
    unattended-upgrades \
    iproute2 \
    iptables \
    tcpdump \
    dkms \
    linux-headers-generic \
    "linux-headers-$(uname -r)"
log OK "Required common packages installed."

log INFO "Running apt autoremove and clean."
apt-get autoremove -y
apt-get clean
log OK "Package cleanup completed."

log INFO "Kernel after upgrade: $(uname -r)"

if [[ -f /run/reboot-required ]]; then
    log WARN "REBOOT_REQUIRED"

    if [[ -f /run/reboot-required.pkgs ]]; then
        while IFS= read -r package; do
            [[ -n "$package" ]] && log INFO "Reboot package: $package"
        done </run/reboot-required.pkgs
    fi

    # Special code handled by sync-servers.ps1.
    exit 10
fi

log OK "UPGRADE_OK"
log DONE "Script completed successfully."
