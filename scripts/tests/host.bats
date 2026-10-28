#!/usr/bin/env bats
# What scripts/lib/host.sh reads about the Host, without the Host: ip answers its route to
# the LAN, and ss its listening sockets.

setup() {
  load lab
  # shellcheck source=../lib/host.sh
  source "$BATS_TEST_DIRNAME/../lib/host.sh"
}

# ip answers the route to the LAN, through the Host's address 192.0.2.10.
ip() {
  [[ $* == "-4 route get 1.1.1.1" ]] || return 1
  echo "1.1.1.1 via 192.0.2.1 dev enp5s0 src 192.0.2.10 uid 1000"
  echo "    cache"
}

@test "LAN address: the source address of the Host's route out" {
  run host_lan_ip
  [[ $status -eq 0 ]]
  [[ $output == 192.0.2.10 ]]
}

@test "HOST_LAN_IP is the Host's address: succeeds, saying nothing" {
  HOST_LAN_IP=192.0.2.10
  run host_lan_ip_current
  [[ $status -eq 0 ]]
  [[ -z $output ]]
}

@test "HOST_LAN_IP isn't the Host's address, or isn't set: fails, saying how" {
  HOST_LAN_IP=192.0.2.99
  run host_lan_ip_current
  [[ $status -eq 1 ]]
  [[ $output == "HOST_LAN_IP in .env (192.0.2.99) isn't the Host's address (192.0.2.10)" ]]
  unset HOST_LAN_IP
  run host_lan_ip_current
  [[ $status -eq 1 ]]
  [[ $output == "HOST_LAN_IP in .env (unset) isn't the Host's address (192.0.2.10)" ]]
}

@test "ports taken: the local address of each socket listening on the Gateway's ports" {
  ss() {
    [[ $* == "-ltnH ( sport = :80 or sport = :443 )" ]] || return 1
    echo "LISTEN 0      4096         0.0.0.0:443        0.0.0.0:*"
    echo "LISTEN 0      511             [::]:80            [::]:*"
  }
  run lab_host_ports_taken
  [[ $status -eq 0 ]]
  [[ $output == "0.0.0.0:443
[::]:80" ]]
}
