#!/bin/bash
KEY="/Users/magrani/Downloads/cros_temp/dell_key"
for IP in 192.168.15.11 192.168.15.9; do
  if ping -c 1 -W 1 "$IP" >/dev/null 2>&1; then
    echo "Conectando ao Dell via $IP na porta 2222..."
    exec ssh -i "$KEY" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$IP"
  fi
done
echo "Dell nao respondeu no cabo (192.168.15.11) nem no Wi-Fi (192.168.15.9)."
