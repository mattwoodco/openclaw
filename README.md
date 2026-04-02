# OpenClaw Multi-Bot Management System

Configuration-first approach to managing multiple OpenClaw bot instances running in OrbStack VMs on macOS.

## Prerequisites

- **macOS** with [OrbStack](https://orbstack.dev) installed
- **jq** and **curl** (install via `brew install jq curl` if missing)
- A **Telegram bot token** per bot (create one via [@BotFather](https://t.me/BotFather) on Telegram)
- An **Anthropic API key** (and optionally an OpenAI API key)
- Optionally: a GitHub personal access token, Google Workspace OAuth credentials

## Quick Start: Adding a New Bot

### Step 1: Create shared credentials

Copy the example and fill in your API keys:

```bash
cp .env.example .env.local
```

Edit `.env.local` and set at minimum:

```bash
ANTHROPIC_API_KEY=sk-ant-...
```

See [Credential Management](#credential-management) for all available keys.

### Step 2: Scaffold a new config

Use the scaffold command (auto-assigns ports):

```bash
./manage.sh scaffold mybot
```

Or copy the template manually and edit it:

```bash
cp templates/example.env configs/mybot.env
```

The template (`templates/example.env`) has every available setting with comments explaining what each one does. At minimum, you need to set `VM_NAME`, `OPENCLAW_PORT`, `WORKSPACE_DIR`, and `TELEGRAM_BOT_TOKEN`.

### Step 3: Set the Telegram bot token

Open the config and paste your bot token from @BotFather:

```bash
./manage.sh edit mybot
```

Find the `TELEGRAM_BOT_TOKEN` line and replace the variable reference with your actual token:

```bash
TELEGRAM_BOT_TOKEN=1234567890:AAH...your-token-here
```

### Step 4: Customize settings (optional)

While editing, you can also adjust:

- `BOT_NAME` and `BOT_DESCRIPTION` -- the bot's display identity
- Feature flags (`ENABLE_EMAIL_SENDING`, `ENABLE_WEB_BROWSING`, etc.)
- `ANTHROPIC_MODEL` -- uncomment and set to override the default model
- `LOG_LEVEL` -- set to `debug` for verbose output during initial setup

Validate your config before deploying:

```bash
./manage.sh validate mybot
```

### Step 5: Provision and deploy

Deploy a single bot:

```bash
./provision.sh mybot
```

Or deploy all configured bots at once:

```bash
./provision.sh all
```

The first run builds a base VM (~8 minutes). Subsequent bots are cloned from the base in seconds.

### Step 6: Verify

Check that everything is running:

```bash
./provision.sh status
```

The status dashboard shows each bot's port, VM state, service status, and HTTP health. The provisioning script also opens the bot's dashboard in your browser automatically.

To run the full validation suite (service, HTTP, email, dashboard):

```bash
./provision.sh validate mybot
```

## Project Structure

```
.
├── .env.example              # Template for shared credentials
├── .env.local                # Your shared API keys (git-ignored)
├── manage.sh                 # Configuration management
├── provision.sh              # VM provisioning (base build + cloning)
├── setup.sh                  # Core VM setup (builds the base Ubuntu VM)
├── validate.sh               # Validation checks for running VMs
├── templates/
│   └── example.env           # Bot config template (copy to configs/)
├── configs/                  # Bot configuration files
│   ├── bubba.env             # Bubba bot config (port 18790)
│   ├── mo.env                # Mo bot config (port 18791)
│   └── quinn.env             # Quinn bot config (port 18792)
├── skills/                   # Shared skills (copied into each workspace)
│   ├── github/               # GitHub integration skill
│   ├── gws-workspace/        # Google Workspace skill
│   └── openclaw-agent-browser-clawdbot/  # Browser automation skill
├── workspace-base/           # Base workspace template files
├── workspace-bubba/          # Bubba's workspace (markdown + skills + app files)
├── workspace-mo/             # Mo's workspace
└── workspace-quinn/          # Quinn's workspace
```

Each workspace contains markdown personality/behavior files (`AGENTS.md`, `SOUL.md`, `IDENTITY.md`, `USER.md`, `TOOLS.md`, `HEARTBEAT.md`, `BOOTSTRAP.md`) plus a `skills/` directory. These are copied from `workspace-base/` on first provision and are not overwritten on subsequent deploys.

## Configuration Reference

Each bot config file (`configs/NAME.env`) supports the following variables:

### Basic VM Settings

| Variable | Description | Default |
|---|---|---|
| `VM_NAME` | OrbStack VM name | Set to config name |
| `OPENCLAW_PORT` | HTTP port for the bot gateway | Auto-assigned starting at 18790 |
| `WORKSPACE_DIR` | Path to the bot's workspace directory | `./workspace-NAME` |

### Bot Identity

| Variable | Description | Default |
|---|---|---|
| `BOT_NAME` | Display name for the bot | `"OpenClaw Assistant: NAME"` |
| `BOT_DESCRIPTION` | Short description | `"AI assistant for various tasks"` |

### API Keys

| Variable | Description | Default |
|---|---|---|
| `ANTHROPIC_API_KEY` | Anthropic API key | Inherited from `.env.local` |
| `OPENAI_API_KEY` | OpenAI API key | Inherited from `.env.local` |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token (bot-specific) | Inherited from `.env.local` by name convention |
| `GITHUB_TOKEN` | GitHub personal access token | Inherited from `.env.local` |
| `GOOGLE_WORKSPACE_CREDENTIALS_FILE` | Path to GWS credentials | Inherited from `.env.local` |

### Feature Flags

| Variable | Description | Default |
|---|---|---|
| `ENABLE_EMAIL_SENDING` | Allow the bot to send emails | `true` |
| `ENABLE_CODE_EXECUTION` | Allow the bot to run code | `true` |
| `ENABLE_WEB_BROWSING` | Allow the bot to browse the web | `false` |
| `ENABLE_CRON_JOBS` | Allow scheduled/recurring tasks | `true` |

### Security and Approval Settings

| Variable | Description | Default |
|---|---|---|
| `AUTO_APPROVE_EMAIL` | Skip email-sending approval prompts | `false` |
| `AUTO_APPROVE_FILE_OPERATIONS` | Skip file operation approval prompts | `false` |
| `AUTO_APPROVE_WEB_REQUESTS` | Skip web request approval prompts | `false` |
| `OPENCLAW_SKIP_APPROVALS` | Skip all approval prompts (development only) | `false` |

### Skills Configuration

| Variable | Description | Default |
|---|---|---|
| `ENABLE_BROWSER_SKILLS` | Enable browser automation skills | Not set |
| `ENABLE_CLAWDBOT_SKILLS` | Enable ClawdBot skills | Not set |
| `ENABLE_WORKSPACE_SKILLS` | Enable workspace management skills | Not set |
| `OPENCLAW_SKILLS` | Comma-separated list of active skills | Not set |

### Advanced Settings

| Variable | Description | Default |
|---|---|---|
| `NODE_OPTIONS` | Node.js runtime flags | `"--max-old-space-size=2048"` |
| `LOG_LEVEL` | Logging verbosity (`debug`, `info`, `warn`, `error`) | `info` |
| `ANTHROPIC_MODEL` | Override the default Anthropic model | `claude-sonnet-4-20250514` (commented out) |
| `OPENAI_MODEL` | Override the default OpenAI model | Not set (commented out) |

## Script Reference

### manage.sh -- Configuration Management

```bash
./manage.sh scaffold <name>              # Create a new bot config with auto-assigned port
./manage.sh list                         # Show all configs with port, VM status, validity
./manage.sh edit <name>                  # Open config in $EDITOR (default: nano)
./manage.sh copy <source> <dest>         # Duplicate a config (auto-assigns new port)
./manage.sh delete <name>                # Delete a config (with confirmation prompt)
./manage.sh validate <name>              # Check config for required fields and port conflicts
./manage.sh template telegram-bot <name> # Create from telegram-bot template (enables web + auto-approve email)
./manage.sh status                       # Show config status + active VMs + port usage
```

### provision.sh -- VM Provisioning

```bash
./provision.sh all                       # Build base VM (if needed) + clone all bots
./provision.sh <name>                    # Clone and deploy a specific bot
./provision.sh <name1> <name2>           # Clone and deploy multiple specific bots
./provision.sh rebuild-base              # Force-rebuild the base VM from scratch
./provision.sh validate <name>           # Run validation checks against a bot
./provision.sh validate all              # Run validation checks against all bots
./provision.sh status                    # Show status dashboard (VM state, service, HTTP)
./provision.sh --force all               # Skip confirmation prompts
```

The base VM (`openclaw-base`) is built once via `setup.sh` (~8 minutes). Each bot is then cloned from the base in seconds. The base VM uses port 18789 and is stopped after building so it can be cloned.

### setup.sh -- Core VM Setup

```bash
./setup.sh                               # Build the default base VM
./setup.sh config=<name>                 # Build a VM using a specific config file
```

This is the low-level script that provisions a fresh Ubuntu VM with Node.js, OpenClaw, Claude Code, a locked-down service user, firewall rules, and a systemd service. Normally called by `provision.sh` -- you rarely need to run it directly.

### validate.sh -- Validation

```bash
# Usually invoked via provision.sh:
./provision.sh validate <name>
./provision.sh validate all
```

Runs four checks against each bot: (1) systemd service is active, (2) HTTP gateway responds with 200, (3) email sending works, (4) dashboard opens in browser.

## Managing Bots

### View status of all bots

```bash
./provision.sh status
```

### After a Mac reboot

OrbStack launches at login by default and restores all VMs that were running before the reboot. Each VM's `openclaw` systemd service is enabled, so bots start automatically when the VM boots. **No manual action is needed.**

If VMs don't auto-restore (e.g. OrbStack auto-start is disabled), start them manually:

```bash
# Start all bot VMs
for vm in bubba mo quinn; do orb start "$vm"; done

# Verify everything is running
./provision.sh status
```

### Start or stop a bot VM

```bash
orb start <name>       # Start the VM
orb stop <name>        # Stop the VM
```

### View bot logs

```bash
orb -m <name> -u root journalctl -u openclaw -f
```

### Restart the OpenClaw service inside a VM

```bash
orb -m <name> -u root systemctl restart openclaw
```

### SSH into a bot VM

```bash
orb -m <name>                    # Connect as default user
orb -m <name> -u root           # Connect as root
```

### Update a bot's config and redeploy

```bash
./manage.sh edit mybot           # Change settings
./provision.sh mybot             # Redeploy (will prompt to delete and recreate the VM)
```

### Copy an existing bot to create a similar one

```bash
./manage.sh copy bubba newbot    # Copies config with new port
./manage.sh edit newbot          # Set the new Telegram token
./provision.sh newbot            # Deploy it
```

### Delete a bot

```bash
./manage.sh delete mybot         # Remove config file (prompts for confirmation)
orb delete mybot                 # Destroy the VM
```

### Open a bot's dashboard

The dashboard URL is `http://localhost:PORT` where PORT is the bot's `OPENCLAW_PORT`. The provisioning script opens it automatically and prints the URL with auth token.

## Credential Management

Shared credentials live in `.env.local` at the project root. This file is sourced before each bot's config, so bot configs can reference shared keys with `${VARIABLE_NAME}` syntax.

### Required keys

| Key | Source | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` | [Anthropic Console](https://console.anthropic.com/) | Required for all bots |

### Optional keys

| Key | Source | Notes |
|---|---|---|
| `OPENAI_API_KEY` | [OpenAI Platform](https://platform.openai.com/) | Only if using OpenAI models |
| `OPENCLAW_MODEL` | -- | Default model in `provider/model` format (e.g., `anthropic/claude-sonnet-4-20250514`) |
| `GITHUB_TOKEN` | [GitHub Settings > Tokens](https://github.com/settings/tokens) | For GitHub integration skill |
| `TELEGRAM_BOT_TOKEN` | [@BotFather](https://t.me/BotFather) | Shared default; usually overridden per bot |
| `TELEGRAM_USER_ID` | [@userinfobot](https://t.me/userinfobot) | For auto-approving Telegram pairing during setup |
| `SURGE_SMS_API_KEY` | Surge | For SMS notifications |
| `GOOGLE_WORKSPACE_CREDENTIALS_FILE` | GCP Console | Path to OAuth credentials JSON |

### Per-bot token overrides

Each bot config can set its own `TELEGRAM_BOT_TOKEN` directly (hardcoded value) rather than referencing `.env.local`. This is the typical setup since each bot needs its own Telegram identity.

When scaffolding, the generated config references `${TELEGRAM_BOT_TOKEN_NAME}` (uppercased bot name). You can either:
- Set `TELEGRAM_BOT_TOKEN_MYBOT=...` in `.env.local`, or
- Replace the line in `configs/mybot.env` with the literal token value (simpler)

## Troubleshooting

### "OrbStack not found" or orb command fails

Install OrbStack from [orbstack.dev](https://orbstack.dev). Ensure it is running (`orb status`).

### Base VM build fails or times out

The base VM build has a 10-minute timeout. If it fails:

```bash
orb delete openclaw-base         # Remove the failed base
./provision.sh rebuild-base      # Rebuild from scratch
```

### Bot VM won't start

```bash
orb list                         # Check VM state
orb start <name>                 # Try starting it
orb -m <name> -u root journalctl -u openclaw --no-pager -n 50   # Check logs
```

### HTTP gateway not responding (port check fails)

```bash
# Check if the service is running
orb -m <name> -u root systemctl status openclaw

# Check if the port is correct
grep OPENCLAW_PORT configs/<name>.env

# Check firewall rules inside the VM
orb -m <name> -u root ufw status

# Restart the service
orb -m <name> -u root systemctl restart openclaw
```

### Port conflict

If `./manage.sh validate <name>` reports a port conflict, edit the config and change `OPENCLAW_PORT` to an unused port. Ports start at 18790 and increment. Use `./manage.sh status` to see which ports are in use.

### Email validation fails

The email check requires Google Workspace credentials to be configured. Ensure:
1. `client_secret.json` (OAuth client) exists next to `setup.sh`
2. GWS credentials are exported to the VM (this happens automatically during provisioning)
3. The bot has `ENABLE_EMAIL_SENDING=true` in its config

### Config changes not taking effect

Config changes require re-provisioning the bot. The VM is deleted and re-cloned:

```bash
./provision.sh <name>            # Will prompt to delete and recreate
```

### Workspace files missing after provisioning

Template files (`AGENTS.md`, `SOUL.md`, etc.) are only copied from `workspace-base/` if they do not already exist in the bot's workspace. If `workspace-base/` is empty, no templates are copied. Check that the base VM was built successfully.
