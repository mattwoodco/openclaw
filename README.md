# OpenClaw on OrbStack

One-script setup for [OpenClaw](https://github.com/open-claw/openclaw) in a hardened OrbStack Ubuntu VM on macOS.

## Prerequisites

- macOS with [OrbStack](https://orbstack.dev) installed
- An [Anthropic API key](https://console.anthropic.com/settings/keys)

## Quick start

```bash
cp .env.example .env.local   # fill in your keys
./setup.sh
```

The dashboard opens at `http://localhost:18789` when ready (~2 min).

## Configuration

Copy `.env.example` to `.env.local` and fill in the values:

| Variable | Required | Description |
|----------|----------|-------------|
| `ANTHROPIC_API_KEY` | One of these | Anthropic (Claude) &mdash; default provider |
| `OPENAI_API_KEY` | One of these | OpenAI (GPT) &mdash; alternative provider |
| `OPENCLAW_MODEL` | No | Default model in `provider/model` format (see below) |
| `GITHUB_TOKEN` | No | GitHub CLI ([create token](https://github.com/settings/tokens)) |
| `TELEGRAM_BOT_TOKEN` | No | Telegram bot interface |
| `TELEGRAM_USER_ID` | No | Skip pairing (get yours from [@userinfobot](https://t.me/userinfobot)) |
| `SURGE_SMS_API_KEY` | No | SMS notifications via Surge |

At least one AI provider key is required. You can set both to have a fallback.

### Choosing a model

Set `OPENCLAW_MODEL` in `.env.local` to change the default model. If not set, it defaults to `anthropic/claude-sonnet-4-20250514`.

```bash
# Examples
OPENCLAW_MODEL=anthropic/claude-sonnet-4-20250514    # default, best tool-calling
OPENCLAW_MODEL=anthropic/claude-haiku-4-5-20251001   # faster, cheaper
OPENCLAW_MODEL=openai/gpt-4o                         # requires OPENAI_API_KEY
OPENCLAW_MODEL=openai/o3-mini                        # requires OPENAI_API_KEY
```

> **Note:** OpenClaw relies heavily on tool calling (skills, cron, browser automation, etc.). Smaller or cheaper models often produce worse tool calls &mdash; wrong arguments, skipped tools, or malformed JSON. If things feel flaky, try a stronger model before debugging.

<details>
<summary>Telegram setup</summary>

1. Message [@BotFather](https://t.me/BotFather) &rarr; `/newbot` &rarr; copy the **bot token**
2. Set `TELEGRAM_BOT_TOKEN` in `.env.local`
3. To skip pairing, message [@userinfobot](https://t.me/userinfobot) for your numeric user ID &rarr; set `TELEGRAM_USER_ID`

</details>

<details>
<summary>Google Workspace setup</summary>

Gives the agent access to Gmail, Drive, Calendar, Sheets, and Docs.

1. [Google Cloud Console](https://console.cloud.google.com) &rarr; create a project
2. **Enable APIs**: Gmail, Drive, Calendar, Sheets, Docs
3. **Google Auth Platform &rarr; Branding**: fill in app name and emails
4. **Google Auth Platform &rarr; Audience**: click **Make internal** (Google Workspace) or add your email as a test user (personal Gmail)
5. **Google Auth Platform &rarr; Data Access**: add scopes &mdash; `gmail.modify`, `drive`, `calendar`, `spreadsheets`, `documents`, plus `openid`, `userinfo.email`, `userinfo.profile`
6. **Google Auth Platform &rarr; Clients**: create a **Desktop app** client
7. **Download JSON** &rarr; save as `client_secret.json` next to `setup.sh`

During setup, a browser window opens for Google sign-in. On rebuilds, existing credentials are reused automatically.

</details>

## Usage

```bash
# Dashboard (auto-authenticates)
open "http://localhost:18789/?token=$(orb -m openclaw -u root bash -c \
  'cat /home/ocagent/.openclaw/openclaw.json' | jq -r '.gateway.auth.token')"

# Terminal chat UI
orb -m openclaw -u root su -l -s /bin/bash ocagent -c 'openclaw tui'

# Shell into the VM
orb -m openclaw -u root su -l -s /bin/bash ocagent   # service user
orb -m openclaw -u root bash                          # root

# Open workspace in Cursor / VS Code
cursor --remote ssh-remote+orb /workspace/vm-openclaw

# Logs
orb -m openclaw -u root journalctl -u openclaw -f

# Rebuild from scratch
orb delete openclaw && ./setup.sh
```

## Cron jobs

Cron jobs let the agent run tasks on a schedule — reminders, checks, reports, etc.

```bash
# List all cron jobs
orb -m openclaw -u root su -s /bin/bash ocagent -c "openclaw cron list"

# Add a job that runs every 5 minutes
orb -m openclaw -u root su -s /bin/bash ocagent -c \
  'openclaw cron add --name "my-check" --every 5m --message "Check for new emails"'

# Add a daily job at 9am (Central time)
orb -m openclaw -u root su -s /bin/bash ocagent -c \
  'openclaw cron add --name "morning-brief" --cron "0 9 * * *" --tz America/Chicago --message "Give me a morning briefing"'

# Run a job immediately (for testing)
orb -m openclaw -u root su -s /bin/bash ocagent -c "openclaw cron run <job-id>"

# Remove a job
orb -m openclaw -u root su -s /bin/bash ocagent -c "openclaw cron rm <job-id>"

# Check scheduler status
orb -m openclaw -u root su -s /bin/bash ocagent -c "openclaw cron status"
```

You can also create cron jobs by chatting with the agent in the dashboard or Telegram — just ask it to set up a recurring task.

<details>
<summary>Cron not working? ("pairing required" error)</summary>

This means the CLI device doesn't have admin permissions. The setup script handles this automatically, but if it happens after an update or restart:

```bash
# Approve the pending device request
orb -m openclaw -u root su -s /bin/bash ocagent -c "openclaw devices approve --latest"

# Restart the gateway
orb -m openclaw -u root systemctl restart openclaw

# Verify cron works
orb -m openclaw -u root su -s /bin/bash ocagent -c "openclaw cron status"
```

</details>

## Workspace sync

The VM workspace is bind-mounted to `./workspace/` on your Mac &mdash; instant, bidirectional, no daemon.

```
Mac   ./workspace/
       ↕  bind-mount
VM    /workspace/vm-openclaw/
```

The rest of the Mac filesystem is blocked. Only this folder is exposed to the VM.

<details>
<summary>Multiple VMs</summary>

Each VM gets its own subfolder. Add a bind-mount in `mac-isolation.service` for each:

```
workspace/
├── vm-openclaw/     ← VM 1
├── vm-research/     ← VM 2
└── vm-builder/      ← VM 3
```

</details>

<details>
<summary>Obsidian integration</summary>

Open `./workspace/` as an [Obsidian](https://obsidian.md) vault to browse and edit agent files from your Mac or iPhone via [Obsidian Sync](https://obsidian.md/sync).

Useful plugins: **data-files-editor** (JSON, TXT), **obsidian-html-plugin** (HTML dashboards).

</details>

## Keeping the VM alive with the lid closed

If you close your MacBook lid, macOS sleeps and the VM stops. To prevent this while plugged in:

```bash
sudo pmset -c disablesleep 1
```

To re-enable lid sleep:

```bash
sudo pmset -c disablesleep 0
```

> **Note:** `caffeinate` only prevents idle sleep — it does **not** prevent lid-close sleep. `pmset disablesleep` is required.

## Troubleshooting

<details>
<summary>OpenClaw gateway is unreachable (port 18789 not listening)</summary>

The `openclaw.service` can die after a supervisor restart (SIGUSR1) without systemd detecting a failure, since the exit code is 0. Check and restart:

```bash
# Check service status
orb -m openclaw -u root systemctl status openclaw.service

# Restart the gateway
orb -m openclaw -u root systemctl restart openclaw.service

# Verify it's listening
orb -m openclaw -u root ss -tlnp | grep 18789
```

</details>

<details>
<summary>mac-isolation.service failed (workspace mount broken on reboot)</summary>

If the Mac workspace directory doesn't exist when the VM boots, the bind-mount fails. Fix:

```bash
# Ensure the workspace directory exists on your Mac
mkdir -p ./workspace

# Reset and restart the mount service
orb -m openclaw -u root systemctl reset-failed mac-isolation.service
orb -m openclaw -u root systemctl start mac-isolation.service
```

</details>


## Security

| Layer | Detail |
|-------|--------|
| Workspace mount | Only `./workspace/` is exposed; the rest of the Mac filesystem is blocked by a read-only tmpfs overlay |
| API keys | `.env.local` and `client_secret.json` are gitignored &mdash; rotate if the host is compromised |
| Gateway token | Grants full control; port 18789 is restricted to loopback and the OrbStack bridge |
| Agent user | `ocagent` has no sudo and no login shell, but retains outbound HTTPS access |
| VM isolation | Not a hard security boundary &mdash; OrbStack VMs share the host kernel |

## License

[MIT](LICENSE)
