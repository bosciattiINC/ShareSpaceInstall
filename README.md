# SharedSpace Installer

One-line installation script for SharedSpace.

## Usage

```bash
curl -fsSL https://install.sharedspace.cc/install.sh | sudo bash
```

## What it does

1. Installs Docker and Docker Compose (if needed)
2. Creates directory structure at `~/share-space`
3. Sets up all required containers (app, Signal API, mDNS, Watchtower, Autoheal)
4. Creates systemd service for auto-start
5. Configures mDNS for `sharespace.local` access

## After installation

Access the application at:
- `http://sharespace.local`
- `http://<your-ip>`
