#!/usr/bin/env bash

# universal deploy script for jenkins->wildfly deployments
# b2c@dest-unreachable.net
# 30.01.2017
# License: GPLv2

SSHUSER=""
SSHPASSWD=""
SERVER=""
CONTROLLER_CLI=""
CONTROLLER_HOST=""
CONTROLLER_PORT=""
HAPROXY_MGMT="0"
HAPROXY_HOST=""
HAPROXY_PORT=""
HAPROXY_BACKEND=""

help(){
echo "
 wildfly-deploy.sh
  a post-build deploy script to deploy war files to jboss/wildfly

  requires: sshpass, scp, ssh
  optional: socat (for haproxy management during deployment)

  options:
  -C   path to jboss or wildfly cli (on remote host,
         e.g.: /opt/wildfly/bin/jboss-cli.sh)
  -H   host of the wildfly console (on remote host, e.g.: localhost)
  -P   port of the wildfly console (on remote host, e.g.: 9990)
  -S   remote server(s) to deploy to. can be specified multiple times,
         e.g.: -S server1 -S server2 ...
  -h   display help
  -u   ssh user to connect to remote server(s)
  -p   ssh password to connect to remote server(s)

  ## HAProxy Options ##

  if enabled with the '-e' switch, haproxy backend servers can
  be automatically disabled / re-enabled during deployment.
  the backend to operate on must be specified, the servernames
  will be taken from the '-S' parameter which must match the
  server names configured in the haproxy backend.

  -e   enable HAProxy management during deployment
  -A   haproxy server name / IPv4 address
  -a   haproxy control socket port (stats socket: level admin)
  -b   HTTP backend(s) to en/disable. can be specified multiple times,
        e.g.: -b http_app1 -b http_app2 ...
"
exit 0
}

if (($# == 0)); then
  echo "
         missing arguments, exiting.
       "
  help
  exit 1
fi

while getopts "C:H:P:S:hu:p:eA:a:b:" opt; do
  case "${opt}" in
    C)
     CONTROLLER_CLI="${OPTARG}";;

    H)
     CONTROLLER_HOST="${OPTARG}";;

    P)
     CONTROLLER_PORT="${OPTARG}";;

    S)
     SERVER+=("${OPTARG}");;

    h)
     help;;

    u)
     SSHUSER="${OPTARG}";;

    p)
     SSHPASSWD="${OPTARG}";;

    e)
     HAPROXY_MGMT="1";;

    A)
     HAPROXY_HOST="${OPTARG}";;

    a)
     HAPROXY_PORT="${OPTARG}";;

    b)
     HAPROXY_BACKEND+=("${OPTARG}");;
  esac
done
shift $((OPTIND -1))

BINARIES=(sshpass ssh scp)
for binary in "${BINARIES[@]}" ; do
  if ! [[ -x $(which ${binary} 2>/dev/null) ]]; then
    echo "${binary} binary not found, exiting."
    exit 1
  fi
done

SSHPASS="$(which sshpass)"
SSH="$(which ssh)"
SCP="$(which scp)"

echo "## ** ENVIRONMENT ** ##

$(env | sort)

#####################
"
echo " ## ** DEPLOYMENT SUMMARY ** ##

 cli:         ${CONTROLLER_CLI}
 host:        ${CONTROLLER_HOST}
 port:        ${CONTROLLER_PORT}
 sshuser:     ${SSHUSER}
 sshpassword: ********

 local artifact:  ${POM_ARTIFACTID}-${POM_VERSION}

 deploy to:"
for server in ${SERVER[@]}; do
  echo "        - ${server}"
done

if [[ "${HAPROXY_MGMT}" -ne 0 ]]; then
  if ! [[ -x $(which socat 2>/dev/null) ]]; then
    echo "socat binary not found, exiting."
    exit 1
  else
    SOCAT="$(which socat)"
  fi

  TALK2HAPROXY="${SOCAT} stdio tcp4-connect:${HAPROXY_HOST}:${HAPROXY_PORT}"
  echo "
 ## HAProxy Management during Deployment enabled ##
 HAProxy Host:    ${HAPROXY_HOST}
 HAProxy Port:    ${HAPROXY_PORT}
"
  for haproxybackend in ${HAPROXY_BACKEND[@]}; do
    echo " HAProxy Backend: ${haproxybackend}"
    echo "  HAProxy Backend ${haproxybackend} servers:"
    echo "show servers state ${haproxybackend}" \
      | ${TALK2HAPROXY} \
      | grep ${haproxybackend} \
      | awk '{print "   backend: "$2,"  - server: "$4, "/ ip: "$5 }'
  done
fi

echo "
 ###############################
 ## ** DEPLOYMENT STARTED  ** ##
 ###############################
"

for server in ${SERVER[@]}; do

  # determine remote artifact
  REMOTE_ARTIFACT=$( ${SSHPASS} -p ${SSHPASSWD} \
                       ${SSH} -o StrictHostKeyChecking=no \
                       ${SSHUSER}@${server} "${CONTROLLER_CLI} \
                       --connect \
                       --controller=${CONTROLLER_HOST}:${CONTROLLER_PORT} \
                       --commands='ls deployment' \
                       | grep ${POM_ARTIFACTID}"
                   )
  echo -en "\n
 - remote server ${server} currently deployed artifact: ${REMOTE_ARTIFACT}

 - starting deployment:\n"

  # copy new artifact to server(s)
  echo "  -- copy new artifact ${POM_ARTIFACTID}-${POM_VERSION} to server ${server} /tmp..."
  ${SSHPASS} -p ${SSHPASSWD} \
                  ${SCP} -o StrictHostKeyChecking=no "${WORKSPACE}/target/${POM_ARTIFACTID}-${POM_VERSION}.${POM_PACKAGING}" \
                  ${SSHUSER}@${server}:/tmp/
  if ! [[ $? -eq 0 ]]; then echo "copy failed, exiting."; exit 1; fi
  echo "  -- copy finished."

  # set haproxy backend server to MAINT
  # TODO: wait until all clients have migrated to other server
  #       in case of multi-server deployment
  if [[ "${HAPROXY_MGMT}" -ne 0 ]]; then
    for haproxybackend in ${HAPROXY_BACKEND[@]}; do
      echo -en "  -- setting server ${server} on HAProxy backend ${haproxybackend} to MAINT"
      echo "set server ${haproxybackend}/${server} state maint" | ${TALK2HAPROXY}
    done
  fi

  # undeploy old artifact
  echo "  -- undeploying old artifact ${REMOTE_ARTIFACT} on ${server}"
  ${SSHPASS} -p ${SSHPASSWD} \
                  ${SSH} -o StrictHostKeyChecking=no \
                  ${SSHUSER}@${server} "${CONTROLLER_CLI} \
                  --connect \
                  --controller=${CONTROLLER_HOST}:${CONTROLLER_PORT} \
                  --commands='undeploy ${REMOTE_ARTIFACT}' 2>&1 >/dev/null"
  if ! [[ $? -eq 0 ]]; then echo "undeploy failed, exiting."; exit 1; fi
  echo "  -- undeployment of old artifact finished."

  # deploy new artifact
  echo "  -- start deployment of new artifact ${POM_ARTIFACTID}-${POM_VERSION}.${POM_PACKAGING} on ${server}"
  ${SSHPASS} -p ${SSHPASSWD} \
                  ${SSH} -o StrictHostKeyChecking=no \
                  ${SSHUSER}@${server} "${CONTROLLER_CLI} \
                  --connect \
                  --controller=${CONTROLLER_HOST}:${CONTROLLER_PORT} \
                  --commands='deploy /tmp/${POM_ARTIFACTID}-${POM_VERSION}.${POM_PACKAGING}'"
  if ! [[ $? -eq 0 ]]; then echo "deploy failed, exiting."; exit 1; fi
  echo -en "  -- deployment of new artifact ${POM_ARTIFACTID}-${POM_VERSION}.${POM_PACKAGING} on ${server} finished.\n\n"

  # cleanup
  echo "  -- removing temporary copy of ${POM_ARTIFACTID}-${POM_VERSION}.${POM_PACKAGING} on ${server} from /tmp"
  ${SSHPASS} -p ${SSHPASSWD} \
                  ${SSH} -o StrictHostKeyChecking=no \
                  ${SSHUSER}@${server} "rm -f /tmp/${POM_ARTIFACTID}-${POM_VERSION}.${POM_PACKAGING}"

  # set haproxy backend server to READY
  if [[ "${HAPROXY_MGMT}" -ne 0 ]]; then
    for haproxybackend in ${HAPROXY_BACKEND[@]}; do
      echo -en "  -- setting server ${server} on HAProxy backend ${haproxybackend} to READY"
      echo "set server ${haproxybackend}/${server} state ready" | ${TALK2HAPROXY}
    done
  fi

done

echo "
 ###############################
 ## ** DEPLOYMENT FINISHED ** ##
 ###############################

 runtime: ${SECONDS} seconds
"

exit 0
