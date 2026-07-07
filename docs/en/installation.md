# Installation Guide

This guide explains how to deploy **PD-Element Local** on a clean Ubuntu server.

The installer is fully interactive and will guide you through the required configuration.

---

# Before You Begin

Before running the installer, ensure the following requirements are met.

## Operating System

Supported:

- Ubuntu Server 22.04 LTS
- Ubuntu Server 24.04 LTS

A clean installation is strongly recommended.

---

## Hardware Requirements

### Small Deployment

- 2 CPU Cores
- 2 GB RAM
- 20 GB Storage

Suitable for:

- Home Labs
- Small Offices
- Development

---

### Medium Deployment

- 4 CPU Cores
- 8 GB RAM
- SSD Storage

Suitable for:

- Companies
- Schools
- Small Organizations

---

### Large Deployment

- 8+ CPU Cores
- 16+ GB RAM
- SSD/NVMe Storage

Suitable for:

- Enterprise Environments
- Large Organizations

---

# Network Requirements

The server should have:

- Static LAN IP
- Internal DNS
- Internet access during installation (recommended)

Once installed, Internet access is no longer required for normal operation.

---

# Required Ports

Open the following ports on your firewall.

| Port | Protocol | Purpose |
|-------|----------|---------|
| 80 | TCP | HTTP |
| 443 | TCP | HTTPS |
| 3478 | UDP/TCP | TURN |
| 5349 | TCP | TURN TLS |

---

# Internal DNS

Create DNS records before installation.

Example:

| Hostname | IP Address |
|----------|------------|
| matrix.company.local | 192.168.10.5 |
| element.company.local | 192.168.10.5 |

Verify DNS before continuing.

Example:

```bash
nslookup matrix.company.local
```

or

```bash
ping matrix.company.local
```

Both hostnames should resolve to the server IP.

---

# Download

Clone the repository.

```bash
git clone https://github.com/Amirabbasjadidi/PD-Element-Local.git

cd PD-Element-Local
```

Or run directly:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Amirabbasjadidi/PD-Element-Local/main/install.sh)
```

---

# Running the Installer

Run:

```bash
sudo bash install.sh
```

The installer must be executed as **root** or with **sudo**.

---

# Installation Wizard

The installer will ask several questions.

---

## Matrix Homeserver

Example:

```
matrix.company.local
```

This is the Matrix server address.

---

## Element Domain

Example:

```
element.company.local
```

This is the web interface users will access.

---

## Base Domain

Example:

```
company.local
```

Used internally for certificate generation.

---

## Server IP

Example:

```
192.168.10.5
```

Should be the server's static LAN address.

---

## PKI Directory

Default:

```
/etc/pd-element-local/pki
```

Stores:

- Root CA
- Intermediate CA
- Certificates
- Private Keys

---

## Root CA Lifetime

Example:

```
20 years
```

The Root CA rarely changes.

---

## Server Certificate Lifetime

Example:

```
730 days
```

Longer validity reduces maintenance while remaining manageable.

---

## Additional SANs

Optional.

Example:

```
chat.company.local
turn.company.local
```

Leave blank if not required.

---

# What Happens During Installation?

The installer performs the following tasks automatically:

- Installs Matrix Synapse
- Installs Element Web
- Installs Coturn
- Configures Nginx
- Creates the Enterprise PKI
- Generates Root CA
- Generates Intermediate CA
- Issues Server Certificates
- Configures TLS
- Configures TURN
- Configures Matrix
- Configures Element
- Enables Services
- Performs Health Checks

No manual configuration is normally required.

---

# After Installation

When installation finishes:

1. Run a Health Check.
2. Export the Root CA certificate.
3. Install the Root CA on all client devices.
4. Create an Administrator account.
5. Disable public registration (recommended).
6. Create user accounts.
7. Create an initial backup.

---

# First Login

Open:

```
https://element.company.local
```

Login using the administrator account created during installation.

---

# Updating

To update Element or perform maintenance, use the appropriate options from the main menu instead of manually replacing files.

---

# Troubleshooting

If the installer reports an error:

1. Verify DNS resolution.
2. Verify firewall rules.
3. Verify server time.
4. Run the Health Check.
5. Run the Fix Wizard.
6. Review the generated logs.

Most common issues can be resolved without reinstalling the server.

---

# Recommended Deployment Workflow

A recommended installation sequence is:

1. Prepare Ubuntu
2. Configure Internal DNS
3. Run the Installer
4. Verify Health Check
5. Export Root CA
6. Install the Root CA on client devices
7. Create Administrator
8. Create Users
9. Create Initial Backup

Following this workflow results in a clean, secure, and maintainable deployment.