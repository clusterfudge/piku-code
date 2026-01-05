# Proposal: Client-Side Plugin Support for Piku

> **Status: Implemented** - See [clusterfudge/piku branch claude/add-client-plugins-kZEcv](https://github.com/clusterfudge/piku/tree/claude/add-client-plugins-kZEcv)

## Problem

The piku client currently has no extensibility mechanism. Server-side plugins can add new commands, but some operations require **both** server and local actions. For example:

- `piku code` - needs to SSH to start a tunnel, then launch local VS Code
- `piku open` - could SSH to get app URL, then open local browser
- `piku sync` - could use rsync/scp with local files

Currently, users must install separate wrapper scripts, breaking the unified `piku <command>` experience.

## Proposed Solution

Add a simple client-side plugin mechanism: before the main `case` statement, check for an executable in `~/.piku/client-plugins/` matching the command name.

### Implementation

Add this block after the remote/server/app parsing, before the `case "$cmd"` statement:

```bash
# Client-side plugin support
plugin_cmd=$(echo "$cmd" | cut -d: -f1)  # Extract base command (e.g., "code" from "code:stop")
plugin_path="$HOME/.piku/client-plugins/$plugin_cmd"
if [ -x "$plugin_path" ]; then
    exec "$plugin_path" "$server" "$app" "$cmd" "$@"
fi
```

### Plugin Interface

Plugins receive:
- `$1` - server (e.g., `piku@myserver.com`)
- `$2` - app name (e.g., `myapp`)
- `$3` - full command (e.g., `code:stop`)
- `$@` - remaining arguments

Plugins are responsible for their own SSH calls and can use the server/app info as needed.

### Example Plugin

`~/.piku/client-plugins/code`:
```bash
#!/bin/bash
server="$1"
app="$2"
cmd="$3"
shift 3

case "$cmd" in
    code)
        # Start tunnel if needed, get tunnel name
        tunnel=$(ssh "$server" "code-tunnel:ensure $app" 2>/dev/null) || \
            tunnel=$(ssh -t "$server" "code-tunnel:start $app" | tail -1)
        # Launch local VS Code
        code --remote "tunnel+$tunnel" "/home/piku/.piku/apps/$app"
        ;;
    code:stop)
        ssh "$server" "code-tunnel:stop $app"
        ;;
    code:status)
        ssh "$server" "code-tunnel:status $app"
        ;;
esac
```

### Installation

Server-side plugins can include a client component. The installer would:
```bash
mkdir -p ~/.piku/client-plugins
curl -sL https://example.com/plugin-client.sh > ~/.piku/client-plugins/code
chmod +x ~/.piku/client-plugins/code
```

## Benefits

1. **Minimal change** - ~5 lines added to piku client
2. **Backwards compatible** - no change to existing behavior
3. **Convention over configuration** - just drop executable in directory
4. **Unified UX** - `piku code` instead of `piku-code code`
5. **Enables new plugin types** - anything needing local+remote coordination

## Alternatives Considered

1. **Wrapper scripts** - Works but breaks unified `piku` experience
2. **Shell aliases** - Awkward for multi-word commands, not portable
3. **Modifying piku directly** - Doesn't scale for third-party plugins

## Files Changed

Only `piku` (the client shell script) - approximately 5-10 lines added.
