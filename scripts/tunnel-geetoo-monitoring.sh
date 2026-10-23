#!/usr/bin/env bash
#
# Expose Grafana, Prometheus and Alertmanager running on 172.28.17.5
# (reachable only from the jump host) on this machine, so they can be opened
# in a browser as http://api-int.os-prod.int.g2server.com:<port>.
#
# How it works:
#   - one SSH connection to the jump host with local port forwards
#     127.0.0.1:<port> -> 172.28.17.5:<port>
#   - /etc/hosts entry  127.0.0.1  api-int.os-prod.int.g2server.com
#     (forwarding is plain TCP, so Host header / TLS SNI stay intact)
#   - if the route to the jump host does not go through the VPN (e.g. a
#     local/docker network shadows it), a /32 host route via VPN_GW is added
#     (set VPN_GW= to disable this check)
#
# Usage: ./monitoring-tunnel.sh {start|stop|restart|status}
set -euo pipefail
JUMP_HOST="${JUMP_HOST:-osm-00010424.int.g2server.com}"
JUMP_USER="${JUMP_USER:-ultimum}"
TARGET_IP="${TARGET_IP:-172.28.17.5}"
DOMAIN="${DOMAIN:-api-int.os-prod.int.g2server.com}"
BIND_ADDR="127.0.0.1"
VPN_GW="${VPN_GW-172.29.255.1}"
# name:port
SERVICES=(
    "grafana:3000"
    "prometheus:9091"
    "alertmanager:9093"
    "haproxy-stats:1984"
)
CONTROL_SOCKET="${XDG_RUNTIME_DIR:-/tmp}/monitoring-tunnel-${JUMP_USER}@${JUMP_HOST}.sock"
HOSTS_FILE="/etc/hosts"
HOSTS_MARKER="# monitoring-tunnel"
ROUTE_STATE="${XDG_RUNTIME_DIR:-/tmp}/monitoring-tunnel-route"
log()  { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }
is_running() {
    [[ -S "$CONTROL_SOCKET" ]] && \
        ssh -S "$CONTROL_SOCKET" -O check "${JUMP_USER}@${JUMP_HOST}" >/dev/null 2>&1
}
port_in_use() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .
    else
        (exec 3<>"/dev/tcp/${BIND_ADDR}/${port}") 2>/dev/null
    fi
}
ensure_hosts_entry() {
    if grep -Eq "^[[:space:]]*${BIND_ADDR//./\\.}[[:space:]].*\b${DOMAIN//./\\.}\b" "$HOSTS_FILE"; then
        return
    fi
    if grep -Eq "^[^#]*\b${DOMAIN//./\\.}\b" "$HOSTS_FILE"; then
        warn "$HOSTS_FILE already maps ${DOMAIN} to a different address, fix it manually:"
        grep -En "\b${DOMAIN//./\\.}\b" "$HOSTS_FILE" >&2
        return
    fi
    log "Adding '${BIND_ADDR} ${DOMAIN}' to ${HOSTS_FILE} (sudo)"
    echo "${BIND_ADDR} ${DOMAIN} ${HOSTS_MARKER}" | sudo tee -a "$HOSTS_FILE" >/dev/null
}
remove_hosts_entry() {
    if grep -q "${HOSTS_MARKER}\$" "$HOSTS_FILE"; then
        log "Removing ${DOMAIN} entry from ${HOSTS_FILE} (sudo)"
        sudo sed -i "/${HOSTS_MARKER}\$/d" "$HOSTS_FILE"
    fi
}
# Interface on which VPN_GW is directly reachable (i.e. the VPN interface).
vpn_dev() {
    local r
    r=$(ip -o -4 route get "$VPN_GW" 2>/dev/null) || return 1
    [[ $r != *" via "* ]] || return 1
    sed -n 's/.* dev \([^ ]*\).*/\1/p' <<<"$r"
}
ensure_route() {
    [[ -n $VPN_GW ]] || return 0
    local ip dev cur
    ip=$(getent ahostsv4 "$JUMP_HOST" | awk 'NR==1 {print $1}')
    [[ -n $ip ]] || die "Cannot resolve ${JUMP_HOST}."
    dev=$(vpn_dev) || die "VPN is not connected (${VPN_GW} is not directly reachable). Connect to VPN first."
    cur=$(ip -o -4 route get "$ip" 2>/dev/null || true)
    [[ $cur =~ " dev ${dev}"( |$) ]] && return
    warn "Route to ${JUMP_HOST} (${ip}) does not go through VPN (${dev}): ${cur:-none}"
    log "Adding route ${ip}/32 via ${VPN_GW} dev ${dev} (sudo)"
    sudo ip route replace "${ip}/32" via "$VPN_GW" dev "$dev"
    echo "${ip}/32" >"$ROUTE_STATE"
}
remove_route() {
    [[ -f $ROUTE_STATE ]] || return 0
    local net
    net=$(<"$ROUTE_STATE")
    log "Removing route ${net} (sudo)"
    sudo ip route del "$net" 2>/dev/null || true
    rm -f "$ROUTE_STATE"
}
print_urls() {
    local svc name port
    for svc in "${SERVICES[@]}"; do
        name=${svc%%:*}
        port=${svc##*:}
        printf '    %-13s http://%s:%s\n' "$name" "$DOMAIN" "$port"
    done
}
start() {
    if is_running; then
        log "Tunnel is already running."
        print_urls
        return
    fi
    local forwards=() svc port
    for svc in "${SERVICES[@]}"; do
        port=${svc##*:}
        port_in_use "$port" && die "Local port ${port} is already in use."
        forwards+=(-L "${BIND_ADDR}:${port}:${TARGET_IP}:${port}")
    done
    ensure_route
    ensure_hosts_entry
    log "Opening tunnel via ${JUMP_USER}@${JUMP_HOST} -> ${TARGET_IP}"
    ssh -f -N -M -S "$CONTROL_SOCKET" \
        -o ExitOnForwardFailure=yes \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        "${forwards[@]}" \
        "${JUMP_USER}@${JUMP_HOST}" \
        || die "SSH connection to ${JUMP_USER}@${JUMP_HOST} failed."
    log "Tunnel is up. Open in browser:"
    print_urls
}
stop() {
    if is_running; then
        log "Closing tunnel"
        ssh -S "$CONTROL_SOCKET" -O exit "${JUMP_USER}@${JUMP_HOST}" 2>/dev/null || true
    else
        log "Tunnel is not running."
    fi
    rm -f "$CONTROL_SOCKET"
    if [[ "${KEEP_HOSTS:-0}" != 1 ]]; then
        remove_hosts_entry
        remove_route
    fi
}
status() {
    if is_running; then
        log "Tunnel is running (socket: ${CONTROL_SOCKET})"
        print_urls
    else
        log "Tunnel is not running."
        return 1
    fi
}
case "${1:-}" in
    start)   start ;;
    stop)    stop ;;
    restart) KEEP_HOSTS=1 stop; start ;;
    status)  status ;;
    *)       echo "Usage: $0 {start|stop|restart|status}" >&2; exit 2 ;;
esac

