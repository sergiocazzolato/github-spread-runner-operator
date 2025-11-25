#!/usr/bin/env python3

"""Operator Framework charm that creates LXD containers and installs GitHub runners."""
import logging
import subprocess
import shlex
import time
from pathlib import Path

from ops.charm import CharmBase
from ops.main import main
from ops.model import ActiveStatus, BlockedStatus, MaintenanceStatus

logger = logging.getLogger(__name__)


class GitHubRunnerLXDCharm(CharmBase):
    """ Charm to manage GitHub runners in LXD containers. """

    def __init__(self, *args):
        super().__init__(*args)
        self.framework.observe(self.on.config_changed, self._on_config_changed)

    def _run(self, cmd, check=True, capture_output=False):
        """Run a shell command locally and return CompletedProcess."""
        logger.debug("Running command: %s", cmd)
        if isinstance(cmd, (list, tuple)):
            proc = subprocess.run(cmd, check=check, capture_output=capture_output, text=True)
        else:
            proc = subprocess.run(shlex.split(cmd), check=check, capture_output=capture_output, text=True)
        return proc

    def _lxc_available(self):
        try:
            self._run(["lxc", "--version"], capture_output=True)
            return True
        except Exception as e:
            logger.warning("lxc not available: %s", e)
            return False

    def _container_exists(self, name):
        try:
            # "lxc info <name>" exits non-zero when missing
            self._run(["lxc", "info", name], capture_output=True)
            return True
        except Exception:
            return False

    def _containers_list(self):
        """Return a list of existing LXD container names."""
        try:
            result = self._run(["lxc", "list", "--format", "csv", "-c", "n"], capture_output=True)
            containers = result.stdout.strip().splitlines()
            return containers
        except Exception as e:
            logger.error("Failed to list LXD containers: %s", e)
            return []

    def _wait_for_network(self, name, timeout=120):
        start = time.time()
        while time.time() - start < timeout:
            try:
                # Try a simple command inside the container
                self._run(["lxc", "exec", name, "--", "hostname"], capture_output=True)
                return True
            except Exception:
                time.sleep(2)
        return False

    def _create_container(self, name, image="ubuntu:24.04"):
        logger.info("Creating LXD container: %s", name)
        self.unit.status = MaintenanceStatus(f"launching container {name}")
        try:
            # Launch with default profile, detach
            self._run(["lxc", "launch", image, name])
        except Exception as e:
            logger.error("Failed to launch container %s: %s", name, e)
            raise
        # Wait for container's init to be responsive
        if not self._wait_for_network(name):
            raise RuntimeError(f"container {name} did not become responsive in time")

    def _get_local_script_path(self, script_name):
        script_path = Path(__file__).parent.parent / "scripts" / script_name
        if not script_path.exists():
            raise FileNotFoundError(f"Script {script_name} not found in charm layer")
        return script_path

    def _push_file_to_container(self, name, local_path, remote_path):
        logger.info("Pushing file to container %s: %s -> %s", name, local_path, remote_path)
        self._run(["lxc", "file", "push", local_path, f"{name}{remote_path}"])

    def _bootstrap_runner_in_container(self, name, github_url, token, runner_name, labels,
                                       http_proxy=None, https_proxy=None, no_proxy=None):
        logger.info("Bootstrapping runner in %s", name)
        self.unit.status = MaintenanceStatus(f"bootstrapping runner in {name}")

        # Copy helper script into container
        script_local = self._get_local_script_path("register-runner.sh")
        # push script content via lxc file push (create tmp script)
        remote_path = f"/tmp/runner_bootstrap_{runner_name}.sh"

        try:
            self._push_file_to_container(name, str(script_local), remote_path)
        except Exception as e:
            # fallback: use lxc exec with a heredoc (less portable). For simplicity, rethrow.
            logger.error("Failed to push bootstrap script: %s", e)
            raise

        # Make executable and run script with env vars
        cmd = [
            "lxc",
            "exec",
            name,
            "--",
            "bash",
            "-lc",
            (f"chmod +x {remote_path} && "
             f"GITHUB_URL=\"{github_url}\" GITHUB_TOKEN=\"{token}\" "
             f"RUNNER_NAME=\"{runner_name}\" RUNNER_LABELS=\"{labels}\" "
             f"{'HTTP_PROXY=\"' + http_proxy + '\" ' if http_proxy else ''}"
             f"{'HTTPS_PROXY=\"' + https_proxy + '\" ' if https_proxy else ''}"
             f"{'NO_PROXY=\"' + no_proxy + '\" ' if no_proxy else ''}"
             f"{remote_path}")
        ]
        try:
            self._run(cmd)
        except Exception as e:
            logger.error("Bootstrap script failed inside %s: %s", name, e)
            raise

    def _get_name(self):
        # The unit name will be something like "my-app/0"
        app_name = self.model.unit.name.replace("/", "-")
        # The machine ID is the part after the slash
        if app_name is None:
            return None
        return app_name

    def _on_config_changed(self, event):
        cfg = self.model.config
        project_name = cfg.get("project_name")
        github_url = cfg.get("github_url")
        token = cfg.get("registration_token")
        try:
            count = int(cfg.get("runner_count") or 6)
        except Exception:
            count = 6
        prefix = cfg.get("runner_name_prefix") or "spread-agent"
        labels = cfg.get("runner_labels") or "spread-enabled"
        http_proxy = cfg.get("runner_http_proxy")
        https_proxy = cfg.get("runner_https_proxy")
        no_proxy = cfg.get("runner_no_proxy")
        app_name = self._get_name() or "local"

        if not token:
            self.unit.status = BlockedStatus("please set registration_token in charm config")
            return

        if not self._lxc_available():
            self.unit.status = BlockedStatus("lxc client not available on the unit; "
                                             "ensure LXD is installed and accessible")
            return

        # Init lxd if needed
        try:
            # Launch with default profile, detach
            self._run(["lxd", "init", "--auto"])
        except Exception as e:
            logger.error("Failed to init lxd: %s", e)
            raise

        # Create containers and bootstrap runners
        for i in range(1, count + 1):
            cname = f"{prefix}-{app_name}-{i}"
            if not self._container_exists(cname):
                try:
                    self._create_container(cname)
                except Exception as e:
                    logger.error("Failed creating container %s: %s", cname, e)
                    self.unit.status = BlockedStatus(f"failed to create container {cname}: {e}")
                    return
            else:
                logger.debug("Container %s already exists", cname)

            # Check whether runner is already configured by testing for a file marker
            try:
                check_cmd = ["lxc", "exec", cname, "--", "test", "-f", f"/var/lib/github-runner/{cname}.registered"]
                self._run(check_cmd, check=False)
                if self._run(check_cmd, check=False).returncode == 0:
                    logger.info("Runner already registered in %s; skipping", cname)
                    continue
            except Exception:
                # Non-fatal; we'll try to bootstrap
                pass

            runner_name = f"{prefix}-{i}"
            try:
                self._bootstrap_runner_in_container(cname, github_url, token, runner_name, labels,
                                                    http_proxy, https_proxy, no_proxy)
                # mark success
                mark_cmd = ["lxc", "exec", cname, "--", "bash", "-lc", 
                            f"mkdir -p /var/lib/github-runner && touch /var/lib/github-runner/{cname}.registered"]
                self._run(mark_cmd)
            except Exception as e:
                logger.error("Failed to bootstrap runner in %s: %s", cname, e)
                self.unit.status = BlockedStatus(f"failed bootstrapping runner in {cname}: {e}")
                return

        self.unit.status = ActiveStatus(f"{count} GitHub runners ready as {prefix}-1..{prefix}-{count}")


if __name__ == "__main__":
    main(GitHubRunnerLXDCharm)
