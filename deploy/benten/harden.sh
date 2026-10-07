#!/bin/sh
# Run over the verified SSH connection to VM9502 only.
set -eu
admin_ip=${SSH_CONNECTION%% *}
case "$admin_ip" in 192.168.1.*) ;; *) echo 'Unexpected administration source'; exit 1 ;; esac
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/80-chat-overlay.conf <<'SSH'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
SSH
sshd -t
systemctl reload ssh
cat > /etc/nftables.conf <<NFT
#!/usr/sbin/nft -f
table inet chat_overlay_guard {
  chain input {
    type filter hook input priority 0; policy drop;
    iifname "lo" accept
    ct state established,related accept
    ip saddr { $admin_ip, 192.168.1.101 } tcp dport 22 accept
    udp sport 67 udp dport 68 accept
    ip protocol icmp accept
    meta l4proto ipv6-icmp accept
  }
  chain forward {
    type filter hook forward priority -20; policy accept;
    ip saddr 192.168.1.112 ip daddr { 172.30.96.0/28, 172.30.97.0/28 } tcp dport 4100 accept
    # Also block LAN access to Docker loopback-published ports on older engines.
    iifname "eth0" ct state new drop
  }
}
NFT
nft -c -f /etc/nftables.conf
nft -f /etc/nftables.conf
systemctl enable nftables
printf 'Dedicated guest SSH and ingress restrictions applied.\n'
