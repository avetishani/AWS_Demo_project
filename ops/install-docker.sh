#!/usr/bin/env bash
set -o errexit
set -o nounset

#-------------------------------------------------------------------------------
# Log a message.
#-------------------------------------------------------------------------------
function log() {
  echo 1>&2 "$@"
}

#-------------------------------------------------------------------------------
# Display an error message to standard error and then exit the script with a
# non-zero exit code.
#-------------------------------------------------------------------------------
function error() {
  echo 1>&2 "ERROR: $@"
  echo 1>&2
  usage
  exit 1
}

#-------------------------------------------------------------------------------
# Retry a command until it returns an exit code of zero.
#
# @param $* - The command to run.
#-------------------------------------------------------------------------------
function wait_until() {
    until "${@}"; do
        log "Command failed: ${*}"
        sleep 10
        log "Retrying."
    done
}

#-------------------------------------------------------------------------------
# Determine which region the currently running instance is in.
#-------------------------------------------------------------------------------
function get_ec2_instance_region() {
  /opt/aws/bin/ec2-metadata --availability-zone |
  cut -d" " -f2 |
  sed "s/.$//g"
}

#-------------------------------------------------------------------------------
# Install a package, retrying if it fails.
#-------------------------------------------------------------------------------
function yum_install() {
  local package="${1}"

  while ! yum install -y "${package}"; do
    log "Failed to install ${package}"
    sleep 15
    log "Trying again."
  done
}

#-------------------------------------------------------------------------------
# Build and run docker image
#-------------------------------------------------------------------------------
function install_dropwizard() {
  local version="${1}"

  yum_install docker
  service docker start
  aws s3 cp s3://30daysdevops/dropwizard/docker/Dockerfile Dockerfile
  aws s3 cp s3://30daysdevops/nick/release/dropwizard-example-${version}-SNAPSHOT.jar dropwizard.jar
  aws s3 cp s3://30daysdevops/nick/release/mysql.yml mysql.yml
  wait_until docker build -t dropwizard .
  docker run -d -p 8080:8080 dropwizard
}

#-------------------------------------------------------------------------------
# Install and configure the DataDog agent on the current instance.
#
# @param $1 - The API key to connect to DataDog with.
#-------------------------------------------------------------------------------
function install_datadog() {
  local region="${1}"
  local datadog_secret_name="${2}"
  local version="${3}"
  local environment="${4}"

  log "Installing jq..."
  yum_install jq
  log "Done."

  log "Getting Datadog API key from Secret Manager"
  local api_key=$(wait_until aws secretsmanager get-secret-value                     \
                                                --region ${region}                   \
                                                --secret-id ${datadog_secret_name}   \
                                                --output json                        \
                                                --version-stage AWSCURRENT |         \
                                                jq ".SecretString" -r |              \
                                                jq ".key" -r)
  log "Datadog API key is ${api_key}"

  log "Installing datadog-agent..."
  DD_API_KEY=${api_key} bash -c "$(curl -L https://raw.githubusercontent.com/DataDog/dd-agent/master/packaging/datadog-agent/source/install_agent.sh)"
  log "Done."

  log "Configuring datadog..."
  local tags=""
  tags="${tags:+${tags}, }service:dropwizard"
  tags="${tags:+${tags}, }version:${version}"
  tags="${tags:+${tags}, }environment:${environment}"

  cat > /etc/dd-agent/datadog.conf <<EOF
[Main]
dd_url: https://app.datadoghq.com
api_key: ${api_key}
tags: ${tags}
EOF
  log "Done."

  log "Starting datadog-agent..."
  service datadog-agent start
  log "Done."
}

#-------------------------------------------------------------------------------
# Install Dropwizard host
#-------------------------------------------------------------------------------
function main() {
  local region=$(get_ec2_instance_region)
  local version="0.0.1"
  local environment="qa"
  local datadog_secret_name="datadog_api_key"

    while [[ ${#} -gt 0 ]]; do
    case "${1}" in
      --datadog-secret-name)    datadog_secret_name="${2}"
                                shift 2 ;;
      --version)                version="${2}"
                                shift 2 ;;
      *)                        error Unrecognized option "${1}" ;;
    esac
  done

  install_dropwizard ${version}

  install_datadog ${region} ${datadog_secret_name} ${version} ${environment}
}

#exec &> >(logger -t "cloud_init" -p "local0.info")

main "${@}"
