#!/usr/bin/env bash

# Copyright 2017 Confluent Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#
# Copyright 2018 Daniel Heinrich
#
# This file has been modified to support the standard kafka distribution
# and add windows support.
# see https://github.com/Danny02/kafka-cli

success=false
# Uncomment to enable debugging on the console
#set -x

#currently internal option only.
_default_curl_timeout=10

platform="$( uname -s )"
is_windows=$(uname -s | egrep -q "MSYS|CYGWIN|MINGW" && echo 1 || echo 0)
(( is_windows )) && NET_CMD='netstat -aon' || NET_CMD='lsof -P -c java'


ERROR_CODE=127

# Exit with an error message.
die() {
    echo "$@"
    exit ${ERROR_CODE}
}

validate_and_export_dir_layout() {
    command_name="$( basename "${BASH_SOURCE[0]}" )"

    kafka_bin="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

    kafka_home="$( dirname "${kafka_bin}" )"

    kafka_conf="${kafka_home}/config"

    [[ ! -f "${kafka_conf}/connect-distributed.properties" ]] \
        && die "Cannot locate 'config' directory for Kafka."

    # $TMPDIR includes a trailing '/' by default.
    tmp_dir="${TMPDIR:-/tmp/}"
    kafka_current_dir="${KAFKA_CURRENT:-${tmp_dir}}"
    last="${kafka_current_dir:${#kafka_current_dir}-1:1}"
    [[ "${last}" != "/" ]] && export kafka_current_dir="${kafka_current_dir}/"
}

# Since this function performs essential initializations, call it as early as possible.
validate_and_export_dir_layout

# Contains the result of functions that intend to return a value besides their exit status.
_retval=""

Gre='\e[0;32m';
Red='\e[0;31m';
#Reset color
RC='\e[0m'

declare -a services=(
    "zookeeper"
    "kafka"
    "connect"
)

declare -a rev_services=(
    "connect"
    "kafka"
    "zookeeper"
)

declare -a commands=(
    "list"
    "start"
    "stop"
    "status"
    "current"
    "destroy"
    "top"
    "log"
    "load"
    "unload"
    "config"
    "version"
)

declare -a connector_properties=(
    "console-sink=connect-console-sink.properties"
    "console-source=connect-console-source.properties"
    "file-sink=connect-file-sink.properties"
    "file-source=connect-console-source.properties"
)

export SAVED_KAFKA_LOG4J_OPTS="${KAFKA_LOG4J_OPTS}"
export SAVED_KAFKA_EXTRA_ARGS="${KAFKA_EXTRA_ARGS}"

export SAVED_KAFKA_HEAP_OPTS="${KAFKA_HEAP_OPTS}"
export SAVED_KAFKA_JVM_PERFORMANCE_OPTS="${KAFKA_JVM_PERFORMANCE_OPTS}"
export SAVED_KAFKA_GC_LOG_OPTS="${KAFKA_GC_LOG_OPTS}"

export SAVED_KAFKA_JMX_OPTS="${KAFKA_JMX_OPTS}"

export SAVED_KAFKA_DEBUG="${KAFKA_DEBUG}"
export SAVED_KAFKA_OPTS="${KAFKA_OPTS}"

export SAVED_KAFKA_CLASSPATH="${KAFKA_CLASSPATH}"

FORMAT_CMD="jq '.'"

requirements() {
    local major=3
    local minor=2
    [ "${BASH_VERSINFO[0]:-0}" -lt "${major}" ] \
        || [ "${BASH_VERSINFO[0]:-0}" -eq ${major} -a "${BASH_VERSINFO[1]:-0}" -lt ${minor} ] \
        && invalid_requirement "bash" "${major}.${minor}"

    which curl > /dev/null 2>&1
    status=$?
    if [[ ${status} -ne 0 ]]; then
        invalid_requirement "curl"
    fi

    which jq > /dev/null 2>&1
    status=$?
    if [[ ${status} -ne 0 ]]; then
        FORMAT_CMD="xargs -0"
    fi
}

export_service_env() {
    # The prefix needs to include any delimiters (e.g. '_').
    local prefix="${1}"

    local var="${prefix}LOG4J_OPTS"
    export KAFKA_LOG4J_OPTS="${!var}"
    var="${prefix}EXTRA_ARGS"
    export EXTRA_ARGS="${!var}"

    var="${prefix}HEAP_OPTS"
    export KAFKA_HEAP_OPTS="${!var}"
    var="${prefix}JVM_PERFORMANCE_OPTS"
    export KAFKA_JVM_PERFORMANCE_OPTS="${!var}"
    var="${prefix}GC_LOG_OPTS"
    export KAFKA_GC_LOG_OPTS="${!var}"

    var="${prefix}JMX_OPTS"
    export KAFKA_JMX_OPTS="${!var}"

    var="${prefix}DEBUG"
    export KAFKA_DEBUG="${!var}"
    var="${prefix}OPTS"
    export KAFKA_OPTS="${!var}"

    var="${prefix}CLASSPATH"
    export CLASSPATH="${!var}"
}

echo_variable() {
    local var_value="${!1}"
    echo "${1} = ${var_value}"
}

# Implies zero or positive
is_integer() {
    [[ -n "${1}" ]] && [[ "${1}" =~ ^[0-9]+$ ]]
}

is_json() {
    which jq > /dev/null 2>&1
    status=$?
    if [[ ${status} -ne 0 ]]; then
        echo "Warning: Install 'jq' to add support for parsing JSON"
        local ext="${config_file##*.}"
        if [[ "${#ext}" -ne 4 ]]; then
            return ${ERROR_CODE}
        fi
        echo "${ext}" | grep -i json > /dev/null 2>&1
        return $?
    fi

    # Check whether we have json contents.
    cat "${config_file}" | eval ${FORMAT_CMD} > /dev/null 2>&1
    return $?
}

# Will pick the last integer value that will encounter
get_service_port() {
    local property="${1}"
    local config_file="${2}"
    local delim="${3:-:}"

    [[ -z "${property}" ]] && die "Need property key to extract service port from configuration"
    local property_split=( $( grep -i "^${property}" "${config_file}" | tr "${delim}" "\n" ) )

    _retval=""
    local entry=""
    for entry in "${property_split[@]}"; do
        # trim string
        entry=$( echo "${entry}" | xargs )
        is_integer "${entry}" && _retval="${entry}"
    done
}

wheel_pos=0
wheel_freq_ms=100
spinner_running=false

spinner_init() {
    spinner_running=false
}

spinner() {
    local wheel='-\|/'
    wheel_pos=$(( (wheel_pos + 1) % ${#wheel} ))
    printf "\r${wheel:${wheel_pos}:1}"
    spinner_running=true
    sleep 0.${wheel_freq_ms}
}

spinner_done() {
    # Backspace to override spinner in the next printf/echo
    [[ "${spinner_running}" == true ]] && printf "\b"
    spinner_running=false
}

get_version() {
    local kafka_prefix="${kafka_home}/libs/kafka-clients-"
    local zookeeper_prefix="${kafka_home}/libs/zookeeper-"

    kafka_version="$( ls ${kafka_prefix}*.jar 2> /dev/null )"
    kafka_version="${kafka_version#$kafka_prefix}"
    export kafka_version="${kafka_version%.jar}"

    zookeeper_version="$( ls ${zookeeper_prefix}*.jar 2> /dev/null )"
    zookeeper_version="${zookeeper_version#$zookeeper_prefix}"
    export zookeeper_version="${zookeeper_version%.jar}"
}

set_or_get_current() {
    if [[ -f "${kafka_current_dir}kafka.current" ]]; then
        export kafka_current="$( cat "${kafka_current_dir}kafka.current" )"
    fi

    if [[ ! -d "${kafka_current}" ]]; then
        export kafka_current="$( mktemp -d ${kafka_current_dir}kafka.XXXXXXXX )"
        echo "${kafka_current}" > "${kafka_current_dir}kafka.current"
    fi

    get_version
}

shutdown() {
    [[ "${success}" == false ]] \
        && echo "Unsuccessful execution. Attempting service shutdown" \
        && stop_command

}

is_alive() {
    local pid="${1}"
    kill -0 "${pid}" > /dev/null 2>&1
}

is_not_alive() {
    ! is_alive "${1}"
}

is_running() {
    local service="${1}"
    local print_status="${2}"
    local service_dir="${kafka_current}/${service}"
    local service_pid="$( cat "${service_dir}/${service}.pid" 2> /dev/null )"

    is_alive "${service_pid}"
    status=$?
    if [[ "${print_status}" != false ]]; then
        if [[ ${status} -eq 0 ]]; then
            printf "${service} is [${Gre}UP${RC}]\n"
        else
            printf "${service} is [${Red}DOWN${RC}]\n"
        fi
    fi

    return ${status}
}

wait_process_up() {
    #TODO: need to add port condition here too probably
    wait_process "${1}" "up" "${2}"
}

wait_process_down() {
    wait_process "${1}" "down" "${2}"
}

wait_process() {
    local pid="${1}"
    local event="${2:-up}"
    local timeout_ms="${3}"

    is_integer "${pid}" || die "Need PID to wait on a process"

    # Default max wait time set to 10 minutes. That's practically infinite for this program.
    is_integer "${timeout_ms}" || timeout_ms=600000

    local mode=is_alive
    spinner_init
    # Busy wait in case service dies soon after startup
    while ${mode} "${pid}" && [[ "${timeout_ms}" -gt 0 ]]; do
        spinner
        (( timeout_ms = timeout_ms - wheel_freq_ms ))
    done
    spinner_done

    if [[ "${event}" == "down" ]]; then
        ! ${mode} "${pid}"
    else
        ${mode} "${pid}"
    fi
}

stop_and_wait_process() {
    local pid="${1}"
    local timeout_ms="${2}"
    # Default max wait time set to 10 minutes. That's practically infinite for this program.
    is_integer "${timeout_ms}" || timeout_ms=600000

    spinner_init
    kill "${pid}" 2> /dev/null
    while kill -0 "${pid}" > /dev/null 2>&1 && [[ "${timeout_ms}" -gt 0 ]]; do
        spinner
        (( timeout_ms = timeout_ms - wheel_freq_ms ))
    done
    spinner_done
    # Will have no effect if the process stopped gracefully
    # TODO: maybe should issue a warning if the process is not stopped gracefully.
    kill -9 "${pid}" > /dev/null 2>&1
}

start_zookeeper() {
    export_service_env "ZOOKEEPER_"
    export_log4j_zookeeper
    start_service "zookeeper" "${kafka_bin}/zookeeper-server-start.sh"
}

config_zookeeper() {
    config_service "zookeeper" "zookeeper" "dataDir"
}

export_zookeeper() {
    get_service_port "clientPort" "${kafka_conf}/zookeeper.properties" "="
    if [[ -n "${_retval}" ]]; then
        export zk_port="${_retval}"
    else
        export zk_port="2181"
    fi
}

export_log4j_zookeeper() {
    export_log4j_with_generic_log_dir "zookeeper"
}

stop_zookeeper() {
    stop_service "zookeeper"
}

#TODO: a generic wait_service function makes sense after all.
wait_zookeeper() {
    local pid="${1}"
    export_zookeeper

    local started=false
    local timeout_ms=5000
    while [[ "${started}" == false && "${timeout_ms}" -gt 0 ]]; do
        ( $NET_CMD | grep -a ${zk_port} > /dev/null 2>&1 ) && started=true
        spinner && (( timeout_ms = timeout_ms - wheel_freq_ms ))
    done
    wait_process_up "${pid}" 2000 || echo "Zookeeper failed to start"
}

start_kafka() {
    local service="kafka"
    is_running "zookeeper" "false" \
        || die "Cannot start Kafka, Zookeeper is not running. Check your deployment"
    export_service_env "SAVED_KAFKA_"
    export_log4j_kafka
    start_service "kafka" "${kafka_bin}/kafka-server-start.sh"
}

config_kafka() {
    export_kafka
    config_service "kafka" "server" "log.dirs"
}

export_kafka() {
    get_service_port "listeners" "${kafka_conf}/server.properties"
    if [[ -n "${_retval}" ]]; then
        export kafka_port="${_retval}"
    else
        export kafka_port="9092"
    fi
}

export_log4j_kafka() {
    export_log4j_with_generic_log_dir "kafka"
}

stop_kafka() {
    stop_service "kafka"
}

wait_kafka() {
    local pid="${1}"
    export_kafka

    local started=false
    local timeout_ms=10000

    while [[ "${started}" == false && "${timeout_ms}" -gt 0 ]]; do
        ( $NET_CMD 2> /dev/null | grep -a ${kafka_port} > /dev/null 2>&1 ) && started=true
        spinner && (( timeout_ms = timeout_ms - wheel_freq_ms ))
    done
    wait_process_up "${pid}" 3000 || echo "Kafka failed to start"
}

start_connect() {
    local service="connect"
    is_running "kafka" "false" \
        || die "Cannot start Kafka Connect, Kafka Server is not running. Check your deployment"
    export_service_env "CONNECT_"
    export_log4j_connect
    start_service "connect" "${kafka_bin}/connect-distributed.sh"
}

config_connect() {
    get_service_port "listeners" "${kafka_conf}/server.properties"
    export_kafka

    config_service "connect" "connect-distributed" \
        "bootstrap.servers" "localhost:${kafka_port}"
}

export_connect() {
    get_service_port "rest.port" "${kafka_conf}/connect-distributed.properties" "="
    if [[ -n "${_retval}" ]]; then
        export connect_port="${_retval}"
    else
        export connect_port="8083"
    fi
}

export_log4j_connect() {
    export_log4j_with_generic_log_dir "connect"
}

stop_connect() {
    stop_service "connect"
}

wait_connect() {
    local pid="${1}"
    export_connect

    local started=false
    local timeout_ms=10000
    while [[ "${started}" == false && "${timeout_ms}" -gt 0 ]]; do
        ( netstat -aon 2> /dev/null | grep -a ${connect_port} > /dev/null 2>&1 ) && started=true
        spinner && (( timeout_ms = timeout_ms - wheel_freq_ms ))
    done
    wait_process_up "${pid}" 4000 || echo "Kafka Connect failed to start"
}

status_service() {
    local service="${1}"
    if [[ -n "${service}" ]]; then
        ! service_exists "${service}" && die "Unknown service: ${service}"
    fi

    skip=true
    local entry=""
    [[ -z "${service}" ]] && skip=false

    for entry in "${rev_services[@]}"; do
        [[ "${entry}" == "${service}" ]] && skip=false;
        [[ "${skip}" == false ]] && is_running "${entry}"
    done
}

start_service() {
    local service="${1}"
    local start_command="${2}"
    local service_dir="${kafka_current}/${service}"
    is_running "${service}" "false" \
        && echo "${service} is already running. Try restarting if needed"\
        && return 0

	if [ "x$KAFKA_LOG4J_OPTS" = "x" ]; then	
		LOG4J_DIR="$kafka_home/config/$([ $service = 'connect' ] && echo 'connect-')log4j.properties"
		# If Cygwin is detected, LOG4J_DIR is converted to Windows format.
		(( is_windows )) && LOG4J_DIR=$(cygpath --path --mixed "${LOG4J_DIR}")
		export KAFKA_LOG4J_OPTS="-Dlog4j.configuration=file:${LOG4J_DIR}"
	fi	
		
    mkdir -p "${service_dir}"
    config_"${service}"
    echo "Starting ${service}"
    # TODO: decide whether to persist logs on stdout / stderr between runs.
    ${start_command} "${service_dir}/${service}.properties" \
        &> "${service_dir}/${service}.stdout" &
    echo $! > "${service_dir}/${service}.pid"
    local service_pid="$( cat "${service_dir}/${service}.pid" 2> /dev/null )"
    wait_"${service}" "${service_pid}"
    is_running "${service}"
}

# The first 3 args seem unavoidable right now. 4th is optional
# TODO: refactor to pass property pairs as a map.
config_service() {
    local service="${1}"
    local property_file="${2}"

    ( [[ -z "${service}" ]] || [[ -z "${property_file}" ]] ) \
        && die "Missing required configuration properties for service: ${service}"

    local service_dir="${kafka_current}/${service}"
    mkdir -p "${service_dir}/data"
    local property_key="${3}"
    local property_value="${4}"
    if [[ -n "${property_key}" && -z "${property_value}" ]]; then
        config_command="sed -e s@^${property_key}=.*@${property_key}=${service_dir}/data@g"
    else
        #TODO: Generalize how key-value pairs are set. Property key-value pairs are ignored for now.
        config_command=cat
    fi

    local input_file="${kafka_conf}/${property_file}.properties"

    ${config_command} < "${input_file}" \
        > "${service_dir}/${service}.properties"

    # Override Connect's config, in case this is an unchanged config from a tar.gz or .zip package
    # installation, to make plugin.path work for any "current working directory (cwd)"
    local plugins_dir="${kafka_home}/plugins"
	(( is_windows )) && plugins_dir=$(cygpath -m $plugins_dir)
    if [[ "${service}" == "connect" ]]; then
        sed "s@^#plugin.path=@plugin.path=${plugins_dir}@g" \
            "${service_dir}/${service}.properties" > "${service_dir}/${service}.properties.bak"
        mv -f "${service_dir}/${service}.properties.bak" "${service_dir}/${service}.properties"
    fi
}

export_log4j_with_generic_log_dir() {
    local service="${1}"
    export LOG_DIR="${kafka_current}/${service}/logs"
}

stop_service() {
    local service="${1}"
    local service_dir="${kafka_current}/${service}"
    # check file exists, and if not issue warning.
    local service_pid="$( cat "${service_dir}/${service}.pid" 2> /dev/null )"
    echo "Stopping ${service}"

    stop_and_wait_process "${service_pid}" 10000
    rm -f "${service_dir}/${service}.pid"
    is_running "${service}"
}

service_exists() {
    local service="${1}"
    exists "${service}" "services" && return 0
    return 1
}

command_exists() {
    local command="${1}"
    exists "${command}" "commands"
}

exec_cli(){
    exec "${kafka_bin}"/"${1}"  "$@"
}

exists() {
    local arg="${1}"

    case "${2}" in
        "services")
        local list=( "${services[@]}" ) ;;
        "commands")
        local list=( "${commands[@]}" ) ;;
    esac

    local entry=""
    for entry in "${list[@]}"; do
        [[ ${entry} == "${arg}" ]] && return 0;
    done
    return 1
}

list_command() {
    if [[ "x${1}" == "x" ]]; then
        echo "Available services:"
        local service=""
        for service in "${services[@]}"; do
            echo "  ${service}"
        done
    else
        connect_subcommands "list" "$@"
    fi
}

start_command() {
    set_or_get_current
    echo "Using KAFKA_CURRENT: ${kafka_current}"
    start_or_stop_service "start" "services" "${@}"
}

stop_command() {
    set_or_get_current
    echo "Using KAFKA_CURRENT: ${kafka_current}"
    start_or_stop_service "stop" "rev_services" "${@}"
    return 0
}

status_command() {
    #TODO: consider whether a global call to this one with every invocation makes more sense
    set_or_get_current

    local command="${1}"

    service_exists "${command}"
    status=$?
    if [[ "x${command}" == "x" || ${status} -eq 0 ]]; then
        status_service "$@"
    elif [[ "${command}" == "connectors" ]]; then
        connect_subcommands "status"
    else
        connect_subcommands "status" "${@}"
    fi
}

start_or_stop_service() {
    local command="${1}"
    shift
    case "${1}" in
        "services")
        local list=( "${services[@]}" ) ;;
        "rev_services")
        local list=( "${rev_services[@]}" ) ;;
    esac
    shift
    local service="${1}"
    shift

    if [[ -n "${service}" ]]; then
        ! service_exists "${service}" && die "Unknown service: ${service}"
    fi

    local entry=""
    for entry in "${list[@]}"; do
        "${command}"_"${entry}" "${@}";
        # 1 indicates that a match was found; not an error code here
        [[ "${entry}" == "${service}" ]] && return 1
    done

    # 0 indicates that no match was found
    return 0
}

print_current() {
    set_or_get_current
    echo "${kafka_current}"
}

destroy_command() {
    if [[ -f "${kafka_current_dir}kafka.current" ]]; then
        export kafka_current="$( cat "${kafka_current_dir}kafka.current" )"
    fi

    [[ ${kafka_current} == ${kafka_current_dir}kafka* ]] \
        && stop_command \
        && echo "Deleting: ${kafka_current}" \
        && rm -rf "${kafka_current}" \
        && rm -f "${kafka_current_dir}kafka.current"
}

top_command() {
    set_or_get_current
    local service="${1}"

    if [[ -n "${service}" ]]; then
        ! service_exists "${service}" && die "Unknown service: ${service}"
    fi

    case "${platform}" in
        Darwin|Linux)
            top_"${platform}" "$@";;
        *)
            die "'top' not available in platform: ${platform}" "$@";;
    esac
}

top_Linux() {
    local service=( "${1}" )

    [[ -z "${service}" ]] && service=( "${services[@]}" )

    local pids=""
    local item=""
    for item in "${service[@]}"; do
        local service_dir="${kafka_current}/${item}"
        local service_pid="$( cat "${service_dir}/${item}.pid" 2> /dev/null )"
        [[ -n "${service_pid}" ]] && pids="${pids}${service_pid},"
    done
    pids="${pids%%','}"
    [[ -z "${pids}" ]] && die "No services are running"
    top -p "${pids}"
}

top_Darwin() {
    local service="${1}"

    [[ -z "${service}" ]] && die "Missing required service argument in '${command_name} top'"

    local service_dir="${kafka_current}/${service}"
    local service_pid="$( cat "${service_dir}/${service}.pid" 2> /dev/null )"
    top -pid "${service_pid}"
}

log_command() {
    set_or_get_current
    local service="${1}"

    [[ -z "${service}" ]] && die "Missing required service argument in '${command_name} log'"

    if [[ -n "${service}" ]]; then
        ! service_exists "${service}" && die "Unknown service: ${service}"
    fi
    shift

    local service_dir="${kafka_current}/${service}"
    local service_log="${service_dir}/${service}.stdout"

    if [[ $# -gt 0 ]]; then
        tail "${@}" "$service_log"
    else
        less "$service_log"
    fi
}

connect_bundled_command() {
    echo "Bundled Predefined Connectors (edit configuration under $KAFKA_HOME/config/):"

    local entry=""
    for entry in "${connector_properties[@]}"; do
        local key="${entry%%=*}"
        echo "  ${key}"
    done
}

connect_list_command() {
    local subcommand="${1}"

    is_running "connect" "false"
    status=$?
    if [[ ${status} -ne 0 ]]; then
        is_running "connect" "true"
    fi

    if [[ "${subcommand}" == "connectors" ]]; then
            connect_bundled_command
    elif [[ "${subcommand}" == "plugins" ]]; then
        echo "Available Connector Plugins: "
        curl --max-time "${_default_curl_timeout}" -s -X GET \
            http://localhost:"${connect_port}"/connector-plugins \
            | eval ${FORMAT_CMD}
    else
        invalid_argument "list" "${subcommand}"
    fi
}

connect_status_command() {
    local connector="${1}"

    is_running "connect" "false"
    status=$?
    if [[ ${status} -ne 0 ]]; then
        is_running "connect" "true" \
        || die "To get the status of connectors try starting 'connect' service first."
    fi

    if [[ -n "${connector}" ]]; then
        curl --max-time "${_default_curl_timeout}" -s -X GET \
            http://localhost:"${connect_port}"/connectors/"${connector}"/status \
            | eval ${FORMAT_CMD}
    else
        curl --max-time "${_default_curl_timeout}" -s -X GET \
            http://localhost:"${connect_port}"/connectors \
            | eval ${FORMAT_CMD}
    fi
}

connector_config_template() {
    local connector_name="${1}"
    local config_file="${2}"
    local nested="${3}"

    [[ ! -f "${config_file}" ]] \
        && die "Can't load connector configuration. Config file '${config_file}' does not exist."

    local config="{"
    # TODO: decide which name to use. The one in the file or the predefined
    #local name_line="$( grep ^name ${config_file} )"
    #name="${name_line#*=}"
    name="${connector}"

    append_key_value "name" "${name}"
    local wrapper=""
    [[ "${nested}" == true ]] && wrapper=" \"config\": {"

    config="${config}${_retval},${wrapper}"

    while IFS= read -r line; do
        local key="${line%%=*}"
        local value="${line#*=}"
        append_key_value "${key}" "${value}"
        config="${config}${_retval},"
    done < <( grep -v ^# "${config_file}" | grep -v ^name | grep -v -e '^[[:space:]]*$' | grep '=' )

    [[ "${nested}" == true ]] && wrapper="}"

    config="${config}}"
    config="${config%%',}'}"
    config="${config}}${wrapper}"
    _retval="$( echo "${config}" | eval ${FORMAT_CMD} )"
}

extract_name_from_properties_file() {
    local config_file="${1}"

    [[ ! -f "${config_file}" ]] \
        && die "Can't load connector configuration. Config file '${config_file}' does not exist."

    local name_line="$( grep ^name ${config_file} | grep '=' )"
    _retval="${name_line#*=}"
}

append_key_value() {
    local key="${1}"
    local value="${2}"

    _retval="\"${key}\": \"${value}\""
}

is_predefined_connector() {
    local connector_name="${1}"
    [[ -z "${connector_name}" ]] && die "Connector name is missing"

    _retval=""
    local entry=""
    for entry in "${connector_properties[@]}"; do
        local key="${entry%%=*}"
        local value="${entry#*=}"
        if [[ "${key}" == "${connector_name}" ]]; then
            _retval="${value}"
            return 0
        fi
    done
    return 1
}

connect_load_command() {
    local connector="${1}"
    local flag="${2}"
    local config_file="${3}"

    if [[ "x${connector}" == "x" ]]; then
        die "Missing required connector name argument in '${command_name} load'"
    elif [[ "x${flag}" == "x" ]]; then
        if is_predefined_connector "${connector}"; then
            connector_config_template "${connector}" "${kafka_conf}/${_retval}" "true"
            parsed_json="${_retval}"
        else
            die "${connector} is not a predefined connector name.\nUse '${command_name} load ${connector} -d <connector-config-file.[json|properties]' to load the connector's configuration."
        fi
    else
        if [[ "${flag}" != "-d" ]]; then
            invalid_argument "load" "${flag}"
        fi

        [[ ! -f "${config_file}" ]] \
            && die "Can't load connector configuration. Config file '${config_file}' does not exist."

        # Check whether we have json contents.
        is_json "${config_file}"
        status=$?

        local parsed_json=""
        if [[ ${status} -eq 0 ]]; then
            # It's JSON format load it.
            extract_json_config "${config_file}" "false"
            parsed_json="${_retval}"
        else
            file "${config_file}" | grep "ASCII" > /dev/null 2>&1
            status=$?
            if [[ ${status} -eq 0 ]]; then
                # Potentially properties file. Try to load it.
                extract_name_from_properties_file "${config_file}"
                [[ "x${_retval}" == "x" ]] \
                    && die "Missing 'name' property from connectors properties file."
                local connector_name="${_retval}"
                connector_config_template "${connector_name}" "${config_file}" "true"
                parsed_json="${_retval}"
            else
                invalid_argument "config" "${config_file}"
            fi
        fi
    fi

    curl --max-time "${_default_curl_timeout}" -s -X POST -d "${parsed_json}" \
        --header "content-Type:application/json" \
        http://localhost:"${connect_port}"/connectors \
        | eval ${FORMAT_CMD}
}

connect_unload_command() {
    local connector="${1}"
    [[ -z "${connector}" ]] && die "Can't unload connector. Connector name is missing"

    curl --max-time "${_default_curl_timeout}" -s -X DELETE \
        http://localhost:"${connect_port}"/connectors/"${connector}"
}

extract_json_config() {
    local config_file="${1}"
    # If it is nested, extract only the config field.
    local only_config="${2}"

    local parsed_json=""
    # Treating here the JSON contents as flat json, or nested with a specific field called
    # "config" is good enough for now.
    if [[ ${only_config} == true ]]; then
        which jq > /dev/null 2>&1
        status=$?

        if [[ ${status} -ne 0 ]]; then
            die "Error: Parsing config from JSON file '${config_file}' failed."
        fi

        cat "${config_file}" | jq -e '.config' > /dev/null 2>&1
        status=$?

        if [[ ${status} -ne 0 ]]; then
            die "Error: Parsing JSON file '${config_file}' failed"
        fi

        parsed_json=$( cat "${config_file}" | jq -e '.config' )
    else
        parsed_json=$( cat "${config_file}" )
    fi
    _retval="${parsed_json}"
}

connect_config_command() {
    local connector="${1}"
    local flag="${2}"
    local config_file="${3}"

    if [[ "x${connector}" == "x" ]]; then
        die "Missing required connector name argument in '${command_name} config'"
    elif [[ "x${flag}" == "x" ]]; then
        echo "Current configuration of '${connector}' connector:"
        curl --max-time "${_default_curl_timeout}" -s -X GET \
            http://localhost:"${connect_port}"/connectors/"${connector}"/config \
            | eval ${FORMAT_CMD}
        return $?
    fi

    if [[ "${flag}" != "-d" ]]; then
        invalid_argument "config" "${flag}"
    fi

    [[ ! -f "${config_file}" ]] \
        && die "Can't load connector configuration. Config file '${config_file}' does not exist."

    # Check whether we have json contents.
    is_json "${config_file}"
    status=$?

    local parsed_json=""
    if [[ ${status} -eq 0 ]]; then
        # It's JSON format load it.
        extract_json_config "${config_file}" "true"
        parsed_json="${_retval}"
    else
        file "${config_file}" | grep "ASCII" > /dev/null 2>&1
        status=$?
        if [[ ${status} -eq 0 ]]; then
            # Potentially properties file. Try to load it.
            extract_name_from_properties_file "${config_file}"
            [[ "x${_retval}" == "x" ]] \
                && die "Missing 'name' property from connectors properties file."
            local connector_name="${_retval}"
            connector_config_template "${connector_name}" "${config_file}" "false"
            parsed_json="${_retval}"
        else
            invalid_argument "config" "${config_file}"
        fi
    fi

    curl --max-time "${_default_curl_timeout}" -s -X PUT \
        -H "Content-Type: application/json" \
        -d "${parsed_json}" \
        http://localhost:"${connect_port}"/connectors/"${connector}"/config \
        | eval ${FORMAT_CMD}
}

connect_restart_command() {
    echo "Not implemented yet!"
}

connect_subcommands() {
    set_or_get_current
    export_connect

    local subcommand="${1}"

    case "${subcommand}" in
        list)
            shift
            connect_list_command "$@";;

        load)
            shift
            connect_load_command "$@";;

        unload)
            shift
            connect_unload_command "$@";;

        status)
            shift
            connect_status_command "$@";;

        config)
            shift
            connect_config_command "$@";;

        restart)
            shift
            connect_restart_command "$@";;

        *) invalid_subcommand "connect" "$@";;
    esac
}

version_command() {
    set_or_get_current
    local service="${1}"

    if [[ -n "${service}" ]]; then
        ! service_exists "${service}" && die "Unknown service: ${service}"
        if [[ "x${service}" == "xkafka" ]]; then
            echo "${kafka_version}"
        elif [[ "x${service}" == "xzookeeper" ]]; then
            echo "${zookeeper_version}"
        else
            echo "${kafka_version}"
        fi
    else
        echo "${kafka_version}"
    fi
}

list_usage() {
    cat <<EOF
Usage: ${command_name} list [ plugins | connectors ]

Description:
    List all the available services or plugins.

    Without arguments it prints the list of all the available services.

    Given 'plugins' as subcommand, prints all the connector-plugins which are
    discoverable in the current Kafka deployment.

    Given 'connectors' as subcommand, prints a list of connector names that map to predefined
    connectors. Their configuration files can be found under 'config/' directory in Kafka.


Examples:
    kafka list
        Prints the available services.

    kafka list plugins
        Prints all the connector plugins (connector classes) discoverable by Connect runtime.

    kafka list connectors
        Prints a list of predefined connectors.

EOF
    exit 0
}

start_usage() {
    cat <<EOF
Usage: ${command_name} start [<service>]

Description:
    Start all services. If a specific <service> is given as an argument, it starts this service
    along with all of its dependencies.


Output:
    Prints status messages after starting each service to indicate successful startup or error.


Examples:
    kafka start
        Starts all available services.

    kafka start kafka
        Starts kafka and zookeeper as its dependency.

EOF
    exit 0
}

stop_usage() {
    cat <<EOF
Usage: ${command_name} stop [<service>]

Description:
    Stop all services. If a specific <service> is given as an argument it stops this service
    along with all of its dependencies.


Output:
    Prints status messages after stopping each service to indicate successful shutdown or error.


Examples:
    kafka stop
        Stops all available services.

    kafka stop kafka
        Stops kafka and zookeeper as its dependency.

EOF
    exit 0
}

status_usage() {
    cat <<EOF
Usage: ${command_name} status [ <service> | connectors | <connector-name> ]

Description:
    Return the status of services or connectors.

    Without arguments it prints the status of all the available services.

    If a specific <service> is given as an argument the status of the requested service is returned
    along with the status of its dependencies.

    Given 'connectors' as subcommand, prints a list with the connectors currently loaded in Connect.

    If a specific <connector-name> is given, then the status of the requested connector is returned.


Examples:
    kafka status
        Prints the status of the available services.

    kafka status kafka
        Prints the status of the 'kafka' service.

    kafka status connectors
        Prints a list with the loaded connectors at any given moment.

    kafka status file-source
        Prints the status of the connector with the given name.

EOF
    exit 0
}

current_usage() {
    cat <<EOF
Usage: ${command_name} current

Description:
    Return the filesystem path of the data and logs of the services managed by the current
    kafka run. If such a path does not exist, it will be created.


Output:
    The filesystem directory path to the current kafka run.


Examples:
    kafka current
        /tmp/kafka.SpBP4fQi

EOF
    exit 0
}

destroy_usage() {
    cat <<EOF
Usage: ${command_name} destroy

Description:
    Delete an existing kafka run. Any running services are stopped. The data and the log
    files of all services are deleted.


Examples:
    kafka destroy
        Confirms that every service is stopped and finally prints the filesystem path that is deleted.

EOF
    exit 0
}

log_usage() {
    cat <<EOF
Usage: ${command_name} log <service> [optional arguments to tail]

Description:
    Read or tail the log of a service. If no arguments are given, a snapshot of the log is opened with
    a viewer ('less' command). If any arguments are given, 'tail' is used instead and the arguments
    are passed to the tail command.


Examples:
    kafka log connect
        Opens the connect log using 'less'.

    kafka log kafka -f
        Tails the kafka log and waits to print additional output until the log command is interrupted.

EOF
    exit 0
}

top_usage() {
    cat <<EOF
Usage: ${command_name} top [<service>]

Description:
    Track resource usage of a service.

EOF
    exit 0
}

load_usage() {
    cat <<EOF
Usage: ${command_name} load [<connector-name> [-d <connector-config-file>]]

Description:
    Load a bundled connector with a predefined name or custom connector with a given configuration.

EOF
    exit 0
}

unload_usage() {
    cat <<EOF
Usage: ${command_name} unload [<connector-name>]

Description:
    Unload a connector with the given <connector-name>.

EOF
    exit 0
}

config_usage() {
    cat <<EOF
Usage: ${command_name} config <connector-name> [ -d <connector-config-file> ]

Description:
    Get or set a connector's configuration properties.

    Given only the connector's name, prints the connector's configuration if such a connector is
    currently loaded in Connect.

    Additionally, given a filename with the option '-d', it configures the connector '<connector-name>'.
    The file needs to be in a valid JSON or java properties format and has to contain a correct
    configuration for a connector with the same name as the one given in the command-line.


Examples:
    kafka config s3-sink
        Prints the current configuration of the predefined connector with name 's3-sink'

    kafka config wikipedia-file-source
        Prints the current configuration of a custom connector with name 'wikipedia-file-source'

    kafka config wikipedia-file-source -d ./wikipedia-file-source.json
        Configures a connector named 'wikipedia-file-source' by passing its configuration properties in
        JSON format.

    kafka config wikipedia-file-source -d ./wikipedia-file-source.properties
        Configures a connector named 'wikipedia-file-source' by passing its configuration properties as
        java properties.

EOF
    exit 0
}

version_usage() {
    cat <<EOF
Usage: ${command_name} version [<service>]

Description:
    Print the Kafka version, or the individual version of a service.

Examples:
    kafka version
        Prints the version of Kafka.

    kafka version zookeeper
        Prints the version of a service included with Kafka, 'zookeeper' in this example.

EOF
    exit 0
}

usage() {
    cat <<EOF
${command_name}: A command line interface to manage Kafka services

Usage: ${command_name} <command> [<subcommand>] [<parameters>]

These are the available commands:

    config      Configure a connector.
    current     Get the path of the data and logs of the services managed by the current kafka run.
    destroy     Delete the data and logs of the current kafka run.
    list        List available services.
    load        Load a connector.
    log         Read or tail the log of a service.
    start       Start all services or a specific service along with its dependencies
    status      Get the status of all services or the status of a specific service along with its dependencies.
    stop        Stop all services or a specific service along with the services depending on it.
    top         Track resource usage of a service.
    unload      Unload a connector.
    version     Print the Kafka version or the individual version of a service.

'${command_name} help' lists available commands. See '${command_name} help <command>' to read about a
specific command.

EOF
    exit 0
}

invalid_argument() {
    local command="${1}"
    local argument="${2}"
    die "Invalid argument '${argument}' given to '${command}'."
}

invalid_subcommand() {
    local command="${1}"
    shift
    echo "Unknown subcommand '${command} ${1}'."
    die "Type '${command_name} help ${command}' for a list of available subcommands."
}

invalid_command() {
    echo "Unknown command '${1}'."
    die "Type '${command_name} help' for a list of available commands."
}

invalid_requirement() {
    echo -n "'${command_name}' requires '${1}'"
    if [[ "x${2}" == "x" ]]; then
        echo "."
    else
        echo " >= '${2}'."
    fi

    exit ${ERROR_CODE}
}

# Parse command-line arguments
[[ $# -lt 1 ]] && usage

requirements

command="${1}"
shift
case "${command}" in
    help)
        if [[ -n "${1}" ]]; then
            command_exists "${1}" && ( "${1}"_usage "$@" || invalid_command "${1}" )
        else
            usage
        fi;;

    config)
        connect_subcommands "${command}" "$@";;

    connect)
        connect_subcommands "$@";;

    current)
        print_current;;

    destroy)
        destroy_command;;

    list)
        list_command "$@";;

    load)
        connect_subcommands "${command}" "$@";;

    log)
        log_command "$@";;

    start)
        start_command "$@";;

    status)
        status_command "$@";;

    stop)
        stop_command "$@";;

    top)
        top_command "$@";;

    unload)
        connect_subcommands "${command}" "$@";;

    version)
        version_command "$@";;

    *) invalid_command "${command}";;
esac

success=true

trap shutdown EXIT
