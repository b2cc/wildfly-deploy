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
  -b   HTTP backend
