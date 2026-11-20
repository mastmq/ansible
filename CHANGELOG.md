# Changelog

## 0.1.3

Installs mast v0.3.2 by default, and waits on its `/readyz` instead of the NATS monitor's `/healthz` before moving to the next host. On a core and a standalone broker the answer is the same JetStream check as before. On an edge it is new: the edge is ready only while its leaf connection to the cores is up, so a rolling restart no longer moves on from an edge that listens on MQTT but cannot carry a message across the cluster. `/readyz` is on the metrics address (`mast_private_address:mast_metrics_port`), so monitoring needs that port as before.

`/readyz` first shipped in mast v0.3.2. The role refuses an older `mast_version` from a release rather than waiting the whole health timeout on a 404; to stay on an older broker, stay on collection 0.1.2. A `local` binary is not checked, so build it from v0.3.2 or later.

## 0.1.2

Installs mast v0.3.1 by default. From v0.3.0 the cores keep the offline queue for sleeping devices, so a device keeps its QoS 1 and 2 messages when the edge it last used is restarted. The role needs no new settings for it: the queue lives in the JetStream assets the core tier already holds.

## 0.1.1

Installs mast v0.2.0 by default. The `[session]` and `[fabric]` settings the role already renders are read from that release on; v0.1.0 ignored them.

## 0.1.0

First release. One role, `mastmq.mast.mast`, running mast as a systemd service in the all-in-one, core or edge role picked from the inventory, and `playbooks/site.yml`, which deploys cores, then waits for quorum, then rolls the edges one at a time.
