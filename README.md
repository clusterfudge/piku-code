# piku-code

Open VS Code connected to your piku apps using [VS Code Tunnels](https://code.visualstudio.com/docs/remote/tunnels).

## Why?

Piku restricts SSH access via `command=` in `authorized_keys`, which prevents VS Code Remote-SSH from working. This plugin uses VS Code Tunnels to provide a full VS Code experience for your piku apps.

## Quick Start

### 1. Install on your piku server

```bash
ssh piku@myserver 'curl -sL https://raw.githubusercontent.com/clusterfudge/piku-code/main/install.sh | sh'
```

This installs:
- The piku-code plugin to `~/.piku/plugins/piku_code/`
- VS Code CLI to `~/bin/code`

### 2. Set up your local machine

**Option A: Standalone script** (works now)

```bash
curl -sL https://raw.githubusercontent.com/clusterfudge/piku-code/main/piku-client.sh > ~/.local/bin/piku-code
chmod +x ~/.local/bin/piku-code
```

Then use `piku-code code` to connect.

**Option B: Piku client plugin** (requires [upstream piku patch](UPSTREAM-PROPOSAL.md))

```bash
mkdir -p ~/.piku/client-plugins
curl -sL https://raw.githubusercontent.com/clusterfudge/piku-code/main/piku-client-plugin.sh > ~/.piku/client-plugins/code
chmod +x ~/.piku/client-plugins/code
```

Then use `piku code` directly.

### 3. Connect to your app

The client automatically detects server and app from your git remote:

```bash
# If you have a piku remote configured (git remote add piku piku@server:myapp)
cd /path/to/your/app
piku-code code

# Or specify a different remote
piku-code -r production code

# Or use environment variables as fallback
export PIKU_SERVER=piku@myserver.com
piku-code code myapp
```

## First-Time Authentication

The first time you start a tunnel, you'll need to authenticate with GitHub:

```
$ piku-code code
Starting VS Code tunnel (may require authentication)...

-----> Starting VS Code tunnel 'piku-myapp-a1b2c3'...

-----> Authentication required!
       Open this URL in your browser:
       https://github.com/login/device

       Enter code: ABCD-1234

-----> Authenticated successfully!
-----> Tunnel ready!
piku-myapp-a1b2c3

Tunnel: piku-myapp-a1b2c3
Connecting VS Code...
```

After the first authentication, subsequent connections are instant.

## Commands

### Client-side (your machine)

| Command | Description |
|---------|-------------|
| `piku-code code [app]` | Start tunnel if needed, open VS Code |
| `piku-code code:stop [app]` | Stop the tunnel |
| `piku-code code:status [app]` | Check tunnel status |
| `piku-code -r <remote> ...` | Use a specific git remote |

### Server-side (piku server)

| Command | Description |
|---------|-------------|
| `piku code-tunnel:start <app>` | Start a tunnel for an app |
| `piku code-tunnel:stop <app>` | Stop the tunnel |
| `piku code-tunnel:status <app>` | Check if tunnel is running |
| `piku code-tunnel:ensure <app>` | Return tunnel name if running, else error |
| `piku code-tunnel:name <app>` | Get the tunnel name |
| `piku code-tunnel:logs <app>` | View tunnel logs |

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PIKU_SERVER` | SSH connection to piku | `piku@localhost` |
| `PIKU_APP` | Default app name | (none) |
| `PIKU_CODE_DEBUG` | Enable debug output | `0` |

### Tunnel Names

Tunnel names are automatically generated as `piku-<app>-<hash>` and stored in `~/.piku/data/<app>/code-tunnel.name`. You can also specify a custom name:

```bash
ssh piku@myserver code-tunnel:start myapp my-custom-tunnel-name
```

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│ YOUR MACHINE                                                    │
│                                                                 │
│  $ piku code myapp                                              │
│       │                                                         │
│       ├──► SSH to piku server: code-tunnel:start myapp          │
│       │         └──► Starts VS Code tunnel daemon               │
│       │         └──► Returns tunnel name                        │
│       │                                                         │
│       └──► code --remote tunnel+piku-myapp-abc123 /path/to/app  │
│                 └──► VS Code connects via Microsoft relay       │
└─────────────────────────────────────────────────────────────────┘
```

VS Code Tunnels work by:
1. Running a tunnel server on the piku host
2. Connecting through Microsoft's relay service
3. Your local VS Code connects to the relay (no direct SSH needed)

## Troubleshooting

### "VS Code CLI not found"

The installer didn't complete. Run it again or manually install:

```bash
# On the piku server
cd ~/bin
curl -fsSL "https://update.code.visualstudio.com/latest/cli-alpine-x64/stable" -o code.tar.gz
tar -xzf code.tar.gz
rm code.tar.gz
chmod +x code
```

### "Tunnel not running"

Check if the tunnel process died:

```bash
ssh piku@myserver code-tunnel:status myapp
```

View the tunnel logs:

```bash
ssh piku@myserver code-tunnel:logs myapp
```

Restart it:

```bash
ssh -t piku@myserver code-tunnel:start myapp
```

### Authentication issues

Re-authenticate by stopping and restarting:

```bash
ssh piku@myserver code-tunnel:stop myapp
ssh -t piku@myserver code-tunnel:start myapp
```

### VS Code can't connect

1. Make sure VS Code is up to date
2. Check the tunnel is running on the server
3. Try the tunnel name directly in VS Code:
   - Press `Ctrl+Shift+P` (or `Cmd+Shift+P` on Mac)
   - Type "Remote-Tunnels: Connect to Tunnel"
   - Enter the tunnel name

## Development

### Local testing

```bash
# On piku server, link the plugin for development
mkdir -p ~/.piku/plugins
ln -s /path/to/piku-code/piku_code ~/.piku/plugins/piku_code

# Test commands
piku code-tunnel:start myapp
piku code-tunnel:status myapp
piku code-tunnel:stop myapp
```

### Debug mode

```bash
PIKU_CODE_DEBUG=1 piku code-tunnel:start myapp
```

## Requirements

### Server
- Piku installed and running
- Internet access (for GitHub auth and tunnel relay)
- Python 3.9+ with Click

### Client
- VS Code installed with `code` command available
- SSH access to piku server
- Bash shell

## License

MIT

## Related

- [Piku](https://github.com/piku/piku) - The tiniest PaaS you've ever seen
- [VS Code Tunnels](https://code.visualstudio.com/docs/remote/tunnels) - Official documentation
- [VS Code Remote Development](https://code.visualstudio.com/docs/remote/remote-overview)
