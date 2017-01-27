#!/bin/bash 

# universal deploy script for jenkins->wildfly deployments
# dg@upstream
# 24.01.2017
# License: GPLv2

# variables
SSHUSER=""
SSHPASSWD=""
SERVER=""
CONTROLLER_CLI=""
CONTROLLER_HOST=""
CONTROLLER_PORT=""
HAPROXY_MGMT="0"


if ! [[ -x $(which sshpass) ]]; then
  echo "sshpass binary not found, exiting"
else
  SSHPASS="$(which sshpass)"
fi

if ! [[ -x $(which ssh) ]]; then
  echo "ssh binary not found, exiting"
else
  SSH="$(which ssh)"
fi

if ! [[ -x $(which scp) ]]; then
  echo "scp binary not found, exiting"
else
  SCP="$(which scp)"
fi

help(){
echo "
 wildfly-deploy.sh
  a post-build deploy script to deploy war files to jboss/wildfly

  options:
  -C   path to jboss or wildfly cli (on remote host,
         e.g.: /opt/wildfly/bin/jboss-cli.sh)
  -H   host of the wildfly console (e.g.: localhost)
  -P   port of the wildfly console (e.g.: 9990)
  -S   server to deploy to. can be specified multiple times,
         e.g.: -S server1 -S server2 ...
  -h   display help
  -u   ssh user to connect to server(s)
  -p   ssh password to connect to server(s)

  ## HAProxy Options ##

   if enabled with the '-e' switch, haproxy backend servers can
   be automatically disabled / re-enabled during deployment.
   the backend to operate on must be specified, the servernames
   will be taken from the '-S' parameters and must match the
   backend server names.

  -e   enable HAProxy management during Deployment
  -A   haproxy server name
  -a   haproxy control socket port (stats socket: level admin)
  -b   HTTP Backend
"
exit 0
}


# test arguments
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
     HAPROXY_BACKEND="${OPTARG}";;
  esac
done
shift $((OPTIND -1))


echo "## ** ENVIRONMENT ** ##

$(env | sort)

#####################
"
echo " ## ** DEPLOYMENT SUMMARY ** ##

 cli:         ${CONTROLLER_CLI}
 host:        ${CONTROLLER_HOST}
 port:        ${CONTROLLER_PORT}
 sshuser:     ${SSHUSER}
 sshpassword: ${SSHPASSWD}

 local artifact:  ${POM_ARTIFACTID}-${POM_VERSION}

 ssh:     ${SSH}
 scp:     ${SCP}
 sshpass: ${SSHPASS}

 deploy to:"
for server in ${SERVER[@]}; do
  echo "        - ${server}"
done  

if [[ "${HAPROXY_MGMT}" -ne 0 ]]; then
  TALK2HAPROXY="socat stdio tcp4-connect:${HAPROXY_HOST}:${HAPROXY_PORT}"
  echo "
 ## HAProxy Management during Deployment enabled ##
 HAProxy Host:    "${HAPROXY_HOST}"
 HAProxy Port:    "${HAPROXY_PORT}"
 HAProxy Backend: "${HAPROXY_BACKEND}"

 HAProxy Backend "${HAPROXY_BACKEND}" servers:
"
  echo "show servers state ${HAPROXY_BACKEND}" | ${TALK2HAPROXY} | grep "${HAPROXY_BACKEND}" | awk '{print "  backend: "$2,"  - server: "$4, "/ ip: "$5 }'

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
   starting deployment:\n"

  # copy new artifact to server(s)
  echo "  -- copy new artifact ${POM_ARTIFACTID}-${POM_VERSION} to server ${server}..."
  ${SSHPASS} -p ${SSHPASSWD} \
    ${SCP} -o StrictHostKeyChecking=no "${WORKSPACE}/target/${POM_ARTIFACTID}-${POM_VERSION}.${POM_PACKAGING}" \
    ${SSHUSER}@${server}:/tmp/
  if ! [[ $? -eq 0 ]]; then echo "copy failed, exiting"; exit 1; fi
  echo "  -- copy finished."

  # set haproxy backend server to MAINT

  if [[ "${HAPROXY_MGMT}" -ne 0 ]]; then
    echo "  -- setting server ${server} on HAProxy backend ${HAPROXY_BACKEND} to MAINT"
    echo "set server ${HAPROXY_BACKEND}/${server} state maint" | ${TALK2HAPROXY}
  fi

  # undeploy old artifact
  echo "  -- undeploying old artifact ${REMOTE_ARTIFACT} on ${server}"
  ${SSHPASS} -p ${SSHPASSWD} \
                  ${SSH} -o StrictHostKeyChecking=no \
                  ${SSHUSER}@${server} "${CONTROLLER_CLI} \
                    --connect \
                    --controller=${CONTROLLER_HOST}:${CONTROLLER_PORT} \
                    --commands='undeploy ${REMOTE_ARTIFACT}'"
  if ! [[ $? -eq 0 ]]; then echo "undeploy failed, exiting"; exit 1; fi
  echo "  -- undeployment of old artifact finished."

  # deploy new artifact
  echo "  -- start deployment of new artifact ${POM_ARTIFACTID}-${POM_VERSION}.${POM_PACKAGING} on ${server}"
   ${SSHPASS} -p ${SSHPASSWD} \
                  ${SSH} -o StrictHostKeyChecking=no \
                  ${SSHUSER}@${server} "${CONTROLLER_CLI} \
                    --connect \
                    --controller=${CONTROLLER_HOST}:${CONTROLLER_PORT} \
                    --commands='deploy /tmp/${POM_ARTIFACTID}-${POM_VERSION}.${POM_PACKAGING}'"
  if ! [[ $? -eq 0 ]]; then echo "deploy failed, exiting"; exit 1; fi
  echo -en "  -- deployment of new artifact ${POM_ARTIFACTID}-${POM_VERSION}.${POM_PACKAGING} on ${server} finished.\n\n"

  # set haproxy backend server to MAINT
  if [[ "${HAPROXY_MGMT}" -ne 0 ]]; then
    echo "  -- setting server ${server} on HAProxy backend ${HAPROXY_BACKEND} to READY"
    echo "set server ${HAPROXY_BACKEND}/${server} state ready" | ${TALK2HAPROXY}
  fi

done

echo "
 ###############################
 ## ** DEPLOYMENT FINISHED ** ##
 ###############################

 runtime: ${SECONDS} seconds
"

exit 0
