# Testing the github-spread-runner-operator Charm

## Requirements

This need to be executed in the host machine:

```
sudo snap install juju --classic
sudo snap install charmcraft --classic
sudo snap install lxd
sudo lxd init --auto
```

LXD is the recommended backend for local charm development.

## Bootstrap a local Juju controller

`juju bootstrap lxd <controller-name>`

This creates a local LXD-based controller and “default” model.

Optionally could be required to run:

`lxc network set lxdbr0 ipv6.address none`

## Adding a juju model

`juju add-model <model-name>`

## Build the charm

From the root of the project:

`charmcraft pack`

This produces: github-spread-runner-operator_*.charm

## Deploy the charm locally

`juju deploy ./github-spread-runner-operator_amd64.charm <unit-name> --config registration_token=<registration-token> --config runner_count=<number> --config runner_name_prefix=runner --config runner_labels=<label1,label2>`

## Check the status

`juju status`

Filter by unit:

`juju status <unit-name>`

## Check charm logs

`juju debug-log`

Filter by unit:

`juju debug-log --include <unit-name>`


## Access the charm unit

`juju ssh <unit-name>` or `juju ssh <machine-id>`

## Access the internal LXD runner container

```
lxc list
lxc shell <runner-container-name>
```

## Run custom charm actions

```
juju run-action <unit-name> update-proxy \
  http_proxy=http://10.0.0.1:3128 \
  https_proxy=http://10.0.0.1:3128 \
  no_proxy="127.0.0.1,localhost" \
  --wait
```

# Cleaning Up

In case the unit is in error status, before deleting it run:

`juju resolved --no-retry <unit-name>`

Destroy only the app:

`juju remove-application <application-name> --destroy-storage --force`

Or reset the entire model:

`juju destroy-model default --destroy-storage --force`

Or remove everything:

`juju kill-controller charm-dev --yes`

