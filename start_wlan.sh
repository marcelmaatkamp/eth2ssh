#!/bin/bash
sysctl -w net.ipv4.conf.all.forwarding=1

# ---
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
# iptables -t nat -A PREROUTING -i wlan0 -p tcp --syn -j REDIRECT --to-ports 12346
# iptables -t nat -A PREROUTING -i wlan0 -p udp --dport 53 -j REDIRECT --to-ports 53
# iptables -t nat -A PREROUTING --in-interface eth0 -p tcp -j REDSOCKS

killall -9 wpa_supplicant hostapd dhcpd
ifconfig wlan0 down
iwconfig wlan0 power off
ifconfig wlan0 10.0.0.1/24
hostapd -B /etc/hostapd.conf
/etc/init.d/isc-dhcp-server start
# ---

# ---
# iptables -A FORWARD -o eth0 -i wlan0 -s 10.0.0.0/24 -m conntrack --ctstate NEW -j ACCEPT
# iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# iptables -t nat -F POSTROUTING
# iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
# ---

# ---
# ifconfig eth0 192.168.1.1/24 netmask 255.255.255.0
# iptables -A FORWARD -o wlan0 -i eth0 -s 192.168.1.1/24 -m conntrack --ctstate NEW -j ACCEPT
# iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# iptables -A POSTROUTING -t nat -j MASQUERADE
# ---

