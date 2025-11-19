# github-spread-runner-operator
github-spread-runner-operator - charm repository.

This charm will create `runner_count` LXD containers on the machine where it is deployed and install a GitHub Actions runner into each one.

## Requirements
- The unit must run on a host with `lxc` installed and the unit must have permission to run `lxc` commands.
- Provide a valid GitHub registration token via `juju config registration_token="<token>"`. Tokens are short-lived (usually 1 hour when created via the UI) — see GitHub docs for how to create a registration token for an org/repo.

## Deploy
```
juju deploy ./path/to/charm --series noble
juju config github-spread-runner-operator github_url="https://github.com/owner/repo" registration_token="<token>" runner_count=6
```

