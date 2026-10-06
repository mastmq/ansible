<img src="https://raw.githubusercontent.com/mastmq/.github/main/assets/mark-256.png" alt="mast" width="88" align="right">

# ansible

Part of [mast](https://mastmq.github.io/), a multi-tenant MQTT broker built on core NATS.

An Ansible collection, `mastmq.mast`, that runs [mast](https://github.com/mastmq/mast) on virtual machines and bare metal under systemd. It deploys the same two shapes as the [Helm chart](https://github.com/mastmq/charts): a standalone broker, or a core tier holding Raft and the KV buckets with an edge tier of MQTT nodes joining it as NATS leaf nodes.

## Install

```console
$ ansible-galaxy collection install git+https://github.com/mastmq/ansible.git
```

Ansible 2.16 or later on the controller. The targets need systemd and Python 3; the role is tested on Debian 12 and written for any systemd distribution on amd64 or arm64.

## Use

The role a host plays comes from the inventory group it is in:

| Group | Role | What it runs |
| --- | --- | --- |
| `mast_core` | `core` | Raft and the KV buckets. Wants a stable address and a disk that survives |
| `mast_edge` | `edge` | the MQTT listeners, joined to every core as a leaf node. The tier you add machines to |
| `mast_standalone` | `all-in-one` | one process, file-backed storage, no cluster |

```yaml
# inventory.yml
all:
  children:
    mast_core:
      hosts:
        core-1: { mast_private_address: 10.0.1.11 }
        core-2: { mast_private_address: 10.0.1.12 }
        core-3: { mast_private_address: 10.0.1.13 }
    mast_edge:
      hosts:
        edge-1: { mast_private_address: 10.0.2.21 }
        edge-2: { mast_private_address: 10.0.2.22 }
```

```console
$ ansible-playbook -i inventory.yml mastmq.mast.site
```

`mastmq.mast.site` deploys the cores one at a time, waits for the tier to reach quorum, then rolls the edges one at a time. Run it again to upgrade or reconfigure: a core that was already running has to be fully caught up before the next one restarts, which is what keeps a majority through the whole roll, and an edge restarts only after the one before it is serving MQTT again. See [`examples/inventory`](examples/inventory) for a fuller starting point, and use the role directly as `mastmq.mast.mast` in a playbook of your own.

## Getting the binary

`mast_install_method: release` (the default) downloads `mast_<version>_linux_<arch>.tar.gz` from the [GitHub release](https://github.com/mastmq/mast/releases) for `mast_version` and checks it against the release's checksum file. `mast_install_method: local` copies `mast_binary_src` from the controller instead, for an air-gapped site or a build that has not been released:

```console
$ CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o mast ./cmd/mast
$ ansible-playbook -i inventory.yml mastmq.mast.site -e mast_install_method=local -e mast_binary_src=$PWD/mast -e mast_version=dev-$(git rev-parse --short HEAD)
```

Each version is unpacked into `/opt/mast/<version>` and `/usr/local/bin/mast` is a symlink to it, so a rollback is setting `mast_version` back and running the playbook again.

## What lands on a host

| Path | |
| --- | --- |
| `/etc/mast/mast.toml` | the configuration, owned by root and readable by the `mast` group. Checked by the binary with `mast config show` before it replaces the old one |
| `/etc/mast/mast.env` | auth headers and `mast_extra_env`, kept out of `mast.toml` so a diff in the Ansible output never prints a token |
| `/var/lib/mast` | JetStream's store, on core and all-in-one only. The one path that has to survive a reinstall |
| `/etc/systemd/system/mast.service` | runs as the unprivileged `mast` user, with `LimitNOFILE` raised and the filesystem read-only apart from the store |

## Network

**Only MQTT faces the world.** Routes (`6222`), leaf connections (`7422`), the NATS client port (`4222`), the NATS monitor (`8222`), metrics and pprof (`9090`) and the unauthenticated internal MQTT listener all bind to `mast_private_address`. None of them authenticate, which inside Kubernetes the cluster network covers and on a VM nothing does, so a firewall has to keep them to the nodes and the monitoring that need them:

| From | To | Port |
| --- | --- | --- |
| core | core | 6222 |
| edge | core | 7422 |
| monitoring | every node | 8222, 9090 |
| devices | edge, standalone | `mast_mqtt_port`, `mast_mqtt_ws_port` |

`mast_private_address` defaults to the address of the default route. On a machine with a public and a private interface that is usually the public one, so set it per host.

## Variables

Every variable is in [`roles/mast/defaults/main.yml`](roles/mast/defaults/main.yml) with a comment saying why it exists. They map one to one onto the broker's [`config.example.toml`](https://github.com/mastmq/mast/blob/main/configs/config.example.toml) and the chart's `values.yaml`. The ones most installations touch:

| Variable | Default | |
| --- | --- | --- |
| `mast_version` | `0.1.0` | the release to install |
| `mast_private_address` | default route's address | where the unauthenticated ports bind, and how peers reach this node |
| `mast_core_jetstream_replicas` | `3` | replication for the KV buckets; cannot exceed the number of cores |
| `mast_mqtt_port` | `1883` | |
| `mast_mqtt_tls_cert`, `mast_mqtt_tls_key` | | PEM content, so the key can live in ansible-vault |
| `mast_auth_mode` | `static` | `static`, `http` or `jwt`, as in the broker |
| `mast_auth_http_headers` | `{}` | sent with every auth request; written to `mast.env`, not `mast.toml` |
| `mast_auth_jwt_hmac_secret`, `mast_auth_jwt_public_key` | | exactly one in `jwt` mode, as content |
| `mast_session_expiry` | `24h` | |
| `mast_edge_serial` | `1` | how many edges `site` restarts at once |
| `mast_limit_nofile` | `1048576` | every connection is a file descriptor, and the usual 1024 caps an edge at a thousand devices |

Settings are flat variables rather than nested dicts, because Ansible replaces a dict instead of merging it: overriding one key of a nested default in `group_vars` would silently drop the rest.

## Development

```console
$ just lint   # ansible-lint (production profile) and yamllint
$ just e2e    # the real playbook against systemd containers
```

`just e2e` builds mast from a checkout beside this one (`MAST_SRC` to point elsewhere), starts three cores, two edges and a standalone broker as systemd containers, and runs `site` against them. It then requires a second run to change nothing, a QoS 1 message published on one edge to arrive on the other, a retained message to survive on the standalone, and the same cross-edge delivery after a rolling restart. `KEEP=1` leaves the containers up to poke at.

Apache 2.0.
