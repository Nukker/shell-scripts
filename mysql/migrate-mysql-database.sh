#! /bin/bash

ME="$(basename $0)"

DUMP_DIRECTORY=
CLEANUP="true"

DUMP_OPS_NO_DATA=

SOURCE_MYSQL_HOST=
SOURCE_MYSQL_PORT=
SOURCE_MYSQL_USER=
SOURCE_MYSQL_PASSWORD=
DESTINATION_MYSQL_HOST=
DESTINATION_MYSQL_PORT=
DESTINATION_MYSQL_USER=
DESTINATION_MYSQL_PASSWORD=

function print_usage {
cat << EOF

Usage for migrate-mysql-database.sh:

  $ME -h # Print usage

  $ME -g /path/used/for/generating/migration-config # Generate migration config[git config format.].

  $ME -f /path/of/migration-config -d 'db1 db2 db3 ...' [-s /directory/for/sql/dump] # Migrate database according to migration-config

      1. When migrating multiple database once, the database names MUST be wrapped by single quotes(').
      2. When '-s' option is NOT specified, a temporary directory will be used. When the script exiting, the temporary will be removed.

EOF
}

function die {
  echo -e "$@" && exit 1
}

function generate_migration_config {
  local config_file="$1"
  
  [ -e $config_file ] && die "Specified config file is existed."

  if \
    git config -f $config_file source.host '$$host' >& /dev/null && \
    git config -f $config_file source.port '$$port' >& /dev/null  && \
    git config -f $config_file source.user '$$user' >& /dev/null && \
    git config -f $config_file source.password '$$password' >& /dev/null && \
    git config -f $config_file destination.host '$$host' >& /dev/null && \
    git config -f $config_file destination.port '$$port' >& /dev/null && \
    git config -f $config_file destination.user '$$user' >& /dev/null && \
    git config -f $config_file destination.password '$$password' >& /dev/null; then
    echo "Migration config file has been generated. Please replace text which start with \$\$."
  else
    die "\
Generate failed. Possible reasion: \n\
  1) git is NOT installed;\n\
  2) Parent directory of specified config file is NOT existed or has NO write permission."
  fi
}

function prepare_dump_directory {
  if [ "$CLEANUP" = "true" ]; then
    local md5=
    if [ "Darwin" = "$(uname -s)" ]; then
      md5="$(date +%s | md5)"
    elif [ "Linux" = "$(uname -s)" ]; then
      md5="$(date +%s | md5sum | awk '{print $1}')"
    else
      die "Unsupported OS."
    fi

    DUMP_DIRECTORY="/tmp/$(echo $ME | sed 's/\.sh$//g')-$(date +%s)"
    if ! mkdir -p $DUMP_DIRECTORY >& /dev/null; then
      die "Can't create temporary directory for dump sql."
    fi

    trap "rm -rf $DUMP_DIRECTORY" SIGINT SIGQUIT EXIT
  else
    if ! (mkdir -p $DUMP_DIRECTORY >& /dev/null && [ -w $DUMP_DIRECTORY ]); then
      die "Can't create directory or for dump sql, or the directory has NO write permission."
    fi
    DUMP_DIRECTORY="$(cd $DUMP_DIRECTORY && pwd)"
  fi
}

function read_migration_config {
  local read_config="git config -f $1"
  if \
    SOURCE_MYSQL_HOST="$($read_config source.host)" && \
    SOURCE_MYSQL_PORT="$($read_config source.port)" && \
    SOURCE_MYSQL_USER="$($read_config source.user)" && \
    SOURCE_MYSQL_PASSWORD="$($read_config source.password)" && \
    DESTINATION_MYSQL_HOST="$($read_config destination.host)" && \
    DESTINATION_MYSQL_PORT="$($read_config destination.port)" && \
    DESTINATION_MYSQL_USER="$($read_config destination.user)" && \
    DESTINATION_MYSQL_PASSWORD="$($read_config destination.password)"; then
    echo "Read migration config success."
  else
    die "\
Read migration config failed. Possible reasion: \n\
  1) migration config file is NOT exist or has NO read permission.\n\
  2) Git is NOT installed or migration config file is NOT a legal git config file."
  fi

  local fields="SOURCE_MYSQL_HOST SOURCE_MYSQL_PORT SOURCE_MYSQL_USER SOURCE_MYSQL_PASSWORD \
                DESTINATION_MYSQL_HOST DESTINATION_MYSQL_PORT DESTINATION_MYSQL_USER DESTINATION_MYSQL_PASSWORD"
  for field in $fields; do
    if [ -z "$(eval echo \$$field)" ]; then
      die "Field($(echo $field | sed 's/_MYSQL_/\./g' | tr "[:upper:]" "[:lower:]")) of migration config is empty."
    fi
  done
}

function exec_sql_on_source_host {
  exec_sql \
    $SOURCE_MYSQL_HOST \
    $SOURCE_MYSQL_PORT \
    $SOURCE_MYSQL_USER \
    $SOURCE_MYSQL_PASSWORD \
    "$1"
}

function exec_sql_on_destination_host {
  exec_sql \
    $DESTINATION_MYSQL_HOST \
    $DESTINATION_MYSQL_PORT \
    $DESTINATION_MYSQL_USER \
    $DESTINATION_MYSQL_PASSWORD \
    "$1"
}

function exec_sql {
  local host="$1"
  local port="$2"
  local user="$3"
  local password="$4"
  local sql="$5"

  if ! which mysql >& /dev/null; then
    die "mysql client is NOT installed."
  fi

  mysql -h $host -P $port -u $user -p$password -e "$5"
}

function check_database_connection {
  if ! exec_sql_on_source_host "show databases;" >& /dev/null; then
    echo "Can't connect MySQL Server $SOURCE_MYSQL_HOST:$SOURCE_MYSQL_PORT"
  fi
  if ! exec_sql_on_source_host "show databases;" >& /dev/null; then
    echo "Can't connect MySQL Server $DESTINATION_MYSQL_HOST:$DESTINATION_MYSQL_PORT"
  fi
}

function dump_database {
  local database="$1"
  if ! which mysqldump >& /dev/null; then
    die "mysqldump is NOT installed."
  fi
  echo -n "Dumping database $database from ${SOURCE_MYSQL_HOST}:${SOURCE_MYSQL_PORT} ... "
  if mysqldump \
    -h $SOURCE_MYSQL_HOST \
    -P $SOURCE_MYSQL_PORT \
    -u $SOURCE_MYSQL_USER \
    -p$SOURCE_MYSQL_PASSWORD \
    $DUMP_OPS_NO_DATA \
    -R $database > $DUMP_DIRECTORY/${database}.sql 2> /dev/null; then
    echo "done" 
  else
    die "failed."
  fi
}

function import_database {
  local database="$1"
  echo -n "Importing database $database to ${DESTINATION_MYSQL_HOST}:${DESTINATION_MYSQL_PORT} ... "
  if exec_sql_on_destination_host "DROP DATABASE IF EXISTS ${database}; CREATE DATABASE \`${database}\` /*!40100 DEFAULT CHARACTER SET utf8 */; use ${database}; source ${DUMP_DIRECTORY}/${database}.sql;" 2> /dev/null; then
    echo "done" 
  else
    die "failed."
  fi
}

function main {
  local migration_config=
  local migration_databases=
  local has_opts=
  while getopts hg:f:d:ns: opt; do
    has_opts="true"
    case $opt in
    h)
      print_usage; exit
    ;;
    g)
      generate_migration_config $OPTARG; exit
    ;;
    f)
      migration_config="$OPTARG"
    ;;
    d)
      migration_databases="$OPTARG"
    ;;
    n)
      DUMP_OPS_NO_DATA="--no-data"
    ;;
    s)
      CLEANUP="false"
      DUMP_DIRECTORY="$OPTARG"
    ;;
    ?)
      print_usage && die
    ;;
    esac
  done

  if [ -z $has_opts ]; then
    print_usage && die
  fi

  prepare_dump_directory $OPTARG
  read_migration_config $migration_config
  check_database_connection
  for database in $migration_databases; do
    dump_database $database
    import_database $database
  done
  unset database
}

main "$@"
