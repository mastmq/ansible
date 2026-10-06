default:
    @just --list

lint:
    ansible-lint
    yamllint .

# The playbook against systemd containers, with a mast built from ../mast.
e2e:
    tests/e2e/run.sh

build:
    ansible-galaxy collection build --force
