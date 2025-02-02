#!/bin/bash
# shellcheck disable=SC2174,SC2086
set -e

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

file_env 'ROOT_PASSWORD'

ROOT_PASSWORD=${ROOT_PASSWORD:-password}
BIND_EXTRA_FLAGS=${BIND_EXTRA_FLAGS:--g}
WEBMIN_ENABLED=${WEBMIN_ENABLED:-true}
WEBMIN_INIT_SSL_ENABLED=${WEBMIN_INIT_SSL_ENABLED:-true}
WEBMIN_INIT_REDIRECT_PORT=${WEBMIN_INIT_REDIRECT_PORT:-10000}
WEBMIN_INIT_REFERERS=${WEBMIN_INIT_REFERERS:-NONE}

BIND_DATA_DIR=${DATA_DIR}/bind
WEBMIN_DATA_DIR=${DATA_DIR}/webmin

create_bind_data_dir() {
  mkdir -p "${BIND_DATA_DIR}"

  # populate default bind configuration if it does not exist
  if [ ! -d "${BIND_DATA_DIR}"/etc ]; then
    mv /etc/bind "${BIND_DATA_DIR}"/etc
  fi
  rm -rf /etc/bind
  ln -sf "${BIND_DATA_DIR}"/etc /etc/bind
  chmod -R 0775 "${BIND_DATA_DIR}"
  chown -R "${BIND_USER}":"${BIND_USER}" "${BIND_DATA_DIR}"

  if [ ! -d "${BIND_DATA_DIR}"/lib ]; then
    mkdir -p "${BIND_DATA_DIR}"/lib
    chown "${BIND_USER}":"${BIND_USER}" "${BIND_DATA_DIR}"/lib
  fi
  rm -rf /var/lib/bind
  ln -sf "${BIND_DATA_DIR}"/lib /var/lib/bind
  mkdir -p "${BIND_DATA_DIR}"/etc/logs
  touch "${BIND_DATA_DIR}"/etc/logs/named.log

}

create_webmin_data_dir() {
  mkdir -p "${WEBMIN_DATA_DIR}"
  chmod -R 0755 "${WEBMIN_DATA_DIR}"
  chown -R root:root "${WEBMIN_DATA_DIR}"

  # populate the default webmin configuration if it does not exist
  if [ ! -d "${WEBMIN_DATA_DIR}"/etc ]; then
    mv /etc/webmin "${WEBMIN_DATA_DIR}"/etc
  fi
  rm -rf /etc/webmin
  ln -sf "${WEBMIN_DATA_DIR}"/etc /etc/webmin
}

disable_webmin_ssl() {
  sed -i 's/ssl=1/ssl=0/g' /etc/webmin/miniserv.conf
}

enable_webmin_ssl() {
  sed -i 's/ssl=0/ssl=1/g' /etc/webmin/miniserv.conf
}

set_webmin_redirect_port() {
  webmin_redirect_port_var_exists=$(grep -q "redirect_port" "/etc/webmin/miniserv.conf" ; echo $?)
  if [ "$webmin_redirect_port_var_exists" == "1" ] 
  then
  	echo "redirect_port=$WEBMIN_INIT_REDIRECT_PORT" >> /etc/webmin/miniserv.conf
  else
    sed -i "s/^redirect_port.*/redirect_port=$WEBMIN_INIT_REDIRECT_PORT/" /etc/webmin/miniserv.conf  
  fi	
}

set_webmin_referers() {
  webmin_referers_var_exists=$(grep -q "referers=" "/etc/webmin/config" ; echo $?)
  if [ "$webmin_referers_var_exists" == "1" ] 
  then  
    echo "referers=$WEBMIN_INIT_REFERERS" >> /etc/webmin/config  
  else
    sed -i "s/^referers=.*/referers=$WEBMIN_INIT_REFERERS/" /etc/webmin/config  
  fi
}

set_root_passwd() {
  echo "root:$ROOT_PASSWORD" | chpasswd
}

create_pid_dir() {
  mkdir -m 0775 -p /var/run/named
  chown root:"${BIND_USER}" /var/run/named
}

create_bind_cache_dir() {
  mkdir -m 0775 -p /var/cache/bind
  chown root:"${BIND_USER}" /var/cache/bind
}

first_init() {
    set_webmin_redirect_port
    if [ "${WEBMIN_INIT_SSL_ENABLED}" == "false" ]; then
      disable_webmin_ssl
    elif [ "${WEBMIN_INIT_SSL_ENABLED}" == "true" ]; then
      enable_webmin_ssl
    fi 
    if [ "${WEBMIN_INIT_REFERERS}" != "NONE" ]; then
      set_webmin_referers
    fi
    if [ "${WEBMIN_INIT_REFERERS}" == "NONE" ]; then
      webmin_referers_var_exists=$(grep -q "referers=" "/etc/webmin/config" ; echo $?)
      if [ "$webmin_referers_var_exists" != "1" ] 
      then 
        sed -i "/^referers=.*/d" /etc/webmin/config 
      fi
    fi    
}

create_pid_dir
create_bind_data_dir
create_bind_cache_dir

# allow arguments to be passed to named
if [[ ${1:0:1} = '-' ]]; then
  EXTRA_ARGS="$*"
  set --
elif [[ ${1} == named || ${1} == $(type -p named) ]]; then
  EXTRA_ARGS="${*:2}"
  set --
fi

# default behaviour is to launch named
if [[ -z ${1} ]]; then
  if [ "${WEBMIN_ENABLED}" == "true" ]; then
    create_webmin_data_dir
    first_init
    set_root_passwd
    echo '---------------------'
    echo '|  Starting Webmin  |'
    echo '---------------------'
    /etc/init.d/webmin start
  fi

  echo
  echo '---------------------'
  echo '|  Starting named   |'
  echo '---------------------'
  echo
  exec "$(type -p named)" -u ${BIND_USER} ${BIND_EXTRA_FLAGS} -c /etc/bind/named.conf ${EXTRA_ARGS}
else
  exec "$@"
fi