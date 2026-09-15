#!/usr/bin/env bash

set -Eeuo pipefail

SSH_USER="ultimum"
SSH_HOST="10.128.5.80"
REMOTE_HOST="172.28.17.5"

SSH_PID=""

cleanup() {
    echo
    echo "Stopping SSH tunnels..."

    if [[ -n "${SSH_PID}" ]] && kill -0 "${SSH_PID}" 2>/dev/null; then
        kill "${SSH_PID}" 2>/dev/null || true
        wait "${SSH_PID}" 2>/dev/null || true
    fi

    echo "SSH tunnels stopped."
}

trap cleanup EXIT INT TERM HUP

echo "Starting SSH tunnels via ${SSH_USER}@${SSH_HOST}..."

ssh \
    -N \
    -T \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o ControlMaster=no \
    -L 127.0.0.1:3000:${REMOTE_HOST}:3000 \
    -L 127.0.0.1:15672:${REMOTE_HOST}:15672 \
    -L 127.0.0.1:1984:${REMOTE_HOST}:1984 \
    -L 127.0.0.1:9091:${REMOTE_HOST}:9091 \
    -L 127.0.0.1:9093:${REMOTE_HOST}:9093 \
    -L 127.0.0.1:8500:${REMOTE_HOST}:8500 \
    -L 127.0.0.1:6900:${REMOTE_HOST}:6900 \
    "${SSH_USER}@${SSH_HOST}" &

SSH_PID=$!

sleep 1

if ! kill -0 "${SSH_PID}" 2>/dev/null; then
    echo "ERROR: SSH tunnel failed to start."
    wait "${SSH_PID}" || true
    exit 1
fi

echo
echo "Tunnels active:"
echo
printf '  %-25s -> %s\n' \
    "Grafana"              "http://api-int.os-prod.int.g2server.com:3000" \
    "RabbitMQ Management"  "http://api-int.os-prod.int.g2server.com:15672" \
    "HAProxy Stats"        "http://api-int.os-prod.int.g2server.com:1984" \
    "Prometheus"           "http://api-int.os-prod.int.g2server.com:9091" \
    "Alertmanager"         "http://api-int.os-prod.int.g2server.com:9093" \
    "Consul UI"            "http://api-int.os-prod.int.g2server.com:8500" \
    "ProxySQL UI"          "https://api-int.os-prod.int.g2server.com:6900"

echo
echo "SSH hop: ${SSH_USER}@${SSH_HOST}"
echo "Remote:  ${REMOTE_HOST}"
echo
echo "Press Ctrl+C to stop all tunnels."
echo

wait "${SSH_PID}"
