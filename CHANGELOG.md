# Changelog

## 0.1.0

First release. One role, `mastmq.mast.mast`, running mast as a systemd service in the all-in-one, core or edge role picked from the inventory, and `playbooks/site.yml`, which deploys cores, then waits for quorum, then rolls the edges one at a time.
