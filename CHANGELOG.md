# Changelog

## 0.2.0

Installs mast v0.4.0 by default, and can turn on the three things that release adds. Each one is off, or at mast's own default, unless you set it, and the role writes its block to `mast.toml` only then, so upgrading the collection alone leaves the file unchanged and restarts nothing.

- **Per-tenant limits** with `mast_limits_*`: a connection limit across the cluster, a publish rate per node, and the size of each absent session's queue, with overrides for named tenants in `mast_limits_tenants`. An over-rate MQTT 5 QoS 1 publish gets PUBACK 0x97.
- **The admin API** with `mast_admin_enabled`, bound to `mast_private_address` on `mast_admin_port`. The role writes `mast_admin_token` to a file of its own, readable only by root and the mast group, because mast reads its token from a file and never from `mast.toml`. Keep the token in ansible-vault.
- **OpenTelemetry tracing** with `mast_tracing_*`. `mast_tracing_otlp_headers` goes to `mast.env`, not `mast.toml`, for a collector that wants an API key.

mast v0.4.0 also bounds what a device that returns to the node it left is resent, by `mast_limits_offline_queue` (100). Before, it got everything the broker held for it. Raise `mast_limits_offline_queue` to keep more.

## 0.1.3

Installs mast v0.3.2 by default, and waits on its `/readyz` instead of the NATS monitor's `/healthz` before moving to the next host. On a core and a standalone broker the answer is the same JetStream check as before. On an edge it is new: the edge is ready only while its leaf connection to the cores is up, so a rolling restart no longer moves on from an edge that listens on MQTT but cannot carry a message across the cluster. `/readyz` is on the metrics address (`mast_private_address:mast_metrics_port`), so monitoring needs that port as before.

`/readyz` first shipped in mast v0.3.2. The role refuses an older `mast_version` from a release rather than waiting the whole health timeout on a 404; to stay on an older broker, stay on collection 0.1.2. A `local` binary is not checked, so build it from v0.3.2 or later.

## 0.1.2

Installs mast v0.3.1 by default. From v0.3.0 the cores keep the offline queue for sleeping devices, so a device keeps its QoS 1 and 2 messages when the edge it last used is restarted. The role needs no new settings for it: the queue lives in the JetStream assets the core tier already holds.

## 0.1.1

Installs mast v0.2.0 by default. The `[session]` and `[fabric]` settings the role already renders are read from that release on; v0.1.0 ignored them.

## 0.1.0

First release. One role, `mastmq.mast.mast`, running mast as a systemd service in the all-in-one, core or edge role picked from the inventory, and `playbooks/site.yml`, which deploys cores, then waits for quorum, then rolls the edges one at a time.
