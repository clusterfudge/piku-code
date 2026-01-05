#!/bin/bash
# piku-code client
#
# A client script for piku-code that integrates with the piku workflow.
# Detects server and app from git remotes, just like the piku client.
#
# Usage:
#   piku-code code                    # Uses 'piku' remote, infers app
#   piku-code -r myremote code        # Uses 'myremote' remote
#   piku-code code myapp              # Explicit app name
#   piku-code code:stop               # Stop the tunnel
#   piku-code code:status             # Check tunnel status

set -e

# Parse --remote / -r flag (must come first, like piku client)
REMOTE_NAME="piku"
if [ "$1" = "--remote" ] || [ "$1" = "-r" ]; then
    shift
    REMOTE_NAME="$1"
    shift
fi

# Get git remote URL
get_git_remote() {
    git config --get remote."$REMOTE_NAME".url 2>/dev/null || true
}

# Parse server from remote (user@host:app -> user@host)
parse_server() {
    local remote="$1"
    echo "$remote" | cut -f1 -d":" 2>/dev/null
}

# Parse app from remote (user@host:app -> app)
parse_app() {
    local remote="$1"
    echo "$remote" | cut -f2 -d":" 2>/dev/null
}

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

# Get server and app, with fallbacks
resolve_remote() {
    local git_remote
    git_remote=$(get_git_remote)

    if [ -n "$git_remote" ]; then
        PIKU_SERVER=$(parse_server "$git_remote")
        PIKU_APP=$(parse_app "$git_remote")
    else
        # Fallback to environment variables
        PIKU_SERVER="${PIKU_SERVER:-}"
        PIKU_APP="${PIKU_APP:-}"
    fi
}

# Get app name from argument or detected remote
get_app_name() {
    local explicit_app="$1"

    if [ -n "$explicit_app" ]; then
        echo "$explicit_app"
        return 0
    fi

    if [ -n "$PIKU_APP" ]; then
        echo "$PIKU_APP"
        return 0
    fi

    echo "Error: No app specified." >&2
    echo "       Use: piku-code code <app>" >&2
    echo "       Or add a git remote: git remote add piku piku@server:appname" >&2
    return 1
}

# Run a command on the piku server (non-interactive)
piku_ssh() {
    if [ -z "$PIKU_SERVER" ]; then
        echo "Error: No piku server configured." >&2
        echo "       Add a git remote: git remote add piku piku@server:appname" >&2
        echo "       Or set PIKU_SERVER environment variable." >&2
        return 1
    fi
    ssh -o StrictHostKeyChecking=accept-new "$PIKU_SERVER" "$@"
}

# Run an interactive command on the piku server (for auth prompts)
piku_ssh_interactive() {
    if [ -z "$PIKU_SERVER" ]; then
        echo "Error: No piku server configured." >&2
        return 1
    fi
    ssh -t -o StrictHostKeyChecking=accept-new "$PIKU_SERVER" "$@"
}

# piku code [path] - Open VS Code connected to a piku app
# Usage:
#   piku-code code              # App from git remote, open root
#   piku-code code src          # App from git remote, open src/
#   piku-code code myapp        # Explicit app (if no git remote), open root
#   piku-code code myapp src    # Explicit app, open src/
cmd_code() {
    local app
    local subpath=""

    # Determine app and subpath based on whether PIKU_APP is set
    if [ -n "$PIKU_APP" ]; then
        # App detected from git remote - first arg is optional subpath
        app="$PIKU_APP"
        subpath="${1:-}"
    else
        # No git remote - first arg is app, second is optional subpath
        app=$(get_app_name "$1") || return 1
        subpath="${2:-}"
    fi

    local code_cmd
    code_cmd=$(detect_code_command)
    if [ -z "$code_cmd" ]; then
        echo "Error: VS Code not found. Please install VS Code." >&2
        return 1
    fi

    echo "Checking tunnel status for '$app' on $PIKU_SERVER..."

    # Try to get existing tunnel
    local tunnel_output
    local status
    tunnel_output=$(piku_ssh "code-tunnel:ensure $app" 2>&1) || status=$?

    if [ -n "$status" ] && [ "$status" -ne 0 ]; then
        # Tunnel not running, start it interactively
        echo "Starting VS Code tunnel (may require authentication)..."
        echo ""

        # Run interactively to allow for device auth
        if ! piku_ssh_interactive "code-tunnel:start $app"; then
            echo "Error: Failed to start tunnel" >&2
            return 1
        fi

        # Now get the tunnel name
        tunnel_output=$(piku_ssh "code-tunnel:ensure $app" 2>&1)
        status=$?
        if [ "$status" -ne 0 ]; then
            echo "Error: Tunnel started but could not get name" >&2
            echo "$tunnel_output" >&2
            return 1
        fi
    fi

    # Extract just the tunnel name (last non-empty line without ----->)
    local tunnel_name
    tunnel_name=$(echo "$tunnel_output" | grep -v "^----->" | grep -v "^$" | tail -1 | tr -d '\r')

    if [ -z "$tunnel_name" ]; then
        echo "Error: Could not get tunnel name" >&2
        echo "Output was: $tunnel_output" >&2
        return 1
    fi

    # Build the remote path
    local remote_path="/home/piku/.piku/apps/$app"
    if [ -n "$subpath" ]; then
        # Remove leading slash if present
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

# piku code:stop - Stop the VS Code tunnel
cmd_code_stop() {
    local app
    app=$(get_app_name "$1") || return 1

    echo "Stopping tunnel for $app..."
    piku_ssh "code-tunnel:stop $app"
}

# piku code:status - Check tunnel status
cmd_code_status() {
    local app
    app=$(get_app_name "$1") || return 1

    piku_ssh "code-tunnel:status $app"
}

# Show usage
usage() {
    echo "Usage: $(basename "$0") [-r|--remote <name>] <command> [app]"
    echo ""
    echo "Commands:"
    echo "  code [app]        Open VS Code connected to app"
    echo "  code:stop [app]   Stop the tunnel"
    echo "  code:status [app] Check tunnel status"
    echo ""
    echo "Options:"
    echo "  -r, --remote      Git remote name (default: piku)"
    echo ""
    echo "The server and app are detected from git remote '$REMOTE_NAME'."
    echo "Format: git remote add piku piku@server:appname"
    echo ""
    echo "Environment variables (fallback):"
    echo "  PIKU_SERVER       Piku server (e.g., piku@myserver.com)"
    echo "  PIKU_APP          Default app name"
}

# Main
main() {
    if [ $# -lt 1 ]; then
        usage
        exit 1
    fi

    # Resolve remote configuration
    resolve_remote

    local cmd="$1"
    shift

    case "$cmd" in
        code)
            cmd_code "$@"
            ;;
        code:stop)
            cmd_code_stop "$@"
            ;;
        code:status)
            cmd_code_status "$@"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            echo "Unknown command: $cmd" >&2
            usage
            exit 1
            ;;
    esac
}

main "$@"
