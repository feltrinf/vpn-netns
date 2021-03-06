#!/bin/bash

# Guess the outgoing interface from default route
: ${natiface=$(ip route show to 0/0 |
	       sed -n '/^default/{s/.* dev \([^ ]*\).*/\1/p;q}')}
	       
: ${snat_addr=$(ip addr show ${natiface} |
	       sed -n 's/.*inet \([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')}
	       
# Spawn or attach to a tmux server running in the network namespace
attach()
{
  #name=${1-vpn}
  if [ $UID -ne 0 ]; then
    exec tmux -L $name attach
  else
    exec ip netns exec $name su -c "exec tmux -L $name new -A -n $name" $SUDO_USER
  fi
}

# Set up a network namespace
start()
{
  #name=${1-vpn}
  addrbase=${2-172.31.99}

  # Create a virtual ethernet pair device to let the namespace reach us
  ip link add $name.1 type veth peer name $name.2

  # Find the last used address in the network 
  last_addr=$(ip addr show to $addrbase.0/16 |
    sed -n 's/.*inet \([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\).*/\1/p'| sort -r)

  last_addr=$(cut -d " " -f 1 <<<$last_addr)

  # Get next available pair of addresses
  if [ "$last_addr" = "" ]; then
	host_addr=$addrbase.1
  else
	host_addr="${last_addr%.*}.$((${last_addr##*.} + 2))"
  fi

  peer_addr="${host_addr%.*}.$((${host_addr##*.} + 1))"

  # Set up our end of the veth device
  #ip addr add $addrbase.1 peer $addrbase.2 dev $name.1
  ip addr add $host_addr peer $peer_addr dev $name.1
  ip link set $name.1 up

  # Basic NAT
  #iptables -t nat -A POSTROUTING -s $addrbase.2 -o $natiface -j MASQUERADE
  
  # https://wiki.strongswan.org/projects/strongswan/wiki/ForwardingAndSplitTunneling
  iptables -t nat -A POSTROUTING -s $peer_addr/32 -o $natiface -m policy --dir out --pol ipsec -j ACCEPT
  iptables -t nat -A POSTROUTING -s $peer_addr/32 -o $natiface -j SNAT --to-source $snat_addr 

  # Create custom resolv.conf for the namespace
  mkdir -p /etc/netns/$name
  sed /127.0.0.1/d </etc/resolv.conf >/etc/netns/$name/resolv.conf

  # in case Strongswan is used in this namespace
  # https://wiki.strongswan.org/projects/strongswan/wiki/Netns
  mkdir -p /etc/netns/$name/ipsec.d/run

  # custom ipsec configuration, if any
  mkdir -p /etc/netns/$name/ipsec.d/cacerts
  mkdir -p /etc/netns/$name/ipsec.d/config
  
  # Create the namespace itself
  ip netns add $name

  # Hand off the other end of the veth device to the namespace
  ip link set $name.2 netns $name

  # Set up networking in the namespace
  ip netns exec $name bash -c "
    #ip addr add $addrbase.2 peer $addrbase.1 dev $name.2
    ip addr add $peer_addr peer $host_addr dev $name.2
    ip link set $name.2 up
    #ip route add default via $addrbase.1
    ip route add default via $host_addr
    ip link set lo up"

  # Create a tmux session in the namespace and attach to it
  attach $1
}

# Tear down a previously created network namespace
stop()
{
  #name=${1-vpn}
  #addrbase=$(ip addr show $name.1 |
  #  sed -n 's/.*inet \([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')
  pids=$(ip netns pids $name)

  # Refuse further operation if some processes are still running there
  if [ -n "$pids" ]; then
    echo "namespace still in use by:"
    ps $pids
    exit 1
  fi

  # Get the exact peer address
  host_addr=$(ip addr show $name.1 |
    sed -n 's/.*inet \([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')

  peer_addr="${host_addr%.*}.$((${host_addr##*.} + 1))"

  ip link del $name.1
  #iptables -t nat -D POSTROUTING -s $addrbase.2 -o $natiface -j MASQUERADE
  iptables -t nat -D POSTROUTING -s $peer_addr/32 -o $natiface -j SNAT --to-source $snat_addr 
  iptables -t nat -D POSTROUTING -s $peer_addr/32 -o $natiface -m policy --dir out --pol ipsec -j ACCEPT
  
  ip netns del $name
}

command="$1"
shift
name=${1-vpn}

case "$command" in
  "start" | "stop" | "attach")
    "$command" "$@"
    ;;
  *)
    echo "usage: $0 {start | stop | attach} [vpn-name] [vpn-addr-base]"
esac
