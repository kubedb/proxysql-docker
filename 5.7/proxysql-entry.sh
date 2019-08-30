#!/bin/bash
set -e

## ProxySQL entrypoint
## ===================
##
## Supported environment variable:
##
## MONITOR_CONFIG_CHANGE={true|false}
## - Monitor /etc/proxysql.cnf for any changes and reload ProxySQL automatically

# use the current scrip name while putting log
script_name=${0##*/}

# pid stores the process id of the proxysql process
declare -i pid

# custom config file location for proxysql
CUSTOM_CONFIG="/etc/custom-proxysql.cnf"

function timestamp() {
  date +"%Y/%m/%d %T"
}

function log() {
  local log_type="$1"
  local msg="$2"
  echo "$(timestamp) [$script_name] [$log_type] $msg"
}

# apply the user provided custom config from /etc/custom-proxysql.cng
# to override the config from /etc/proxysql.cnf
function override_proxysql_config_and_restart() {
  run_in_background=$1

  if [ -f ${CUSTOM_CONFIG} ]; then
    killall -15 proxysql
    cmd="proxysql -c /etc/custom-proxysql.cnf --reload -f $CMDARG"
    if [[ "$run_in_background" == "true" ]]; then
      cmd="$cmd &"
    fi
    log "INFO" ">>>>>>>>> $cmd"
    $cmd

    pid=$!
  fi
}

# If command has arguments, prepend proxysql
if [ "${1:0:1}" = '-' ]; then
  CMDARG="$@"
fi

if [ $MONITOR_CONFIG_CHANGE ]; then

  log "INFO" "Env MONITOR_CONFIG_CHANGE=true"
  CONFIG=/etc/proxysql.cnf
  oldcksum=$(cksum ${CONFIG})

  # Start ProxySQL in the background
  proxysql --reload -f $CMDARG &

  override_proxysql_config_and_restart true

  log "INFO" "Configuring proxysql.."
  /usr/bin/configure-proxysql.sh

  log "INFO" "Monitoring $CONFIG for changes.."
  inotifywait -e modify,move,create,delete -m --timefmt '%d/%m/%y %H:%M' --format '%T' ${CONFIG} |
    while read date time; do
      newcksum=$(cksum ${CONFIG})
      if [ "$newcksum" != "$oldcksum" ]; then
        echo "++++++++++++++++++++++++++++++++++++++++++++++++++++++"
        echo "At ${time} on ${date}, ${CONFIG} update detected."
        echo "++++++++++++++++++++++++++++++++++++++++++++++++++++++"
        oldcksum=$newcksum
        log "INFO" "Reloading ProxySQL.."
        killall -15 proxysql
        proxysql --initial --reload -f $CMDARG &

        override_proxysql_config_and_restart false
      fi
    done
fi

# Start ProxySQL with PID 1
exec proxysql -f $CMDARG &
pid=$!

override_proxysql_config_and_restart true

log "INFO" "Configuring proxysql.."
/usr/bin/configure-proxysql.sh

log "INFO" "Waiting for proxysql ..."
wait $pid
