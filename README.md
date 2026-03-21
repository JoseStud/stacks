# Stacks

Docker Swarm stack definitions for the [GoodOldMeServer](https://github.com/JoseStud/GoodOldMeServer) homelab platform. This repository is consumed as a Git submodule by the infrastructure repo and deployed via Portainer GitOps and Ansible.

## Repository Structure

```
stacks/
├── stacks.yaml                  # Stack manifest (dependencies, health checks, Portainer flags)
├── infisical-agent.yaml         # Jinja2 template for Infisical Agent config (rendered by Ansible)
├── gateway/                     # Traefik v3 reverse proxy + docker-socket-proxy
├── auth/                        # Authelia SSO/2FA + PostgreSQL backend
│   └── config/                  #   Authelia configuration + users database template/bootstrap file
├── management/                  # Homarr dashboard + Portainer server/agent
├── network/                     # Vaultwarden + Pi-hole HA + Orbital Sync
├── observability/               # Prometheus + Loki + Promtail + Grafana + Alertmanager
│   └── config/                  #   Prometheus, Loki, Promtail, Alertmanager configs
├── media/
│   └── ai-interface/            # Open WebUI + OpenClaw
├── uptime/                      # Uptime Kuma status monitoring
└── cloud/                       # FileBrowser (GlusterFS file manager)
```

Each stack directory contains:

- `docker-compose.yml` — Swarm service definition
- `.env.tmpl` — Infisical Agent template that renders runtime `.env` files on each node

Stacks with bind-mounted configs (`auth`, `observability`) include a `config/` subdirectory. Ansible syncs static config files to GlusterFS, and the Infisical Agent renders selected runtime-managed config templates where needed.

## Stack Overview

| Stack | Services | Portainer-Managed | Depends On | Health Check |
|-------|----------|:-----------------:|------------|:------------:|
| **management** | homarr, portainer-server, portainer-agent | No | -- | -- |
| **gateway** | traefik, docker-socket-proxy | Yes | -- | `/healthz` |
| **auth** | authelia, authelia-db | Yes | gateway | `/api/health` |
| **network** | vaultwarden, vaultwarden-db, pihole-1, pihole-2, orbital-sync | Yes | gateway, auth | -- |
| **observability** | prometheus, loki, promtail, node-exporter, grafana, alertmanager | Yes | gateway, auth | -- |
| **ai-interface** | open-webui, openclaw | Yes | gateway, auth | -- |
| **uptime** | uptime-kuma | Yes | gateway, auth | -- |
| **cloud** | filebrowser | Yes | gateway, auth | -- |

**Deployment order:** management (Ansible Phase 6) -> gateway -> auth -> all remaining stacks (no ordering among themselves).

## Shared Conventions

All stacks follow these patterns:

- **Routing** — Traefik labels on `deploy.labels` (Swarm mode); `tls.certresolver=letsencrypt` for ACME TLS
- **Auth** — `authelia@swarm` ForwardAuth middleware on protected routes
- **Domains** — `${BASE_DOMAIN}` variable injected by Infisical Agent
- **Updates** — `order: start-first` for zero-downtime rolling updates
- **Resources** — Memory limits on every service; reservations on stateful or heavier workloads so Swarm can place them without overcommitting a node
- **Logging** — `json-file` driver, 10 MB rotation, 3 files max
- **Storage** — Most persistent data on GlusterFS at `/mnt/swarm-shared/<stack>/`; write-heavy pinned services can use node-local block-volume paths under `/mnt/app_data/local/<stack>/`
- **Image pinning** — Critical services version-pinned; utility/dashboard services may use `:latest`

## Secrets Management

Secrets are stored in [Infisical](https://infisical.com) and injected at runtime:

1. Each stack has a `.env.tmpl` that references Infisical paths (e.g., `/infrastructure`, `/stacks/<name>`)
2. The Infisical Agent (systemd service on each node) renders `.env.tmpl` -> `.env` and selected config templates every 60 seconds
3. On change, the agent triggers a Portainer webhook (or direct `docker stack deploy` for the management stack)

Global variables (`BASE_DOMAIN`, `TZ`) come from `/infrastructure`. Stack-specific secrets live under `/stacks/<name>`.

## CI Pipeline

### Stacks CI (`stacks-ci.yml`)

Runs on PRs and pushes to `main` when stack-related files change:

- **Manifest validation** — Verifies `stacks.yaml` structure, required fields, `depends_on` references, and compose file validity (`docker compose config --no-interpolate`)
- **Redeploy planner contract tests** — Validates the v5 dispatch payload planning logic

### Stacks Dispatch Redeploy (`stacks-dispatch-redeploy.yml`)

Triggered automatically after a successful Stacks CI run on `main`:

1. Builds a v5 redeploy request payload (SHA, source metadata)
2. Validates the payload against the dispatch contract
3. Dispatches a `stacks-redeploy-intent-v5` event to the infrastructure repo, which triggers the full orchestrator pipeline

### Trust Boundary

The infrastructure repo's orchestrator verifies this repo's SHA before consuming it:

- SHA must be on the `main` branch lineage
- All observed GitHub CI signals (checks + statuses) must be green
- At least one CI signal must exist

This separates public stacks-repo CI evidence from the private runner stages that mutate infrastructure.

## Integration with Infrastructure Repo

This repo is consumed by GoodOldMeServer at multiple layers:

| Layer | How Stacks Are Used |
|-------|---------------------|
| **Ansible** | Phase 4 (`sync-configs`): syncs static `config/` files to GlusterFS and seeds placeholders. Phase 7 (`runtime_sync`): mirrors checkout to `/opt/stacks`, renders Infisical Agent config, and installs runtime helpers |
| **Terraform** | `portainer-root` pins Portainer GitOps stack definitions to this repo's `main` branch |
| **Dagger CI** | Preflight phase verifies stacks SHA trust. Portainer phase applies stack updates and triggers health-gated redeploys |
| **Dependabot** | Manages submodule update PRs (`gitsubmodule` ecosystem) |

## Adding a New Stack

1. Create `<name>/docker-compose.yml` following the shared conventions above
2. Add secrets to Infisical under `/stacks/<name>`
3. Create `<name>/.env.tmpl` for the Infisical Agent
4. If config files are needed, add `<name>/config/` and a sync task in Ansible's `glusterfs` role
5. Register the stack in `infisical-agent.yaml`
6. Add the stack entry to `stacks.yaml` with `compose_path`, `portainer_managed`, `depends_on`, and optional health check fields
7. Run Ansible `phase7_runtime_sync` to converge `/opt/stacks` and the agent config
8. If the stack is Portainer-managed, add its env mapping in `terraform/portainer/main.tf` so Portainer receives the required compose variables from Infisical
9. Deploy: use `docker stack deploy` for non-Portainer stacks, or let Terraform + Portainer webhook automation handle Portainer-managed stacks
10. Update documentation in the infrastructure repo (`docs/stacks.md`, `docs/deployment-runbook.md`)

## Full Documentation

Detailed architecture, per-stack configuration, environment variable mappings, and operational procedures are in the infrastructure repo:

- [Application Workloads (Stacks)](https://github.com/JoseStud/GoodOldMeServer/blob/main/docs/stacks.md)
- [Infisical Secrets Workflow](https://github.com/JoseStud/GoodOldMeServer/blob/main/docs/infisical-workflow.md)
- [Deployment Runbook](https://github.com/JoseStud/GoodOldMeServer/blob/main/docs/deployment-runbook.md)
