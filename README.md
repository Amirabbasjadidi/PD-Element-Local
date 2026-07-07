# PD-Element Local

> Matrix Synapse + Element deployment toolkit for secure messaging, voice and video calls on enterprise local networks.

> 🇮🇷 **Persian Documentation:** [README.fa.md](README.fa.md)

---

## Overview

PD-Element Local is an automated installer and management toolkit for deploying a complete Matrix communication platform inside enterprise Local Area Networks (LAN).

Unlike the original PD-Element project, which targets public Internet deployments using Let's Encrypt, this project is specifically designed for private corporate environments with internal DNS and private PKI.

The installer automatically deploys and configures:

- Matrix Synapse
- Element Web
- Coturn (Voice & Video Calls)
- Nginx
- Internal PKI (Root CA + Intermediate CA)
- Internal TLS Certificates

No public Internet access or Let's Encrypt is required.

---

## Features

### Complete Matrix Stack

- Matrix Synapse
- Element Web
- Coturn TURN Server
- Nginx Reverse Proxy

---

### Enterprise PKI

Instead of Let's Encrypt, PD-Element Local automatically creates and manages an internal PKI.

Features include:

- Offline Root CA
- Intermediate CA
- Internal TLS Certificates
- Certificate Renewal
- Certificate Revocation
- Certificate Verification
- Root CA Export
- PKI Backup & Restore

---

### Local Network Ready

Designed specifically for enterprise environments.

- Internal DNS
- Custom Local Domains
- No Public DNS
- No Let's Encrypt
- No ACME
- Offline / Air-Gapped Support

---

### User Management

- Create Administrator
- Create User
- Random Password Generation
- List Users
- Deactivate Users
- Reactivate Users

---

### Backup & Restore

Complete backup of:

- Synapse
- Matrix Database
- Nginx
- Coturn
- PKI
- Certificates
- Configuration Files

---

### Health Checks

- Matrix Service
- Synapse
- Nginx
- Coturn
- Certificate Validation
- SAN Verification
- DNS Validation
- Port Checks

---

### Safety Features

- Automatic Rollback
- Configuration Validation
- Error Recovery
- Service Verification
- Logging

---

## Requirements

- Ubuntu Server
- Root Access
- Static IP Address
- Internal DNS Server

Recommended open ports:

- 80
- 443
- 3478
- 5349

---

## Quick Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Amirabbasjadidi/PD-Element-Local/main/install.sh)
```

or

```bash
git clone https://github.com/Amirabbasjadidi/PD-Element-Local.git
cd PD-Element-Local
sudo bash install.sh
```

---

## Documentation

Comprehensive documentation is available in the **docs/** directory.

### English

- `docs/en/installation.md` — Installation Guide
- `docs/en/main-menu.md` — Main Menu Guide
- `docs/en/pki-menu.md` — Enterprise PKI Guide
- `docs/en/certificate-installation.md` — Root CA Installation Guide

### Persian

Persian translations are available in:

- `docs/fa/`

---

## Project History

This project started as a fork of the original **PD-Element** project.

During development it was extensively redesigned for enterprise local network deployments.

Major architectural differences include:

- Internal PKI instead of Let's Encrypt
- Offline Root CA
- Enterprise Certificate Management
- Internal DNS Support
- Air-Gapped Deployment
- No Public Internet Dependency

Because of these differences, this project is maintained independently.

---

## Development Notice

This installer was redesigned with the assistance of AI tools, transforming the original public Internet deployment into an enterprise-focused local network solution.

Although it has been tested in a laboratory environment, there may still be edge cases, bugs, or opportunities for optimization.

Bug reports, pull requests, code reviews, and suggestions are always welcome.

---

## Archive

The original public deployment scripts and documentation have been moved to the **archive/** directory for reference.

---

## License

MIT License

---

⭐ If this project helps you, consider giving it a star.