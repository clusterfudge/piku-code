#!/bin/sh
# piku-code installer
# Install VS Code Tunnel integration for piku
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/OWNER/piku-code/main/install.sh | sh
#
# Or run locally:
#   ./install.sh

set -e

# Colors for output (if terminal supports it)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

info() {
    printf "${BLUE}---->${NC} %s\n" "$1"
}

success() {
    printf "${GREEN}---->${NC} %s\n" "$1"
}

warn() {
    printf "${YELLOW}---->${NC} %s\n" "$1"
}

error() {
    printf "${RED}---->${NC} %s\n" "$1" >&2
}

# Configuration
PIKU_HOME="${PIKU_HOME:-$HOME/.piku}"
PLUGIN_DIR="$PIKU_HOME/plugins/piku_code"
BIN_DIR="$HOME/bin"
CODE_CLI="$BIN_DIR/code"

# GitHub raw URL for plugin files (update OWNER before publishing)
GITHUB_RAW="https://raw.githubusercontent.com/OWNER/piku-code/main"

# VS Code CLI download URLs
# See: https://code.visualstudio.com/docs/editor/command-line#_standalone-cli
VSCODE_CLI_BASE="https://code.visualstudio.com/sha/download"

detect_arch() {
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            echo "x64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l|armhf)
            echo "armhf"
            ;;
        *)
            error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

detect_os() {
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        linux)
            echo "linux"
            ;;
        darwin)
            echo "darwin"
            ;;
        *)
            error "Unsupported OS: $os"
            exit 1
            ;;
    esac
}

download_vscode_cli() {
    os=$(detect_os)
    arch=$(detect_arch)

    info "Detected platform: $os-$arch"

    # Construct download URL
    # Format: https://code.visualstudio.com/sha/download?build=stable&os=cli-<os>-<arch>
    cli_os="cli-${os}-${arch}"
    download_url="${VSCODE_CLI_BASE}?build=stable&os=${cli_os}"

    info "Downloading VS Code CLI..."

    # Create temp directory
    tmp_dir=$(mktemp -d)
    trap "rm -rf $tmp_dir" EXIT

    # Download the CLI
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$download_url" -o "$tmp_dir/vscode-cli.tar.gz"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$download_url" -O "$tmp_dir/vscode-cli.tar.gz"
    else
        error "Neither curl nor wget found. Please install one of them."
        exit 1
    fi

    # Extract the CLI
    info "Extracting VS Code CLI..."
    mkdir -p "$BIN_DIR"
    tar -xzf "$tmp_dir/vscode-cli.tar.gz" -C "$BIN_DIR"

    # Make executable
    chmod +x "$CODE_CLI"

    success "VS Code CLI installed to $CODE_CLI"
}

install_plugin() {
    info "Installing piku-code plugin..."

    # Create plugin directory
    mkdir -p "$PLUGIN_DIR"

    # Download plugin file
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$GITHUB_RAW/piku_code/__init__.py" -o "$PLUGIN_DIR/__init__.py"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$GITHUB_RAW/piku_code/__init__.py" -O "$PLUGIN_DIR/__init__.py"
    fi

    success "Plugin installed to $PLUGIN_DIR"
}

install_plugin_local() {
    # For local development - copy from local directory
    script_dir=$(dirname "$0")
    if [ -f "$script_dir/piku_code/__init__.py" ]; then
        info "Installing piku-code plugin from local directory..."
        mkdir -p "$PLUGIN_DIR"
        cp "$script_dir/piku_code/__init__.py" "$PLUGIN_DIR/__init__.py"
        success "Plugin installed to $PLUGIN_DIR"
        return 0
    fi
    return 1
}

check_piku() {
    if [ ! -d "$PIKU_HOME" ]; then
        warn "Piku home directory not found at $PIKU_HOME"
        warn "Make sure piku is installed first."
        info "Creating $PIKU_HOME anyway..."
        mkdir -p "$PIKU_HOME"
    fi
}

check_existing() {
    if [ -f "$CODE_CLI" ]; then
        warn "VS Code CLI already installed at $CODE_CLI"
        info "Checking version..."
        "$CODE_CLI" --version 2>/dev/null || true
    fi

    if [ -d "$PLUGIN_DIR" ]; then
        warn "Plugin already installed at $PLUGIN_DIR"
    fi
}

add_bin_to_path() {
    # Check if ~/bin is in PATH
    case ":$PATH:" in
        *":$BIN_DIR:"*)
            ;;
        *)
            warn "$BIN_DIR is not in your PATH"
            info "Add this line to your shell profile (.bashrc, .zshrc, etc.):"
            echo "    export PATH=\"\$HOME/bin:\$PATH\""
            ;;
    esac
}

main() {
    echo ""
    info "Installing piku-code: VS Code Tunnel Integration for Piku"
    echo ""

    # Check prerequisites
    check_piku
    check_existing

    # Try local install first (for development)
    if ! install_plugin_local 2>/dev/null; then
        install_plugin
    fi

    # Install VS Code CLI if not present
    if [ ! -f "$CODE_CLI" ]; then
        download_vscode_cli
    else
        info "VS Code CLI already installed, skipping download"
    fi

    add_bin_to_path

    echo ""
    success "Installation complete!"
    echo ""
    info "Server-side commands are now available:"
    echo "    piku code-tunnel:start <app>   - Start a VS Code tunnel"
    echo "    piku code-tunnel:stop <app>    - Stop the tunnel"
    echo "    piku code-tunnel:status <app>  - Check tunnel status"
    echo ""
    info "To use from your local machine, install the client-side script."
    echo "    See: $GITHUB_RAW/README.md"
    echo ""
}

main "$@"
