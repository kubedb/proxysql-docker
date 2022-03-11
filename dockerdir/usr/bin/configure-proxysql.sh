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
  mysql $exec_opt --user=${user} --password=${pass} --host=${server} -P${port} -NBe "${query}"
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

wait_for_mysql \
  root \
  $MYSQL_ROOT_PASSWORD \
  $first_host \
  3306

mysql_exec \
  root \
  $MYSQL_ROOT_PASSWORD \
  $first_host \
  3306 \
  "
CREATE USER '$MYSQL_PROXY_USER'@'%' IDENTIFIED BY '$MYSQL_PROXY_PASSWORD';
  " \
  $opt
mysql_exec \
  root \
  $MYSQL_ROOT_PASSWORD \
  $first_host \
  3306 \
  "
GRANT ALL ON *.* TO '$MYSQL_PROXY_USER'@'%';
FLUSH PRIVILEGES ;
  " \
  $opt
echo "done"
if [[ "$LOAD_BALANCE_MODE" == "GroupReplication" ]]; then
  primary=$(mysql_exec \
  root \
  $MYSQL_ROOT_PASSWORD \
  $first_host \
  3306 \
  "
SELECT MEMBER_HOST FROM performance_schema.replication_group_members
                          INNER JOIN performance_schema.global_status ON (MEMBER_ID = VARIABLE_VALUE)
WHERE VARIABLE_NAME='group_replication_primary_member';
" )

  log "INFO" "Current primary member of the group is $primary"
  additional_sys_query=$(cat /addition_to_sys.sql)
  mysql_exec \
  root \
  $MYSQL_ROOT_PASSWORD \
  $primary \
  3306 \
  "$additional_sys_query" \
  $opt
fi

# Now prepare sql for proxysql
# Here, we configure read and write access for two host groups with id 10 and 20.
# Host group 10 is for requests filtered by the pattern '^SELECT.*FOR UPDATE$'
#   and contains only first host from the peers list
# Host group 20 is for requests filtered by the pattern '^SELECT'
#   and contains all of the hosts from the peers list

function get_hostgroups_sql() {
  local sql=""
  if [[ "$LOAD_BALANCE_MODE" == "Galera" ]]; then
    sql="
REPLACE INTO mysql_galera_hostgroups
(writer_hostgroup,backup_writer_hostgroup,reader_hostgroup,offline_hostgroup,active,max_writers,writer_is_also_reader,max_transactions_behind)
VALUES (2,4,3,1,1,1,1,100);
"
  else
    sql="
REPLACE INTO mysql_group_replication_hostgroups
(writer_hostgroup,backup_writer_hostgroup,reader_hostgroup,offline_hostgroup,active,max_writers,writer_is_also_reader,max_transactions_behind)
VALUES (2,4,3,1,1,1,1,0);
"
  fi

  echo $sql
}

function get_servers_sql() {
  local sql=""
  for server in "${BACKEND_SERVERS[@]}"; do
    sql="$sql
REPLACE INTO mysql_servers
(hostgroup_id, hostname, port, weight)
VALUES (2,'$server',3306,100);
"
  done

  sql="$sql
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;
"

  echo $sql
}

function get_users_sql() {
  local sql="
UPDATE global_variables
SET variable_value='$MYSQL_PROXY_USER'
WHERE variable_name='mysql-monitor_username';
UPDATE global_variables
SET variable_value='$MYSQL_PROXY_PASSWORD'
WHERE variable_name='mysql-monitor_password';

LOAD MYSQL VARIABLES TO RUNTIME;
SAVE MYSQL VARIABLES TO DISK;

REPLACE INTO mysql_users
(username, password, active, default_hostgroup, max_connections)
VALUES ('root', '$MYSQL_ROOT_PASSWORD', 1, 2, 200);
REPLACE INTO mysql_users
(username, password, active, default_hostgroup, max_connections)
VALUES ('$MYSQL_PROXY_USER', '$MYSQL_PROXY_PASSWORD', 1, 2, 200);

LOAD MYSQL USERS TO RUNTIME;
SAVE MYSQL USERS TO DISK;

UPDATE mysql_users
SET default_hostgroup=2;

LOAD MYSQL USERS TO RUNTIME;
SAVE MYSQL USERS TO DISK;
"

  echo $sql
}

function get_queries_sql() {
  local sql="
REPLACE INTO mysql_query_rules
(rule_id,active,match_digest,destination_hostgroup,apply)
VALUES
(1,1,'^SELECT.*FOR UPDATE$',2,1),
(2,1,'^SELECT',3,1),
(3,1,'.*',2,1);

LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
"

  echo $sql
}

hostgroups_sql=$(get_hostgroups_sql)
servers_sql=$(get_servers_sql)
users_sql=$(get_users_sql)
queries_sql=$(get_queries_sql)

log "INFO" "sql query to configure proxysql

$hostgroups_sql

$servers_sql

$users_sql

$queries_sql"

# wait for proxysql process to be run
wait_for_mysql admin admin 127.0.0.1 6032

mysql_exec \
$PROXYSQL_ADMIN_USER \
$PROXYSQL_ADMIN_PASSWORD \
127.0.0.1 \
6032 \
"$cleanup_sql $hostgroups_sql $servers_sql $users_sql $queries_sql" \
$opt

log "INFO" "All done!"

log "INFO" "What have set up"

verification_sql="
select * from runtime_mysql_servers;

select hostgroup, srv_host, status, ConnUsed, MaxConnUsed, Queries
from stats.stats_mysql_connection_pool order by srv_host;

select * from mysql_servers;

"

IFS=',' read -ra PROXY_SERVERS  <<<"$PROXY_PEERS"

function get_proxyservers_sql(){
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

proxycluster_sql=$(get_proxyservers_sql)

log "INFO" "sql query to configure proxysql cluster
$proxycluster_sql"

if [ $DO_CLUSTER == "true" ]; then
mysql_exec \
$PROXYSQL_ADMIN_USER \
$PROXYSQL_ADMIN_PASSWORD \
127.0.0.1 \
6032 \
"$proxycluster_sql" \
$opt
fi

if [[ "$LOAD_BALANCE_MODE" == "Galera" ]]; then
  verification_sql="$verification_sql
select * from mysql_galera_hostgroups;
"
else
  verification_sql="$verification_sql
select * from mysql_group_replication_hostgroups;
"
fi

verification_sql="$verification_sql
select * from mysql_users;

select * from mysql_query_rules;
"

mysql_exec \
$PROXYSQL_ADMIN_USER \
$PROXYSQL_ADMIN_PASSWORD \
127.0.0.1 \
6032 \
"$verification_sql" \
$opt
