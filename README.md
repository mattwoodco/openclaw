# OpenClaw Multi-Bot Management System

Configuration-first approach to managing multiple OpenClaw bot instances.

## Quick Start

```bash
# 1. Create bot configurations
./manage.sh scaffold bubba
./manage.sh scaffold mo  
./manage.sh scaffold quinn

# 2. Customize settings (optional)
./manage.sh edit bubba

# 3. Deploy bots
./provision.sh bubba           # Deploy specific bot
./provision.sh all             # Deploy all configured bots
./setup.sh config=bubba        # Alternative deployment method

# 4. Manage bots
./vm-ops.sh status             # View all bot statuses
./vm-ops.sh start bubba        # Start specific bot
./vm-ops.sh logs mo            # View bot logs
```

## System Structure

```
configs/                   # Bot configurations
├── bubba.env              # Bubba bot settings
├── mo.env                 # Mo bot settings  
└── quinn.env              # Quinn bot settings

workspace-bubba/           # Bubba's workspace
workspace-mo/              # Mo's workspace
workspace-quinn/           # Quinn's workspace
```

## Management Scripts

- **manage.sh** - Configuration management (create, edit, validate configs)
- **provision.sh** - VM provisioning (deploy configured bots)
- **vm-ops.sh** - VM operations (start, stop, monitor, logs)
- **setup.sh** - Core setup script (with config mode support)

## Bot Configuration

Each bot has its own configuration file with:
- Unique port (18790, 18791, 18792)
- Individual Telegram bot token
- Shared credentials from .env.local
- Dedicated workspace directory
- Custom feature flags and settings

## Credential Management

Bots inherit API keys from `.env.local`:
- ANTHROPIC_API_KEY
- OPENAI_API_KEY
- GITHUB_TOKEN
- Google Workspace credentials

Individual tokens can be overridden in bot configs.

## See Also

- `dev_configs.md` - Bot tokens and configuration
- `fly-io-plan.md` - Fly.io deployment plan