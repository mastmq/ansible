# Changelog

## 0.1.2

Installs mast v0.3.1 by default. From v0.3.0 the cores keep the offline queue for sleeping devices, so a device keeps its QoS 1 and 2 messages when the edge it last used is restarted. The role needs no new settings for it: the queue lives in the JetStream assets the core tier already holds.

## 0.1.1

Installs mast v0.2.0 by default. The `[session]` and `[fabric]` settings the role already renders are read from that release on; v0.1.0 ignored them.

## 0.1.0

First release. One role, `mastmq.mast.mast`, running mast as a systemd service in the all-in-one, core or edge role picked from the inventory, and `playbooks/site.yml`, which deploys cores, then waits for quorum, then rolls the edges one at a time.
