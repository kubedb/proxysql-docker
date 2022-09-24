#!/bin/bash

# use the current scrip name while putting log
script_name=${0##*/}

# used env var from container
# LOAD_BALANCE_MODE - value is either "Galera" or "GroupReplication"

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
opt=" -vvv -f "
TIMEOUT="10" # 10 sec timeout to wait for server

if [[ -z "${PROXYSQL_ADMIN_USER}" ]]; then
    export PROXYSQL_ADMIN_USER="admin"
    export PROXYSQL_ADMIN_PASSWORD="admin"
fi

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

function wait_for_mysql() {
    local user="$1"
    local pass="$2"
    local server="$3"
    local port="$4"

    log "INFO" "Waiting for host $server to be online ..."
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

IFS=',' read -ra BACKEND_SERVERS <<<"$PEERS"
if [[ "${#BACKEND_SERVERS[@]}" -eq 0 ]]; then
    log "ERROR" "Backend pxc servers not found. Exiting ..."
    exit 1
fi
first_host=${BACKEND_SERVERS[0]}

log "INFO" "Provided peers are ${BACKEND_SERVERS[*]}"

primary=${BACKEND_SERVERS[0]}

if [[ "$LOAD_BALANCE_MODE" == "GroupReplication" ]]; then
    primary=$(mysql_exec root $MYSQL_ROOT_PASSWORD $first_host 3306 \
        "
SELECT MEMBER_HOST FROM performance_schema.replication_group_members
                          INNER JOIN performance_schema.global_status ON (MEMBER_ID = VARIABLE_VALUE)
WHERE VARIABLE_NAME='group_replication_primary_member';
")

fi

log "INFO" "Current primary member of the group is $primary"

wait_for_mysql root $MYSQL_ROOT_PASSWORD $primary 3306

if [ $BACKEND_TLS_ENABLED == "true" ]; then
    mysql_exec root $MYSQL_ROOT_PASSWORD $primary 3306 "CREATE USER '$MYSQL_PROXY_USER'@'%' IDENTIFIED BY '$MYSQL_PROXY_PASSWORD' REQUIRE SSL;" $opt
else
    mysql_exec root $MYSQL_ROOT_PASSWORD $primary 3306 "CREATE USER '$MYSQL_PROXY_USER'@'%' IDENTIFIED BY '$MYSQL_PROXY_PASSWORD';" $opt
fi

mysql_exec root $MYSQL_ROOT_PASSWORD $primary 3306 \
    "
GRANT ALL PRIVILEGES ON *.* TO '$MYSQL_PROXY_USER'@'%';
FLUSH PRIVILEGES ;
  " \
    $opt

echo "done"

additional_sys_query=$(cat /sql/addition_to_sys_v5.sql)
if [[ $MYSQL_VERSION == "8"* ]]; then
    additional_sys_query=$(cat /sql/addition_to_sys_v8.sql)
fi
mysql_exec root $MYSQL_ROOT_PASSWORD $primary 3306 "$additional_sys_query" $opt

# wait for proxysql process to run
wait_for_mysql admin admin 127.0.0.1 6032

#configure mysql servers
function get_mysql_servers_sql() {
    local sql=""
    for server in "${BACKEND_SERVERS[@]}"; do
        sql="$sql
REPLACE INTO mysql_servers(hostgroup_id, hostname, port, weight) VALUES (2,'$server',3306,100);
"
    done

    if [ $BACKEND_TLS_ENABLED == "true" ]; then
        sql="$sql
UPDATE mysql_servers SET use_ssl=1 WHERE port=3306;
"
    fi

    sql="$sql
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;
"
    echo $sql
}

mysql_servers_sql=$(get_mysql_servers_sql)

log "INFO" "sql query to configure proxysql
$mysql_servers_sql
"

mysql_exec $PROXYSQL_ADMIN_USER $PROXYSQL_ADMIN_PASSWORD 127.0.0.1 6032 "$mysql_servers_sql" $opt

# configure proxysql servers
IFS=',' read -ra PROXY_SERVERS <<<"$PROXY_PEERS"

function get_proxy_servers_sql() {
    local sql=""
    for server in "${PROXY_SERVERS[@]}"; do
        sql="$sql
insert into proxysql_servers(hostname,port,weight) values('$server',6032,1);
"
    done
    sql="$sql
LOAD PROXYSQL SERVERS TO RUNTIME;
SAVE PROXYSQL SERVERS TO DISK;
"
    echo $sql
}

proxycluster_sql=$(get_proxy_servers_sql)

log "INFO" "sql query to configure proxysql cluster
$proxycluster_sql"

if [ $PROXY_CLUSTER == "true" ]; then
    mysql_exec $PROXYSQL_ADMIN_USER $PROXYSQL_ADMIN_PASSWORD 127.0.0.1 6032 "$proxycluster_sql" $opt
fi

# configure cluster user credential
export PRE_CLUSTER_USER=$(mysql -uadmin -padmin -h127.0.0.1 -P6032 -Nbe "select variable_value from global_variables where variable_name='admin-cluster_username';")

IFS=';' read -ra ALL_CLUSTER_USERS <<<"$PRE_CLUSTER_USER"
len=${#ALL_CLUSTER_USERS[@]}
CURRENT_USER_FOUND="false"
for ((i = 0; i < $len; i++)); do
    if [[ "${ALL_CLUSTER_USERS[$i]}" == "cluster" ]]; then
        CURRENT_USER_FOUND="true"
    fi
done

if [[ $CURRENT_USER_FOUND == "false" ]]; then
    export ADMIN_CREDENTIAL=$(mysql -uadmin -padmin -h127.0.0.1 -P6032 -Nbe "select variable_value from global_variables where variable_name='admin-admin_credentials';")
    mysql -uadmin -padmin -h127.0.0.1 -P6032 -Nbe "set admin-admin_credentials='$ADMIN_CREDENTIAL;$CLUSTER_USERNAME:$CLUSTER_PASSWORD';"

    if [[ "$PRE_CLUSTER_USER" == "" ]]; then
        mysql -uadmin -padmin -h127.0.0.1 -P6032 -Nbe "set admin-cluster_username='$CLUSTER_USERNAME';"
    else
        mysql -uadmin -padmin -h127.0.0.1 -P6032 -Nbe "set admin-cluster_username='$PRE_CLUSTER_USER;$CLUSTER_USERNAME';"
    fi

    export PRE_CLUSTER_PASS=$(mysql -uadmin -padmin -h127.0.0.1 -P6032 -Nbe "select variable_value from global_variables where variable_name='admin-cluster_password';")
    if [[ "$PRE_CLUSTER_PASS" == "" ]]; then
        mysql -uadmin -padmin -h127.0.0.1 -P6032 -Nbe "set admin-cluster_password='$CLUSTER_PASSWORD';"
    else
        mysql -uadmin -padmin -h127.0.0.1 -P6032 -Nbe "set admin-cluster_password='$PRE_CLUSTER_PASS;$CLUSTER_PASSWORD';"
    fi

    mysql -uadmin -padmin -h127.0.0.1 -P6032 -Nbe "SAVE ADMIN VARIABLES TO DISK;"
    mysql -uadmin -padmin -h127.0.0.1 -P6032 -Nbe "LOAD ADMIN VARIABLES TO RUNTIME;"
fi

log "INFO" "SET UP COMPLETED"
log "INFO" "CURRENT CONFIGURATION"

configuration_sql="
show variables;

select * from mysql_group_replication_hostgroups\G;

select rule_id,match_digest,destination_hostgroup from runtime_mysql_query_rules;

select * from runtime_mysql_servers;

select * from runtime_proxysql_servers;

"

mysql -uadmin -padmin -h127.0.0.1 -P6032 -vvve "$configuration_sql"
