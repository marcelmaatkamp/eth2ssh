#!/bin/sh

########################################################################
#
# Usage: via-ssh.sh [-v] [-d] [USER@]SERVER[:PORT]
#
#          -v       Provide verbose output.             
#          -d       Send all UDP on the DNS port 53 to 127.0.0.1.
#          USER     User name to use for SSH; default is current user.
#          SERVER   Server to use for SSH.
#          PORT     Port to use for SSH; default is 22.
#
# This experimental script illustrates the use redsocks to build a
# transparent SOCKS proxy that forces all TCP traffic to be routed
# over an encrypted SSH channel to a server.  To use this script, you
# must be able to execute as root on the local computer, and you must
# be using OpenSSH and iptables.
# 
# This script prints three IP addresses.  The first is the externally
# visible IP address when you start the script.  The second is the IP
# address after the script has activated the proxy; that address
# should correspond to your SSH server.  After you use Control-C to
# terminate the proxy, the script will terminate the connection to
# your SSH server and then print a final IP address, which should
# match the first.  If you use the "-v" (verbose) option, the script
# will also print the redsocks log and each of the major commands that
# it executes.
# 
# The proxy that this script creates only carries the TCP protocol.
# In particular, it does not carry the UDP (e.g., DNS, NTP) and ICMP
# (e.g., ping, traceroute) protocols.  You can use the proxy DNS
# server pdnsd with the "-mto" option to force TCP to be used for all
# DNS queries.  If you pass the "-d" option to this script, it will
# enable an iptables rule that redirects all UDP traffic on the DNS
# port (53) to the DNS server that is listening on 127.0.0.1:53, which
# should be pdnsd or equivalent.
# 
# CAUTION: Standard DNS queries over UDP do not travel on the
#          encrypted channel to your server and can be observed by a
#          local network monitor.  Thus it is possible for a network
#          monitor to observe the locations to which your TCP traffic
#          is sent (but not the content of that traffic).  If the
#          destinations of your TCP traffic are sensitive, do not use
#          this script unless you use pdnsd or some other DNS proxy to
#          convert DNS queries from UDP to TCP so those queries are
#          encrypted.
# 
# ------------------------------------------------------------------------
# 
# The script via-ssh.sh was written in 2011 by vitex from
# forum.tinycorelinux.net.
# 
# To the extent possible under law, the author(s) have dedicated all
# copyright and related and neighboring rights to this software to the
# public domain worldwide. This software is distributed without any
# warranty.
# 
# See http://creativecommons.org/publicdomain/zero/1.0/ for a copy of
# the CC0 Public Domain Dedication under which this work is
# distributed.
#
########################################################################

# Print usage information if there are no arguments on the command line.
[ "$#" = "0" ] && 
  echo 'Usage: via-ssh.sh [ -v ] [ -d ] [USER@]SERVER[:PORT]' && exit 1

# Process the command line parameters.
while [ "$#" != '0' ] ; do
  case "$1" in
    -v) VERBOSE=1 ; shift ;;
    -d) DNS=1 ; shift ;;
     *) SSH_PORT=${1##*:}
        SSH_USER_SERVER=${1%%:*}
        [ "$SSH_USER_SERVER" = "$SSH_PORT" ] && SSH_PORT=22 
        shift ;;
  esac
done

# Define various configuration parameters.
SOCKS_PORT=12345
REDSOCKS_TCP_PORT=$(expr $SOCKS_PORT + 1)
TMP=/tmp/via-ssh.sh ; mkdir -p $TMP
REDSOCKS_LOG=$TMP/redsocks.log
REDSOCKS_CONF=$TMP/redsocks.conf

# Verify that OpenSSH is installed.
ssh -V 2>&1 | grep -q OpenSSH || 
  { echo === You must install OpenSSH. ; exit 1 ; }

# Verify that iptables is installed.
sudo which iptables 1>/dev/null ||
  { echo === You must install iptables. ; exit 1 ; }

# Verify that redsocks is installed.
which redsocks 1>/dev/null ||
  { echo === You must install redsocks. ; exit 1 ; }

# Execute the command passed on the command line; print it if -v was specified.
CMD () {
  [ -n "$VERBOSE" ] && echo "+++ $@"
  "$@"
}

# Print the current IP address.
IPADDRESS () {
  local IP=$(wget -qO- http://checkip.dyndns.com | grep -o '[0-9.]*')
  echo $IP
}

# Activate OpenSSH, redsocks, and the iptables rules.
ACTIVATE () {
  # Start the OpenSSH SOCKS proxy.
  CMD ssh -fN -D $SOCKS_PORT -p $SSH_PORT $SSH_USER_SERVER || exit $?

  # Start redsocks.
  : >$REDSOCKS_LOG
  CMD redsocks -c $REDSOCKS_CONF -p /dev/null

  # Use iptables to direct all TCP traffic except 127.0.0.0/8 through the proxy.
  CMD sudo iptables -t nat -N REDSOCKS
  CMD sudo iptables -t nat -A REDSOCKS -d 127.0.0.0/8 -j RETURN
  CMD sudo iptables -t nat -A REDSOCKS \
                    -p tcp -j REDIRECT --to-ports $REDSOCKS_TCP_PORT
  CMD sudo iptables -t nat -A OUTPUT -p tcp -j REDSOCKS

  # If -d is specified, direct UDP DNS queries to 127.0.0.1:53, which should
  # be pdnsd (or equivalent) configured to convert UDP queries to TCP.
  [ -n "$DNS" ] && CMD sudo iptables -t nat -A OUTPUT -p udp --dport 53 \
                                     -j REDIRECT --to-ports 53
}

# Deactivate OpenSSH, redsocks, and the iptables rules.
DEACTIVATE () {
  # Terminate the redsocks and ssh processes.
  CMD pkill -f "redsocks -c $REDSOCKS_CONF -p /dev/null"
  CMD pkill -f "ssh .*-D $SOCKS_PORT"

  # Remove the iptables rules that were added to create the proxy.
  sudo iptables -t nat -L -n | 
         egrep -q 'REDIRECT .* udp .* dpt:53 .* ports 53' &&
    CMD sudo iptables -t nat -D OUTPUT -p udp --dport 53 \
                                     -j REDIRECT --to-ports 53
  CMD sudo iptables -t nat -D OUTPUT -p tcp -j REDSOCKS
  CMD sudo iptables -t nat -F REDSOCKS
  CMD sudo iptables -t nat -X REDSOCKS
}

# Define the trap handler that is used during UP processing.
QUIT () {
  # Clear the trap handlers.
  trap - INT TERM

  # Clean up.
  DEACTIVATE 1>/dev/null 2>&1
 
  # Terminate.
  exit 0
}

# Bring up the transparent proxy.
UP () {
  # Set a trap handler in case the user uses Control-C or KILL.
  trap QUIT INT TERM

  # Silently clean up in case some part of the previous execution failed.
  DEACTIVATE 1>/dev/null 2>&1

  # Build the redsocks configuration file.
  cat >$REDSOCKS_CONF <<EOF
    base {
	    log_info = on;
	    log = "file:$REDSOCKS_LOG";
	    daemon = on;
	    redirector = iptables;
    }
    redsocks {
	    local_ip = 127.0.0.1;
	    local_port = $REDSOCKS_TCP_PORT;
	    ip = 127.0.0.1;
	    port = $SOCKS_PORT;
	    type = socks5;
    }
EOF

  # Print the current IP address, activate the proxy, and then print
  # the new IP address, which should be different.
  echo ===
  echo === $(IPADDRESS) is your initial IP address.
  [ -n "$VERBOSE" ] && echo ===
  ACTIVATE
  echo ===
  echo === $(IPADDRESS) is your IP address after the proxy is activated.
  echo ===
  echo === Use Control-C to quit.
  echo ===
}

# Bring down the transparent proxy.
DOWN () {

  # Disable the special trap handling.
  trap - 0 INT TERM
  echo

  # Deactivate the proxy.
  DEACTIVATE

  # Print the current IP address, which should be the same as the original one.
  echo ===
  echo === $(IPADDRESS) is your IP address after the proxy is deactivated.
  echo ===

  # Terminate this script.
  exit 0
}

#----------------------------------------------------------------------------

# Start the transparent proxy.
UP

# Ensure that DOWN is executed following a normal exit, a Control-C, or TERM.
trap DOWN 0 INT TERM

# Wait for Control-C; display the redsocks log if in verbose mode.
if [ -n "$VERBOSE" ] ; then
  tail -f $REDSOCKS_LOG
else
  while true ; do sleep 10 ; done
fi

exit 0
