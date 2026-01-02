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


def echo_error(msg: str) -> None:
    """Print an error message to stderr."""
    click.echo(f"-----> Error: {msg}", err=True)


def echo_info(msg: str) -> None:
    """Print an info message."""
    click.echo(f"-----> {msg}")


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
            debug(f"Tunnel process {pid} is running")
            return pid
        except (ValueError, OSError) as e:
            # PID file exists but process is not running
            debug(f"PID file exists but process not running: {e}")
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
    exists = Path(CODE_CLI).exists()
    executable = os.access(CODE_CLI, os.X_OK) if exists else False
    debug(f"CODE_CLI={CODE_CLI} exists={exists} executable={executable}")
    return exists and executable


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
        echo_error(f"App '{app}' does not exist")
        click.echo(f"       Available apps: {', '.join(os.listdir(PIKU_APPS)) if os.path.exists(PIKU_APPS) else 'none'}", err=True)
        sys.exit(1)

    # Check if VS Code CLI is installed
    if not check_code_cli():
        echo_error(f"VS Code CLI not found at {CODE_CLI}")
        click.echo("       Run the piku-code installer first:", err=True)
        click.echo("       curl -sL https://raw.githubusercontent.com/clusterfudge/piku-code/main/install.sh | sh", err=True)
        sys.exit(1)

    # Check if tunnel is already running
    existing_pid = get_tunnel_pid(app)
    if existing_pid:
        existing_name = get_tunnel_name(app)
        if existing_name:
            echo_info(f"Tunnel already running (PID {existing_pid})")
            click.echo(existing_name)
            return

    # Determine tunnel name
    if name:
        tunnel_name = name
    else:
        tunnel_name = get_tunnel_name(app) or generate_tunnel_name(app)

    echo_info(f"Starting VS Code tunnel '{tunnel_name}'...")

    # Get app directory for the tunnel
    app_dir = get_app_dir(app)
    log_file = get_log_file(app)

    # Build the command
    cmd = [CODE_CLI, "tunnel", "--accept-server-license-terms", "--name", tunnel_name]
    debug(f"Running command: {' '.join(cmd)}")
    debug(f"Working directory: {app_dir}")
    debug(f"Log file: {log_file}")

    # Start the tunnel process as a daemon
    # We use nohup-style approach: redirect to log file and detach
    try:
        with open(log_file, "w") as log:
            process = subprocess.Popen(
                cmd,
                cwd=str(app_dir),
                stdout=log,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                start_new_session=True,  # Detach from terminal
            )

        # Save PID and name immediately
        save_tunnel_pid(app, process.pid)
        save_tunnel_name(app, tunnel_name)

        echo_info(f"Tunnel started (PID {process.pid})")
        echo_info(f"Log file: {log_file}")

        # Check if process is still running after a brief moment
        import time
        time.sleep(1)

        if process.poll() is not None:
            # Process exited immediately - something went wrong
            exit_code = process.returncode
            echo_error(f"Tunnel process exited immediately with code {exit_code}")

            # Show log contents
            if log_file.exists():
                log_contents = log_file.read_text()
                if log_contents.strip():
                    click.echo("       Log output:", err=True)
                    for line in log_contents.strip().split('\n')[:20]:
                        click.echo(f"       {line}", err=True)

            clear_tunnel_pid(app)
            sys.exit(1)

        # Check if auth is needed by reading log
        if log_file.exists():
            log_contents = log_file.read_text()
            if "github.com/login/device" in log_contents.lower() or "microsoft.com/devicelogin" in log_contents.lower():
                echo_info("Authentication may be required!")
                click.echo("       Check the log file for auth URL:", err=True)
                click.echo(f"       cat {log_file}", err=True)
                # Print relevant lines
                for line in log_contents.split('\n'):
                    if 'http' in line.lower() or 'code' in line.lower():
                        click.echo(f"       {line}")

        echo_info("Tunnel ready!")
        click.echo(tunnel_name)

    except FileNotFoundError:
        echo_error(f"VS Code CLI not found at {CODE_CLI}")
        sys.exit(1)
    except PermissionError as e:
        echo_error(f"Permission denied: {e}")
        sys.exit(1)
    except Exception as e:
        echo_error(f"Failed to start tunnel: {e}")
        debug(f"Exception type: {type(e).__name__}")
        import traceback
        debug(traceback.format_exc())
        sys.exit(1)


@cli.command("code-tunnel:stop")
@click.argument("app")
def cmd_stop(app: str) -> None:
    """Stop the VS Code tunnel for an app."""
    pid = get_tunnel_pid(app)

    if not pid:
        echo_info(f"No tunnel running for '{app}'")
        return

    try:
        os.kill(pid, signal.SIGTERM)
        echo_info(f"Tunnel stopped (was PID {pid})")
    except OSError as e:
        echo_error(f"Failed to stop tunnel: {e}")
    finally:
        clear_tunnel_pid(app)


@cli.command("code-tunnel:status")
@click.argument("app")
def cmd_status(app: str) -> None:
    """Check the status of the VS Code tunnel for an app.

    Returns the tunnel name and exits 0 if running.
    Exits 1 if not running.
    """
    # Check if app exists
    if not app_exists(app):
        echo_error(f"App '{app}' does not exist")
        sys.exit(1)

    pid = get_tunnel_pid(app)
    name = get_tunnel_name(app)

    if pid and name:
        echo_info(f"Tunnel running (PID {pid})")
        click.echo(name)
    elif name:
        echo_info(f"Tunnel not running (was '{name}')")
        sys.exit(1)
    else:
        echo_info(f"No tunnel configured for '{app}'")
        sys.exit(1)


@cli.command("code-tunnel:ensure")
@click.argument("app")
def cmd_ensure(app: str) -> None:
    """Ensure a tunnel is running and return its name.

    Non-interactive version - fails if tunnel is not already running.
    Use code-tunnel:start for interactive startup with auth support.
    """
    # Check if app exists
    if not app_exists(app):
        echo_error(f"App '{app}' does not exist")
        sys.exit(1)

    pid = get_tunnel_pid(app)
    name = get_tunnel_name(app)

    if pid and name:
        click.echo(name)
    else:
        echo_error(f"No tunnel running for '{app}'")
        click.echo("       Use 'code-tunnel:start' to start a tunnel.", err=True)
        sys.exit(1)


@cli.command("code-tunnel:name")
@click.argument("app")
def cmd_name(app: str) -> None:
    """Get the tunnel name for an app (for scripting).

    Returns the configured tunnel name, whether or not the tunnel is running.
    Generates a new name if none is configured.
    """
    # Check if app exists
    if not app_exists(app):
        echo_error(f"App '{app}' does not exist")
        sys.exit(1)

    name = get_tunnel_name(app)

    if name:
        click.echo(name)
    else:
        # Generate and save a new name
        name = generate_tunnel_name(app)
        save_tunnel_name(app, name)
        click.echo(name)


@cli.command("code-tunnel:logs")
@click.argument("app")
@click.option("-f", "--follow", is_flag=True, help="Follow log output")
@click.option("-n", "--lines", default=50, help="Number of lines to show")
def cmd_logs(app: str, follow: bool, lines: int) -> None:
    """Show tunnel logs for an app."""
    # Check if app exists
    if not app_exists(app):
        echo_error(f"App '{app}' does not exist")
        sys.exit(1)

    log_file = get_log_file(app)

    if not log_file.exists():
        echo_info(f"No log file found for '{app}'")
        return

    if follow:
        # Use tail -f
        os.execvp("tail", ["tail", "-f", str(log_file)])
    else:
        # Show last N lines
        content = log_file.read_text()
        log_lines = content.strip().split('\n')
        for line in log_lines[-lines:]:
            click.echo(line)


def cli_commands():
    """Return the CLI commands for this plugin.

    This is the entry point that piku uses to discover plugin commands.
    """
    return cli
