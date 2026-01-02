#!/bin/bash
# piku-code client-side additions
#
# Add these functions to your local piku script or source this file.
#
# Prerequisites:
# - The piku-code plugin must be installed on the server
# - VS Code must be installed locally with the 'code' command available
# - Your piku remote must be configured (PIKU_SERVER environment variable)
#
# Usage:
#   export PIKU_SERVER=piku@myserver.com
#   export PIKU_APP=myapp
#   piku code          # Open VS Code connected to the app
#   piku code:stop     # Stop the tunnel
#   piku code:status   # Check tunnel status

# Configuration
# Set these in your environment or modify here
PIKU_SERVER="${PIKU_SERVER:-piku@localhost}"
PIKU_APP="${PIKU_APP:-}"

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

# Get app name from argument or environment
get_app_name() {
    local app="${1:-$PIKU_APP}"
    if [ -z "$app" ]; then
        echo "Error: No app specified. Use: piku code <app> or set PIKU_APP" >&2
        return 1
    fi
    echo "$app"
}

# Run a command on the piku server
piku_ssh() {
    ssh "$PIKU_SERVER" "$@"
}

# Run an interactive command on the piku server (for auth prompts)
piku_ssh_interactive() {
    ssh -t "$PIKU_SERVER" "$@"
}

# piku code - Open VS Code connected to a piku app
piku_code() {
    local app
    app=$(get_app_name "$1") || return 1

    local code_cmd
    code_cmd=$(detect_code_command)
    if [ -z "$code_cmd" ]; then
        echo "Error: VS Code not found. Please install VS Code." >&2
        return 1
    fi

    echo "Checking tunnel status..."

    # Try to get existing tunnel
    local tunnel_name
    tunnel_name=$(piku_ssh "code-tunnel:status $app" 2>/dev/null | tail -1)
    local status=$?

    if [ $status -ne 0 ] || [ -z "$tunnel_name" ]; then
        # Tunnel not running, start it interactively
        echo "Starting VS Code tunnel (may require authentication)..."
        echo ""

        # Run interactively to allow for device auth
        tunnel_name=$(piku_ssh_interactive "code-tunnel:start $app" | tail -1)
        status=$?

        if [ $status -ne 0 ]; then
            echo "Error: Failed to start tunnel" >&2
            return 1
        fi
    fi

    # Clean up tunnel name (remove any control characters)
    tunnel_name=$(echo "$tunnel_name" | tr -d '\r' | tail -1)

    if [ -z "$tunnel_name" ]; then
        echo "Error: Could not get tunnel name" >&2
        return 1
    fi

    echo ""
    echo "Tunnel: $tunnel_name"
    echo "Connecting VS Code..."

    # Open VS Code connected to the tunnel
    # The path is the app directory on the server
    "$code_cmd" --remote "tunnel+$tunnel_name" "/home/piku/.piku/apps/$app"
}

# piku code:stop - Stop the VS Code tunnel
piku_code_stop() {
    local app
    app=$(get_app_name "$1") || return 1

    echo "Stopping tunnel for $app..."
    piku_ssh "code-tunnel:stop $app"
}

# piku code:status - Check tunnel status
piku_code_status() {
    local app
    app=$(get_app_name "$1") || return 1

    piku_ssh "code-tunnel:status $app"
}

# Main command dispatcher
# This function can be added to your piku script's command handling
piku_code_dispatch() {
    local cmd="$1"
    shift

    case "$cmd" in
        code)
            piku_code "$@"
            ;;
        code:stop)
            piku_code_stop "$@"
            ;;
        code:status)
            piku_code_status "$@"
            ;;
        *)
            return 1  # Command not handled
            ;;
    esac
}

# If sourced, export functions
# If run directly, dispatch command
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    # Running as script
    if [ $# -lt 1 ]; then
        echo "Usage: $0 <command> [app]"
        echo ""
        echo "Commands:"
        echo "  code [app]        Open VS Code connected to app"
        echo "  code:stop [app]   Stop the tunnel"
        echo "  code:status [app] Check tunnel status"
        echo ""
        echo "Environment:"
        echo "  PIKU_SERVER       Piku server (default: piku@localhost)"
        echo "  PIKU_APP          Default app name"
        exit 1
    fi

    piku_code_dispatch "$@"
fi
