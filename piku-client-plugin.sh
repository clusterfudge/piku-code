#!/bin/bash
# piku code - client-side plugin for VS Code tunnel integration
#
# This plugin is installed to ~/.piku/client-plugins/code and is invoked
# by the piku client when running commands like:
#   piku code [path]
#   piku code:stop
#   piku code:status
#
# Plugin interface:
#   $1 - server (e.g., piku@myserver.com)
#   $2 - app name (e.g., myapp)
#   $3 - full command (e.g., code, code:stop)
#   $@ - remaining arguments
#
# Usage:
#   piku code              # Open app root directory
#   piku code src          # Open app/src subdirectory
#   piku code backend/api  # Open app/backend/api subdirectory

set -e

SERVER="$1"
APP="$2"
CMD="$3"
shift 3

# Detect local VS Code command
detect_code_command() {
    if command -v code >/dev/null 2>&1; then
        echo "code"
    elif command -v code-insiders >/dev/null 2>&1; then
        echo "code-insiders"
    elif [ -d "/Applications/Visual Studio Code.app" ]; then
        echo "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    elif [ -d "/Applications/Visual Studio Code - Insiders.app" ]; then
        echo "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code"
    else
        echo ""
    fi
}

# Run SSH command (non-interactive)
run_ssh() {
    ssh -o StrictHostKeyChecking=accept-new "$SERVER" "$@"
}

# Run interactive SSH command (for auth prompts)
run_ssh_interactive() {
    ssh -t -o StrictHostKeyChecking=accept-new "$SERVER" "$@"
}

# piku code [path] - Open VS Code connected to the app
cmd_code() {
    local subpath="${1:-}"

    local code_cmd
    code_cmd=$(detect_code_command)
    if [ -z "$code_cmd" ]; then
        echo "Error: VS Code not found. Please install VS Code." >&2
        exit 1
    fi

    echo "Checking tunnel status for '$APP' on $SERVER..."

    # Try to get existing tunnel
    local tunnel_name
    local status=0
    tunnel_name=$(run_ssh "code-tunnel:ensure $APP" 2>&1) || status=$?

    if [ "$status" -ne 0 ]; then
        # Tunnel not running, start it interactively
        echo "Starting VS Code tunnel (may require authentication)..."
        echo ""

        if ! run_ssh_interactive "code-tunnel:start $APP"; then
            echo "Error: Failed to start tunnel" >&2
            exit 1
        fi

        # Get the tunnel name
        tunnel_name=$(run_ssh "code-tunnel:ensure $APP" 2>&1) || status=$?
        if [ "$status" -ne 0 ]; then
            echo "Error: Tunnel started but could not get name" >&2
            echo "$tunnel_name" >&2
            exit 1
        fi
    fi

    # Extract just the tunnel name (last non-empty line without ----->)
    tunnel_name=$(echo "$tunnel_name" | grep -v "^----->" | grep -v "^$" | tail -1 | tr -d '\r')

    if [ -z "$tunnel_name" ]; then
        echo "Error: Could not get tunnel name" >&2
        exit 1
    fi

    # Build the remote path
    local remote_path="/home/piku/.piku/apps/$APP"
    if [ -n "$subpath" ]; then
        # Remove leading slash if present, normalize path
        subpath="${subpath#/}"
        remote_path="$remote_path/$subpath"
    fi

    echo ""
    echo "Tunnel: $tunnel_name"
    echo "Opening: $remote_path"
    echo "Connecting VS Code..."

    # Open VS Code connected to the tunnel
    "$code_cmd" --remote "tunnel+$tunnel_name" "$remote_path"
}

# piku code:stop - Stop the tunnel
cmd_code_stop() {
    echo "Stopping tunnel for $APP..."
    run_ssh "code-tunnel:stop $APP"
}

# piku code:status - Check tunnel status
cmd_code_status() {
    run_ssh "code-tunnel:status $APP"
}

# piku code:logs - View tunnel logs
cmd_code_logs() {
    run_ssh "code-tunnel:logs $APP" "$@"
}

# Main command dispatch
case "$CMD" in
    code)
        cmd_code "$@"
        ;;
    code:stop)
        cmd_code_stop "$@"
        ;;
    code:status)
        cmd_code_status "$@"
        ;;
    code:logs)
        cmd_code_logs "$@"
        ;;
    *)
        echo "Unknown command: $CMD" >&2
        echo "Available commands: code, code:stop, code:status, code:logs" >&2
        exit 1
        ;;
esac
