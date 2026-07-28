#!/usr/bin/env bash

set -Eeuo pipefail

LOCAL_IP="192.168.205.254"
REMOTE_IP="192.168.205.254"

HOP_HOST="${1:-}"
SSH_USER="${2:-${USER}}"
IDENTITY_FILE="${3:-}"

PORTS=(
    8000
    80
    8780
    8776
    9292
    9876
    9696
    8774
    8004
    5000
    15672
    6080
    8775
    9311
)

usage() {
    cat <<EOF
Použitie:

  $0 <hop-host> [ssh-user] [identity-file]

Príklady:

  $0 deploy.gt1.ultimum.cloud

  $0 deploy.gt1.ultimum.cloud michal

  $0 deploy.gt1.ultimum.cloud michal ~/.ssh/id_ed25519
EOF
}

if [[ -z "${HOP_HOST}" ]]; then
    usage
    exit 1
fi

if ! command -v ssh >/dev/null 2>&1; then
    echo "Chyba: príkaz ssh nie je nainštalovaný."
    exit 1
fi

if ! command -v ip >/dev/null 2>&1; then
    echo "Chyba: príkaz ip nie je nainštalovaný."
    exit 1
fi

echo "Potrebujem sudo oprávnenie na:"
echo "  - pridanie ${LOCAL_IP}/32 na loopback"
echo "  - otvorenie privilegovaného lokálneho portu 80"
echo

# Ak je sudo bez hesla, pokračuje bez otázky.
# Inak používateľa vyzve na zadanie hesla.
sudo -v

ADDRESS_CREATED=false
KEEPALIVE_PID=""

cleanup() {
    local exit_code=$?

    trap - EXIT INT TERM HUP

    if [[ -n "${KEEPALIVE_PID}" ]]; then
        kill "${KEEPALIVE_PID}" 2>/dev/null || true
    fi

    if [[ "${ADDRESS_CREATED}" == "true" ]]; then
        echo
        echo "Odstraňujem ${LOCAL_IP}/32 z loopback rozhrania..."
        sudo ip address delete "${LOCAL_IP}/32" dev lo 2>/dev/null || true
    fi

    exit "${exit_code}"
}

trap cleanup EXIT INT TERM HUP

# Počas behu tunela udržiava sudo oprávnenie platné.
(
    while true; do
        sudo -n true 2>/dev/null || exit
        sleep 30
    done
) &

KEEPALIVE_PID=$!

if ip address show dev lo | grep -Fq "${LOCAL_IP}/32"; then
    echo "Adresa ${LOCAL_IP}/32 už existuje na loopback rozhraní."
else
    echo "Pridávam ${LOCAL_IP}/32 na loopback rozhranie..."
    sudo ip address add "${LOCAL_IP}/32" dev lo
    ADDRESS_CREATED=true
fi

SSH_OPTIONS=(
    -N
    -T
    -o ExitOnForwardFailure=yes
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
    -o TCPKeepAlive=yes
)

# Použitie SSH konfigurácie a known_hosts aktuálneho používateľa,
# aj keď samotný SSH proces beží cez sudo.
if [[ -f "${HOME}/.ssh/config" ]]; then
    SSH_OPTIONS+=(
        -F "${HOME}/.ssh/config"
    )
fi

SSH_OPTIONS+=(
    -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts"
)

if [[ -n "${IDENTITY_FILE}" ]]; then
    IDENTITY_FILE="$(realpath -e "${IDENTITY_FILE}")"

    if [[ ! -r "${IDENTITY_FILE}" ]]; then
        echo "Chyba: SSH kľúč nie je čitateľný: ${IDENTITY_FILE}"
        exit 1
    fi

    SSH_OPTIONS+=(
        -i "${IDENTITY_FILE}"
        -o IdentitiesOnly=yes
    )
fi

for port in "${PORTS[@]}"; do
    SSH_OPTIONS+=(
        -L "${LOCAL_IP}:${port}:${REMOTE_IP}:${port}"
    )
done

echo
echo "Spúšťam SSH tunely cez ${SSH_USER}@${HOP_HOST}:"
echo

for port in "${PORTS[@]}"; do
    printf '  %-26s -> %s:%s\n' \
        "${LOCAL_IP}:${port}" \
        "${REMOTE_IP}" \
        "${port}"
done

echo
echo "Tunel ukončíš pomocou Ctrl+C."
echo

# SSH musí bežať ako root kvôli bindu na port 80.
# SSH_AUTH_SOCK zachová ssh-agent aktuálneho používateľa.
if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
    sudo --preserve-env=SSH_AUTH_SOCK \
        ssh "${SSH_OPTIONS[@]}" "${SSH_USER}@${HOP_HOST}"
else
    sudo ssh "${SSH_OPTIONS[@]}" "${SSH_USER}@${HOP_HOST}"
fi
