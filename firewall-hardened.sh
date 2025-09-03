# Flush everything
iptables -F
ip6tables -F

# Default drop
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT

# Allow established/related
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow Tailscale UDP
iptables -A INPUT -p udp --dport 41641 -j ACCEPT
ip6tables -A INPUT -p udp --dport 41641 -j ACCEPT

# (Optional) allow inbound SSH (if you want NAT IPv4 port forward)
# iptables -A INPUT -p tcp --dport 22 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT

# Persistence
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6


