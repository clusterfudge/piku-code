"""
piku-code: VS Code Tunnel Integration for Piku

A piku plugin that enables opening VS Code connected to a remote piku app's
filesystem via VS Code Tunnels.

This plugin provides server-side commands for managing VS Code tunnels.
"""

import os
import signal
import subprocess
import sys
import hashlib
import time
from pathlib import Path

import click

# Piku directories
PIKU_HOME = os.environ.get("PIKU_HOME", os.path.expanduser("~/.piku"))
PIKU_APPS = os.path.join(PIKU_HOME, "apps")
PIKU_DATA = os.path.join(PIKU_HOME, "data")

# VS Code CLI path
CODE_CLI = os.path.expanduser("~/bin/code")

# Debug mode
DEBUG = os.environ.get("PIKU_CODE_DEBUG", "").lower() in ("1", "true", "yes")


def debug(msg: str) -> None:
    """Print debug message if debug mode is enabled."""
    if DEBUG:
        click.echo(f"[DEBUG] {msg}", err=True)


def get_app_data_dir(app: str) -> Path:
    """Get or create the data directory for an app."""
    data_dir = Path(PIKU_DATA) / app
    data_dir.mkdir(parents=True, exist_ok=True)
    return data_dir


def get_pid_file(app: str) -> Path:
    """Get the PID file path for an app's tunnel."""
    return get_app_data_dir(app) / "code-tunnel.pid"


def get_name_file(app: str) -> Path:
    """Get the name file path for an app's tunnel."""
    return get_app_data_dir(app) / "code-tunnel.name"


def get_log_file(app: str) -> Path:
    """Get the log file path for an app's tunnel."""
    return get_app_data_dir(app) / "code-tunnel.log"


def generate_tunnel_name(app: str) -> str:
    """Generate a unique tunnel name for an app."""
    # Create a short hash for uniqueness
    hostname = os.uname().nodename[:8]
    hash_input = f"{hostname}-{app}".encode()
    short_hash = hashlib.sha256(hash_input).hexdigest()[:6]
    return f"piku-{app}-{short_hash}"


def get_tunnel_name(app: str) -> str | None:
    """Get the stored tunnel name for an app, if any."""
    name_file = get_name_file(app)
    if name_file.exists():
        name = name_file.read_text().strip()
        if name:
            return name
    return None


def save_tunnel_name(app: str, name: str) -> None:
    """Save the tunnel name for an app."""
    get_name_file(app).write_text(name)


def get_tunnel_pid(app: str) -> int | None:
    """Get the PID of the running tunnel for an app, if any."""
    pid_file = get_pid_file(app)
    if pid_file.exists():
        try:
            pid = int(pid_file.read_text().strip())
            # Check if process is actually running
            os.kill(pid, 0)
            return pid
        except (ValueError, OSError):
            # PID file exists but process is not running
            pid_file.unlink(missing_ok=True)
    return None


def save_tunnel_pid(app: str, pid: int) -> None:
    """Save the PID of the tunnel process."""
    get_pid_file(app).write_text(str(pid))


def clear_tunnel_pid(app: str) -> None:
    """Clear the PID file for an app."""
    get_pid_file(app).unlink(missing_ok=True)


def app_exists(app: str) -> bool:
    """Check if a piku app exists."""
    app_dir = Path(PIKU_APPS) / app
    return app_dir.exists() and app_dir.is_dir()


def get_app_dir(app: str) -> Path:
    """Get the app directory path."""
    return Path(PIKU_APPS) / app


def check_code_cli() -> bool:
    """Check if VS Code CLI is installed."""
    return Path(CODE_CLI).exists() and os.access(CODE_CLI, os.X_OK)


@click.group()
def cli():
    """VS Code Tunnel commands for piku."""
    pass


@cli.command("code-tunnel:start")
@click.argument("app")
@click.argument("name", required=False)
def cmd_start(app: str, name: str | None) -> None:
    """Start a VS Code tunnel for an app.

    If the tunnel is already running, returns the existing tunnel name.
    First-time use may require GitHub device authentication.
    """
    # Check if app exists
    if not app_exists(app):
        click.echo(f"-----> Error: App '{app}' does not exist", err=True)
        sys.exit(1)

    # Check if VS Code CLI is installed
    if not check_code_cli():
        click.echo(f"-----> Error: VS Code CLI not found at {CODE_CLI}", err=True)
        click.echo("       Run the piku-code installer first.", err=True)
        sys.exit(1)

    # Check if tunnel is already running
    existing_pid = get_tunnel_pid(app)
    if existing_pid:
        existing_name = get_tunnel_name(app)
        if existing_name:
            click.echo(f"-----> Tunnel already running (PID {existing_pid})")
            click.echo(existing_name)
            return

    # Determine tunnel name
    if name:
        tunnel_name = name
    else:
        tunnel_name = get_tunnel_name(app) or generate_tunnel_name(app)

    click.echo(f"-----> Starting VS Code tunnel '{tunnel_name}'...")

    # Get app directory for the tunnel
    app_dir = get_app_dir(app)
    log_file = get_log_file(app)

    # Start the tunnel process
    # We run it in a way that handles device auth interactively
    try:
        # First, try to start non-interactively to check if auth is needed
        debug(f"Starting tunnel with command: {CODE_CLI} tunnel --name {tunnel_name}")

        # Open log file for output
        with open(log_file, "w") as log:
            process = subprocess.Popen(
                [CODE_CLI, "tunnel", "--accept-server-license-terms", "--name", tunnel_name],
                cwd=str(app_dir),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )

        # Read output to detect auth requirement or successful start
        auth_required = False
        tunnel_ready = False
        auth_url = None
        auth_code = None

        # Set a timeout for initial startup
        start_time = time.time()
        timeout = 60  # 60 seconds for auth/startup

        while time.time() - start_time < timeout:
            if process.poll() is not None:
                # Process exited
                break

            # Read a line (with timeout via select would be better, but this works)
            try:
                line = process.stdout.readline()
                if not line:
                    time.sleep(0.1)
                    continue

                line = line.strip()
                debug(f"Output: {line}")

                # Log to file
                with open(log_file, "a") as log:
                    log.write(line + "\n")

                # Check for authentication requirement
                if "github.com/login/device" in line.lower() or "microsoft.com/devicelogin" in line.lower():
                    auth_required = True
                    auth_url = line
                    click.echo("")
                    click.echo("-----> Authentication required!")
                    click.echo("       Open this URL in your browser:")
                    click.echo(f"       {line}")

                # Check for device code
                if auth_required and ("code:" in line.lower() or "enter" in line.lower()):
                    auth_code = line
                    click.echo(f"       {line}")
                    click.echo("")

                # Check for successful tunnel start
                if "ready" in line.lower() or "connected" in line.lower() or "tunnel" in line.lower():
                    # Look for signs the tunnel is running
                    if "listening" in line.lower() or "ready" in line.lower():
                        tunnel_ready = True
                        if auth_required:
                            click.echo("-----> Authenticated successfully!")
                        click.echo("-----> Tunnel ready!")
                        break

                # Check for tunnel name confirmation
                if tunnel_name in line:
                    tunnel_ready = True
                    click.echo("-----> Tunnel ready!")
                    break

            except Exception as e:
                debug(f"Error reading output: {e}")
                time.sleep(0.1)

        # Check if process is still running (which is good - tunnel should stay up)
        if process.poll() is None:
            # Tunnel is running, save the PID and name
            save_tunnel_pid(app, process.pid)
            save_tunnel_name(app, tunnel_name)
            click.echo(tunnel_name)
        else:
            # Process exited - check why
            exit_code = process.returncode
            click.echo(f"-----> Error: Tunnel process exited with code {exit_code}", err=True)

            # Read any remaining output
            remaining = process.stdout.read()
            if remaining:
                click.echo(remaining, err=True)

            sys.exit(1)

    except FileNotFoundError:
        click.echo(f"-----> Error: VS Code CLI not found at {CODE_CLI}", err=True)
        sys.exit(1)
    except Exception as e:
        click.echo(f"-----> Error starting tunnel: {e}", err=True)
        sys.exit(1)


@cli.command("code-tunnel:stop")
@click.argument("app")
def cmd_stop(app: str) -> None:
    """Stop the VS Code tunnel for an app."""
    pid = get_tunnel_pid(app)

    if not pid:
        click.echo(f"-----> No tunnel running for '{app}'")
        return

    try:
        os.kill(pid, signal.SIGTERM)
        click.echo(f"-----> Tunnel stopped (was PID {pid})")
    except OSError as e:
        click.echo(f"-----> Error stopping tunnel: {e}", err=True)
    finally:
        clear_tunnel_pid(app)


@cli.command("code-tunnel:status")
@click.argument("app")
def cmd_status(app: str) -> None:
    """Check the status of the VS Code tunnel for an app.

    Returns the tunnel name and exits 0 if running.
    Exits 1 if not running.
    """
    pid = get_tunnel_pid(app)
    name = get_tunnel_name(app)

    if pid and name:
        click.echo(f"-----> Tunnel running (PID {pid})")
        click.echo(name)
    elif name:
        click.echo(f"-----> Tunnel not running (was '{name}')")
        sys.exit(1)
    else:
        click.echo(f"-----> No tunnel configured for '{app}'")
        sys.exit(1)


@cli.command("code-tunnel:ensure")
@click.argument("app")
def cmd_ensure(app: str) -> None:
    """Ensure a tunnel is running and return its name.

    Non-interactive version - fails if tunnel is not already running.
    Use code-tunnel:start for interactive startup with auth support.
    """
    pid = get_tunnel_pid(app)
    name = get_tunnel_name(app)

    if pid and name:
        click.echo(name)
    else:
        click.echo(f"-----> Error: No tunnel running for '{app}'", err=True)
        click.echo("       Use 'code-tunnel:start' to start a tunnel.", err=True)
        sys.exit(1)


@cli.command("code-tunnel:name")
@click.argument("app")
def cmd_name(app: str) -> None:
    """Get the tunnel name for an app (for scripting).

    Returns the configured tunnel name, whether or not the tunnel is running.
    Exits 1 if no tunnel name is configured.
    """
    name = get_tunnel_name(app)

    if name:
        click.echo(name)
    else:
        # Generate and save a new name
        name = generate_tunnel_name(app)
        save_tunnel_name(app, name)
        click.echo(name)


def cli_commands():
    """Return the CLI commands for this plugin.

    This is the entry point that piku uses to discover plugin commands.
    """
    return cli
