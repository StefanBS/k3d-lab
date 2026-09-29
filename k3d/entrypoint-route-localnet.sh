#!/bin/sh
# k3d runs this at every start of a k3d Node, before k3s (see up.sh).
#
# k3d's DNS fix points the k3d Node's resolv.conf at the Lab network's gateway and DNATs
# that to Docker's embedded DNS on 127.0.0.11. Traffic from pods, CoreDNS included,
# arrives on a pod interface, and Linux drops it once rewritten to a loopback address
# unless route_localnet is on. Without this, pods can't resolve names outside the Lab,
# so ArgoCD can't reach Git.
set -eu
sysctl -w net.ipv4.conf.all.route_localnet=1
