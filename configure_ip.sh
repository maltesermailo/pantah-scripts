sudo ip address add 192.168.2.1 dev enp2s0f0u3
sudo ip route add 192.168.2.15 dev enp2s0f0u3
ping -c 2 192.168.2.15
