# ansible

The Ansible collection `mastmq.mast`: mast on virtual machines and bare metal, under systemd. It is the VM counterpart of `mastmq/charts`, and deploys the same two shapes — standalone, or a core tier with edges joining it as leaf nodes.

One role, `roles/mast`, and one playbook, `playbooks/site.yml`. A host's role comes from its inventory group (`mast_core`, `mast_edge`, anything else is all-in-one), not from a variable someone has to remember to set.

## Keep it in step with the chart and the broker

**A config field** in `mastmq/mast` → a variable in `defaults/main.yml` with a comment saying why it exists, a line in `templates/mast.toml.j2` under every role it applies to, and a row in the README if people will touch it. The template may only write keys that exist in `mast/configs/config.example.toml`: the broker ignores a key it does not read, silently. The `validate:` on the template catches a TOML syntax error and nothing more.

**Something the chart learned the hard way** usually applies here too, translated. The chart names each pod so leaf connections do not evict each other; here `mast_nats_name` is the inventory hostname for the same reason. The chart's startup/liveness/readiness split is `tasks/health.yml`. The chart's PDBs are `serial: 1` in `site.yml`.

## Things learned by failing

**A role default is invisible through another host's `hostvars`.** Only inventory and facts are. The config template names every core by address, so it falls back from `hostvars[h].mast_private_address` to that host's `default_ipv4` fact, and preflight gathers facts from the cores when a run did not reach them (`--limit edge-1`, or `serial: 1` reaching core-1 before core-2).

**A lone new core cannot pass the full `/healthz`.** It checks JetStream, which needs quorum, and during a first deploy with `serial: 1` the peers are the hosts after it. So a core waits for its own server only when it was not running before the play, and for full JetStream health when it was — that second case is a rolling restart, where moving on before a peer has caught up is how two of three go down at once. `site.yml` then waits for quorum on the whole tier before any edge.

**The restart handler skips a node that was not running.** The service task has just started it with the new everything; restarting it again would cost a core its first JetStream restore twice.

**Flat variables, not nested dicts.** Ansible replaces a dict rather than merging it, so a user overriding one key of `mast_auth.http` in `group_vars` would drop the rest without a warning.

**ansible-lint copies the collection into `~/.ansible/collections`** when it runs, and that copy then shadows the checkout for every later `ansible-playbook`. `tests/e2e/run.sh` sets `ANSIBLE_COLLECTIONS_PATH` so the e2e test always runs the working tree.

## Testing

```console
$ just lint   # ansible-lint --profile production, yamllint
$ just e2e    # systemd containers, three cores, two edges, one standalone
```

`just e2e` builds mast from `../mast` and is the test that matters: bootstrap, a second run with `changed=0`, QoS 1 across two edges, retained on standalone, then a rolling restart and QoS 1 again. It needs Docker with cgroup v2; on macOS, colima works.

## Conventions

Conventional commits (`feat(role):`, `fix(role):`, `ci:`, `docs:`), body explaining why. Markdown one paragraph per line. Comments in YAML explain why a thing is the way it is, as in the chart's `values.yaml`.
