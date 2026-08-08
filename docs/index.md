---
layout: default
title: Home
description: A unified, one-command SSO Manager + OIDC proxy stack for home labs and small businesses. Wires together a self-hosted identity provider and a reverse proxy with one setup.sh.
---

# Theta suite

Theta Suite is your one-line solution to replacing fragmented, hard-to-wire
authentication setups with a unified security stack. It wires together OIDC
authentication, LDAP user directories, automated host enrollment, and
centralized secret management in a single command. It eliminates the manual
configuration friction so you get secure access, auditability, and multi-site
replication running in seconds.

##  Who This Is For
* **Self-Hosters & Homelab Engineers:** Anyone running local bare metal,
  Proxmox, or private VPS nodes who wants enterprise-grade OIDC, multi-master
  LDAP, PAM/SSSD host enrollment, and OpenBao secret management without spending
  days manually wiring glue code.
* **Small-to-Medium Businesses (SMBs):** Infrastructure teams that need a
  unified, directory-driven access plane across both web apps and Linux boxes,
  but want to bypass per-user SaaS taxes (Okta, Azure AD) and cloud vendor
  lock-in.
* **DevOps & Systems Operators:** Engineers who value idempotent, single-command
  deployments (`./setup.sh`) and need a production-grade baseline supporting
  zero-trust proxying, SSH jump-host access control, and multi-site replication
  out of the box.

## Screenshots

The SSO Manager and the proxy it fronts, both stood up by one `./setup.sh` run:

<a href="images/sso-dashboard.png" target="_blank"><img src="images/sso-dashboard.png" alt="SSO Manager dashboard" width="49%"></a>
<a href="images/proxy-hosts.png" target="_blank"><img src="images/proxy-hosts.png" alt="Proxy host list" width="49%"></a>
<a href="images/jump-dashboard.png" target="_blank"><img src="images/jump-dashboard.png" alt="Jump Host dashboard" width="49%"></a>

*(click either screenshot to view full size)*

## What you get

- **Unified SSO Manager**: An OpenID Connect (OIDC) provider and OAuth 2.0
  authorization server fronted by TLS. Includes a web dashboard for managing
  users, groups, and OAuth apps, plus automated invitation and password reset
  flows.
- **Identity-Aware Reverse Proxy**: Intercepts HTTP/HTTPS traffic to protect
  upstream applications with OIDC login and direct LDAP group authorization,
  featuring automatic TLS certificate issuance and automated host routing.
- **Embedded LDAPS Directory**: A bundled OpenLDAP core acting as your single
  source of truth for POSIX accounts, SSH public keys, and sudo roles. Native
  apps, legacy infrastructure, and Linux machines authenticate directly over
  encrypted LDAPS (port 636) or StartTLS.
- **Hierarchical Directory Group & Permission Model**: Every adopted application
  and machine automatically inherits dedicated `admin`, `access`, and
  `capability` groups generated directly from the LDAP directory. These map
  cleanly to real POSIX groups for fine-grained sudo and SSH privilege controls. 
  See [Group & Permission Model](GROUPS.html).
- **Automated Linux Host Enrollment (ldap-client)**: A lightweight host agent
  that enrolls Linux machines into the central directory. It configures system
  PAM/SSSD for login, applies sudo policies, distributes SSH public keys, and
  registers host telemetry in the primary inventory dashboard.
- **Directory-Driven SSH Jump Host**: A centralized bastion host that routes
  inbound terminal traffic (`ssh uid_-_host@jump.<domain>`) using active
    directory group memberships. Supports WinSCP, file transfers, interactive
    host pickers, and a dedicated audit interface for tracking user sessions and
    connection metrics.
- **Central Secrets Engine (OpenBao integration)**: Bootstraps every component
  against an embedded [OpenBao](https://openbao.org/) instance to load tokens
  and cryptographic keys at runtime. Provides per-user secret vaults and enables
  administrators to mint scoped API tokens for external services. See
  [Secrets](secrets.html).
- **Self-Service & CI/CD API Tokens**: Granular, personal access token
  management built directly into the web interface, allowing operators to drive
  system administration and automation pipelines programmatically without an
  active browser session.
- **Multi-Site Geo-Replication**: Built-in support for N-Way Multi-Master LDAP
  replication, allowing directory states to sync across geographically separated
  physical hardware or remote data centers for high availability and low-latency
  local reads.
- **Multi-Target Load Balancing**: Native reverse-proxy load balancing that
  distributes traffic across multiple application backends using customizable
  health checks and round-robin strategies.

## Get it

```bash
git clone --recursive https://github.com/theta42/theta-suite.git
cd theta-suite
cp setup.env.example setup.env     # then edit setup.env: set CFG_DOMAIN to your domain
./setup.sh
```

You need a **Domain**, some **Ports Forwarded**,  **Docker** +
**Docker Compose**. `./setup.sh` is idempotent — re-run any time to converge the
stack to `./config/`. For the full config reference, architecture, see the
**[GitHub repository](https://github.com/theta42/theta-suite#before-you-begin)**
for a details.

## Related projects

- **[SSO Manager](https://theta42.github.io/sso-manager-node/)** — the OIDC
  provider + LDAP directory this stack runs.
- **[Proxy](https://theta42.github.io/proxy/)** — the reverse proxy this
  stack runs in front of it.
- **[Jump Host](https://theta42.github.io/jump-host/)** — the SSH jump
  host this stack brings up.
- **[ldap-client](https://theta42.github.io/ldap-client/)** — enrolls Linux
  hosts into the directory this stack serves.
