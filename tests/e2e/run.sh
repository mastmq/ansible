#!/usr/bin/env bash
# End-to-end test: the real playbook against systemd containers, then a QoS 1
# message published on one edge and received on the other, which only works if
# both edges joined the cores and the durable stream is carrying traffic.
#
#   MAST_SRC   path to a mast checkout (default ../mast beside this repo)
#   KEEP=1     leave the containers running afterwards
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
src="${MAST_SRC:-$root/../mast}"
image="${E2E_IMAGE:-geerlingguy/docker-debian12-ansible:latest}"
net=mast-e2e
hosts=(core1 core2 core3 edge1 edge2 solo)

teardown() {
	for h in "${hosts[@]}" files; do docker rm -f "mast-e2e-$h" >/dev/null 2>&1 || true; done
	docker network rm "$net" >/dev/null 2>&1 || true
}
cleanup() { [[ "${KEEP:-0}" == 1 ]] || teardown; }
trap cleanup EXIT

arch="$(docker info --format '{{.Architecture}}')"
case "$arch" in
	x86_64 | amd64) goarch=amd64 ;;
	aarch64 | arm64) goarch=arm64 ;;
	*) echo "unsupported docker architecture $arch" >&2 && exit 1 ;;
esac

echo "==> building mast for linux/$goarch from $src"
mkdir -p "$here/.build"
(cd "$src" && CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" go build -trimpath -o "$here/.build/mast" ./cmd/mast)

# The standalone host installs the way a real one does, from a release
# archive checked against a checksum file, so package the build the way
# mast's release workflow does and serve it from a container.
release="$here/.build/release"
rm -rf "$release" && mkdir -p "$release/pkg"
cp "$here/.build/mast" "$release/pkg/mast"
tar -C "$release/pkg" -czf "$release/mast_e2e_linux_$goarch.tar.gz" mast
(cd "$release" && sha256sum "mast_e2e_linux_$goarch.tar.gz" 2>/dev/null || shasum -a 256 "mast_e2e_linux_$goarch.tar.gz") >"$release/mast_e2e_checksums.txt"

echo "==> starting containers"
teardown
docker network create "$net" >/dev/null
for h in "${hosts[@]}"; do
	# systemd as PID 1 needs the host's cgroup tree, writable.
	docker run -d --name "mast-e2e-$h" --hostname "mast-e2e-$h" --network "$net" \
		--privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
		"$image" /lib/systemd/systemd >/dev/null
done
docker run -d --name mast-e2e-files --network "$net" -v "$release:/srv:ro" -w /srv \
	python:3-alpine python -m http.server 8000 >/dev/null

# The collection is loaded by its FQCN, so put this checkout where Ansible
# looks for mastmq.mast.
collections="$here/.build/collections"
mkdir -p "$collections/ansible_collections/mastmq"
ln -sfn "$root" "$collections/ansible_collections/mastmq/mast"
# First, so this checkout shadows the copy ansible-lint leaves in
# ~/.ansible/collections. Not alone, though: community.docker, which the
# containers are reached through, is installed in the default locations, and
# a path naming only this directory hid it. That passed on a machine whose
# Ansible bundles community.docker and failed on the first CI run, which
# installs ansible-core alone.
export ANSIBLE_COLLECTIONS_PATH="$collections:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections:/usr/share/ansible/collections}"
export ANSIBLE_FORCE_COLOR=1

play() { ansible-playbook -i "$here/inventory/hosts.yml" "$root/playbooks/site.yml" "$@"; }

echo "==> first run: bootstrap"
play

echo "==> second run: must change nothing"
out="$(play | tee /dev/stderr)"
if grep -E 'changed=[1-9]' <<<"$out" >/dev/null; then
	echo "FAIL: second run was not idempotent" >&2
	exit 1
fi

echo "==> every role reads the limits it was given"
# mast ignores a key it does not read, so a block that rendered is not yet a
# block that applies; the resolved configuration is.
for h in mast-e2e-core1 mast-e2e-edge1 mast-e2e-solo; do
	got="$(docker exec "$h" /usr/local/bin/mast -c /etc/mast/mast.toml config show)"
	python3 -c 'import json,sys; c=json.load(sys.stdin); l=c["limits"]; assert l["max_connections"]==1000 and l["tenants"]["default"]["offline_queue"]==500 and c["obs"]["max_tenant_labels"]==100, l' <<<"$got" ||
		{ echo "FAIL: $h resolved limits as '$got'" >&2; exit 1; }
done

echo "==> core3 runs a core and an edge, each its own unit"
for unit in mast-core mast-edge; do
	docker exec mast-e2e-core3 systemctl is-active --quiet "$unit" || { echo "FAIL: $unit is not active on core3" >&2; exit 1; }
done
docker exec mast-e2e-core3 systemctl show -p MemoryMax --value mast-edge | grep -qx 536870912 ||
	{ echo "FAIL: mast-edge on core3 has no MemoryMax" >&2; exit 1; }
docker exec mast-e2e-core3 /usr/local/bin/mast-edge -c /etc/mast-edge/mast.toml config show |
	python3 -c 'import json,sys; c=json.load(sys.stdin); assert c["role"]=="edge" and c["nats"]["name"]=="mast-e2e-core3-edge", c["nats"]' ||
	{ echo "FAIL: core3's edge config is wrong" >&2; exit 1; }

echo "==> cross-edge QoS 1"
mqtt() { docker run --rm --network "$net" eclipse-mosquitto:2 "$@"; }
sub_out="$here/.build/sub.out"
docker run --rm --network "$net" eclipse-mosquitto:2 \
	mosquitto_sub -h mast-e2e-edge1 -t 'e2e/cross' -q 1 -C 1 -W 20 >"$sub_out" &
sub=$!
sleep 3
mqtt mosquitto_pub -h mast-e2e-edge2 -t 'e2e/cross' -q 1 -m 'across the fabric'
wait "$sub"
[[ "$(cat "$sub_out")" == 'across the fabric' ]] || { echo "FAIL: edge1 got '$(cat "$sub_out")'" >&2; exit 1; }

echo "==> QoS 1 from the edge beside a core to a separate edge"
docker run --rm --network "$net" eclipse-mosquitto:2 \
	mosquitto_sub -h mast-e2e-edge1 -t 'e2e/colocated' -q 1 -C 1 -W 20 >"$sub_out" &
sub=$!
sleep 3
mqtt mosquitto_pub -h mast-e2e-core3 -t 'e2e/colocated' -q 1 -m 'from beside a core'
wait "$sub"
[[ "$(cat "$sub_out")" == 'from beside a core' ]] || { echo "FAIL: edge1 got '$(cat "$sub_out")' from core3's edge" >&2; exit 1; }

echo "==> the admin API on a core sees a client an edge holds"
# A core holds no client, so an answer about one crossed the control plane
# from the edge that does, and the stats count both edges.
admin() { docker run --rm --network "$net" curlimages/curl:8.11.1 -s "$@"; }
token='e2e-admin-token-not-a-secret'
api="http://mast-e2e-core1:9091/v1/tenants/default"
docker run --rm --network "$net" eclipse-mosquitto:2 \
	mosquitto_sub -h mast-e2e-edge1 -i e2e-watcher -t 'e2e/admin' -q 1 -C 1 -W 30 >/dev/null &
sub=$!
sleep 3
got="$(admin -H "Authorization: Bearer $token" "$api/sessions/e2e-watcher")"
grep -q '"connected":true' <<<"$got" || { echo "FAIL: the core's view of e2e-watcher is '$got'" >&2; exit 1; }
got="$(admin -H "Authorization: Bearer $token" "$api/stats")"
grep -q '"nodes":3' <<<"$got" || { echo "FAIL: stats from the core are '$got', want all three edges answering" >&2; exit 1; }
got="$(admin -o /dev/null -w '%{http_code}' "$api/stats")"
[[ "$got" == 401 ]] || { echo "FAIL: a request without the token got $got" >&2; exit 1; }
mqtt mosquitto_pub -h mast-e2e-edge2 -t 'e2e/admin' -q 1 -m 'done'
wait "$sub"

echo "==> standalone QoS 1 with a retained message"
mqtt mosquitto_pub -h mast-e2e-solo -t 'e2e/solo' -q 1 -r -m 'kept'
got="$(mqtt mosquitto_sub -h mast-e2e-solo -t 'e2e/solo' -q 1 -C 1 -W 10)"
[[ "$got" == 'kept' ]] || { echo "FAIL: solo retained got '$got'" >&2; exit 1; }

echo "==> rolling restart after a config change"
play -e mast_log_level=debug

echo "==> cross-edge QoS 1 after the roll"
docker run --rm --network "$net" eclipse-mosquitto:2 \
	mosquitto_sub -h mast-e2e-edge2 -t 'e2e/again' -q 1 -C 1 -W 20 >"$sub_out" &
sub=$!
sleep 3
mqtt mosquitto_pub -h mast-e2e-edge1 -t 'e2e/again' -q 1 -m 'still here'
wait "$sub"
[[ "$(cat "$sub_out")" == 'still here' ]] || { echo "FAIL: edge2 got '$(cat "$sub_out")'" >&2; exit 1; }

echo "PASS"
