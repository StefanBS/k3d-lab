#!/usr/bin/env bash
# Walks you through the Host steps only you can do: for now, reserving the Host's LAN
# address on the router. The GPU Node routes the Lab's subnet through it (ADR 0002),
# so it must never change. Saves it to .env as HOST_LAN_IP.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

env_file=$LAB_ROOT/.env

# What the Host uses to reach the LAN.
route=$(ip -4 route get 1.1.1.1)
iface=$(sed -n 's/.* dev \([^ ]*\).*/\1/p' <<<"$route")
lan_ip=$(sed -n 's/.* src \([0-9.]*\).*/\1/p' <<<"$route")
router=$(sed -n 's/.* via \([0-9.]*\).*/\1/p' <<<"$route")
mac=$(<"/sys/class/net/$iface/address")
connection=$(nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null) || connection=""

if [[ $(nmcli -g 802-11-wireless.cloned-mac-address connection show "$connection" 2>/dev/null) == random ]]; then
  die "'$connection' gets a new random MAC address on each connect, so no reservation can match it. Make it stable, then run this again:
  nmcli connection modify '$connection' 802-11-wireless.cloned-mac-address stable"
fi

cat <<EOF
Reserve the Host's LAN address on your router:

  interface    $iface (connection: ${connection:-none})
  address      $lan_ip
  MAC address  $mac (the one the router sees; NetworkManager keeps it for this network)
  router       http://$router

  1. Log in to the router's admin page (opening it now).
  2. Find its DHCP settings (often LAN → DHCP Server; the names vary by router).
  3. Add a reservation ("static lease", "manually assigned IP") for $mac → $lan_ip.
  4. Save or apply.

EOF
xdg-open "http://$router" >/dev/null 2>&1 || true # the URL is above if no browser opens

read -rp "Is the reservation saved? [y/N] " reply || true
[[ $reply == [Yy]* ]] || die "nothing saved; run 'just host-wizard' again once the reservation is in place"

# Replaces any HOST_LAN_IP line and keeps the rest of .env.
touch "$env_file"
sed -i '/^HOST_LAN_IP=/d' "$env_file"
echo "HOST_LAN_IP=$lan_ip" >>"$env_file"
log "Saved HOST_LAN_IP=$lan_ip to .env"
