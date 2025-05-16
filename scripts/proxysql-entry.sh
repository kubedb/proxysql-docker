#!/bin/bash
set -e

# Grab the script name for logging
script_name=${0##*/}

# pid stores the process id of the proxysql process
declare -i pid

if [ $FRONTEND_TLS_ENABLED == "true" ]; then
    cp /var/lib/frontend/server/ca.crt /var/lib/proxysql/proxysql-ca.pem
    cp /var/lib/frontend/server/tls.crt /var/lib/proxysql/proxysql-cert.pem
    cp /var/lib/frontend/server/tls.key /var/lib/proxysql/proxysql-key.pem
fi

function timestamp() {
    date +"%Y/%m/%d %T"
}

function log() {
    local log_type="$1"
    local msg="$2"
    echo "$(timestamp) [$script_name] [$log_type] $msg"
}

# If command has arguments, prepend proxysql
if [ "${1:0:1}" = '-' ]; then
    CMDARG="$@"
fi


log "INFO" "Starting ProxySQL with configuration....."
nl -ba /etc/custom-config/proxysql.cnf

# Start ProxySQL with PID 1
exec proxysql -c /etc/custom-config/proxysql.cnf -f $CMDARG &
pid=$!

log "INFO" "Running post-startup configuration script..."
/scripts/configure-proxysql.sh

log "INFO" "Waiting for ProxySQL (pid=$pid)..."
wait $pid
