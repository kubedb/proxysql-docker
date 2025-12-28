#!/bin/bash

# use the current scrip name while putting log
script_name=${0##*/}

# used env var from container
# LOAD_BALANCE_MODE - value is either "Galera" or "GroupReplication"
# PROXYSQL_VERSION - e.g., "2.7.3-debian", "2.3.2-debian", etc.

function timestamp() {
    date +"%Y/%m/%d %T"
}

function log() {
    local log_type="$1"
    local msg="$2"
    echo "$(timestamp) [$script_name] [$log_type] $msg"
}

log "" "From $script_name"

# Configs
opt=" -vvv -f " # Verbose and force for mysql exec on schema changes
TIMEOUT="10"    # 10 sec timeout to wait for server

# Functions

function mysql_exec() {
    local user="$1"
    local pass="$2"
    local server="$3"
    local port="$4"
    local query="$5"
    local exec_opt="$6"
    pass_ssl=""
    if [ $BACKEND_TLS_ENABLED == "true" ]; then
        if [ $port == 3306 ]; then
            pass_ssl="--ssl-ca=/var/lib/certs/ca.crt"
        fi
    fi
    mysql $exec_opt ${pass_ssl} --user=${user} --password=${pass} --host=${server} -P${port} -NBe "${query}"
}

function proxysql_admin_exec() {
    local query="$1"
    local exec_opt="$2" # Additional options like -vvve
    # Capture stderr
    error_output=$(mysql ${exec_opt} --user=admin --password=admin --host=127.0.0.1 -P6032 -NBe "${query}" 2>&1)
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log "ERROR" "proxysql_admin_exec failed. Exit code: $exit_code. Error: $error_output. Query: $query"
    fi
    echo "$error_output"
}

function wait_for_mysql() {
    local user="$1"
    local pass="$2"
    local server="$3"
    local port="$4"

    log "INFO" "Waiting for host $server:$port to be online ..."
    for i in {900..0}; do
        out=$(mysql_exec ${user} ${pass} ${server} ${port} "select 1;")
        if [[ "$out" == "1" ]]; then
            break
        fi

        log "WARNING" "out is ---'$out'--- MySQL is not up yet ... sleeping ..."
        sleep 1
    done

    if [[ "$i" == "0" ]]; then
        log "ERROR" "Server ${server} start failed ..."
        exit 1
    fi
}

# Function to compare semantic versions (basic X.Y.Z comparison)
# Extracts the core X.Y.Z part from versions like X.Y.Z-suffix
# Returns 0 if version1 >= version2, 1 otherwise
version_ge() {
    # Extract core version part (X.Y.Z)
    local core_v1=$(echo "$1" | awk -F'-' '{print $1}')
    local core_v2=$(echo "$2" | awk -F'-' '{print $1}')

    # Check if core versions are identical
    if [ "$core_v1" = "$core_v2" ]; then
        return 0
    fi

    # Compare using sort -V which handles version numbers correctly
    if [ "$(printf "%s\n%s" "$core_v1" "$core_v2" | sort -V | head -n1)" = "$core_v2" ]; then
        # This means core_v2 is smaller or equal, so core_v1 is greater or equal
        return 0
    else
        return 1
    fi
}

# --- Main Script Logic ---

wait_for_mysql $BACKEND_AUTH_USERNAME $BACKEND_AUTH_PASSWORD $BACKEND_SERVER 3306

additional_sys_query=$(cat /sql/addition_to_sys_v5.sql)
if [[ $MYSQL_VERSION == "8"* || $MYSQL_VERSION == "9"* ]]; then
    log "INFO" "Applying MySQL 8+ sys schema additions..."
    additional_sys_query=$(cat /sql/addition_to_sys_v8.sql)
else
    log "INFO" "Applying MySQL 5.x sys schema additions..."
fi
mysql_exec $BACKEND_AUTH_USERNAME $BACKEND_AUTH_PASSWORD $BACKEND_SERVER 3306 "$additional_sys_query" $opt

# wait for proxysql process to run and be accessible
wait_for_mysql admin admin 127.0.0.1 6032

# Set default authentication plugin based on PROXYSQL_VERSION
if [ -z "$PROXYSQL_VERSION" ]; then
    log "WARNING" "PROXYSQL_VERSION environment variable is not set. Cannot determine whether to set caching_sha2_password."
else
    log "INFO" "Current PROXYSQL_VERSION is $PROXYSQL_VERSION"
    if version_ge "$PROXYSQL_VERSION" "2.6.0"; then
        log "INFO" "ProxySQL version is $PROXYSQL_VERSION (>= 2.6.0). Setting mysql-default_authentication_plugin to caching_sha2_password."
        set_auth_plugin_sql="
            SET mysql-default_authentication_plugin = 'caching_sha2_password';
            LOAD MYSQL VARIABLES TO RUNTIME;
            SAVE MYSQL VARIABLES TO DISK;
        "
        proxysql_admin_exec "$set_auth_plugin_sql" "" # No extra opts for simple SETs
    else
        log "INFO" "ProxySQL version is $PROXYSQL_VERSION (< 2.6.0). Not changing mysql-default_authentication_plugin."
    fi
fi

log "INFO" "SHOWING PROXYSQL RUNTIME CONFIGURATION"

configuration_sql="
SHOW VARIABLES LIKE 'mysql-default_authentication_plugin';
SHOW VARIABLES LIKE 'admin-version';
SHOW VARIABLES LIKE 'mysql-server_version';

show variables;

select * from mysql_group_replication_hostgroups\G;

select rule_id,match_digest,destination_hostgroup from runtime_mysql_query_rules;

select * from runtime_mysql_servers;

select * from runtime_proxysql_servers;

"

mysql -uadmin -padmin -h127.0.0.1 -P6032 -vvve "$configuration_sql"

log "INFO" "Configuration script finished."
