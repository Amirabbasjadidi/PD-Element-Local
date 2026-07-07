# Enterprise PKI Guide

This document explains every option available in the **PKI Management** menu.

Unlike the original PD-Element project, PD-Element Local includes a complete internal Public Key Infrastructure (PKI) designed for enterprise local network deployments.

The PKI system eliminates the need for Let's Encrypt by allowing organizations to issue and manage their own trusted certificates.

---

# PKI Architecture

The installer creates a standard enterprise PKI hierarchy:

```

Offline Root CA
│
└── Intermediate CA
│
├── Matrix Certificate
├── Element Certificate
├── TURN Certificate
└── Future Services

```

The Root CA should be protected and used only when necessary.

The Intermediate CA is responsible for signing server certificates.

---

# 1. Initialize PKI

## Purpose

Create the complete PKI structure.

This operation creates:

- PKI directory
- Root CA
- Intermediate CA
- OpenSSL configuration
- Required permissions

## When should I use it?

- First installation
- Rebuilding a lost PKI

## Warning

Do not initialize a new PKI on an existing production server unless you intend to replace every certificate.

---

# 2. Create Root Certificate Authority

## Purpose

Generate the Root Certificate Authority.

The Root CA is the trust anchor for your entire infrastructure.

## Best Practice

Store the Root CA offline whenever possible.

Do not use the Root CA for signing server certificates directly.

---

# 3. Create Intermediate Certificate Authority

## Purpose

Generate an Intermediate CA signed by the Root CA.

All server certificates should be signed using the Intermediate CA.

## Why?

Keeping the Root CA offline significantly improves security.

---

# 4. Issue Server Certificate

## Purpose

Generate a TLS certificate for a server.

Supported services include:

- Matrix Synapse
- Element Web
- Coturn
- Other internal services

The installer automatically supports Subject Alternative Names (SANs).

---

# 5. Renew Certificate

## Purpose

Issue a replacement certificate before expiration.

The private key may be reused depending on configuration.

## Recommended

Renew certificates before they expire to avoid service interruptions.

---

# 6. Verify Certificate

## Purpose

Validate a certificate against the local trust chain.

Checks include:

- Signature validation
- Trust chain
- Expiration
- SAN entries
- Issuer information

---

# 7. Revoke Certificate

## Purpose

Mark a certificate as no longer trusted.

Typical reasons include:

- Compromised private key
- Device loss
- Server replacement

## Note

After revocation, a new certificate should be issued.

---

# 8. Export Root CA

## Purpose

Export the Root CA certificate.

This certificate should be installed on:

- Windows
- Linux
- macOS
- Android
- iOS

Without trusting the Root CA, browsers and Matrix clients will display certificate warnings.

---

# 9. Export Intermediate CA

## Purpose

Export the Intermediate CA certificate.

This is primarily useful for:

- Troubleshooting
- Certificate chain validation
- Enterprise integrations

---

# 10. Backup PKI

## Purpose

Create a secure backup of:

- Root CA
- Intermediate CA
- Private Keys
- Certificate Database
- CRL
- OpenSSL Configuration

## Recommendation

Store backups in multiple secure locations.

---

# 11. Restore PKI

## Purpose

Restore a previously created PKI backup.

Use this operation after:

- Server failure
- Migration
- Disaster recovery

---

# 12. Display PKI Information

## Purpose

Display useful information about the current PKI.

Information includes:

- Root CA
- Intermediate CA
- Validity period
- Certificate serials
- Issued certificates
- Revoked certificates

Useful for auditing and troubleshooting.

---

# 13. Return to Main Menu

Exit the PKI menu and return to the main application.

---

# Certificate Lifecycle

A typical enterprise certificate lifecycle looks like this:

1. Create Root CA
2. Create Intermediate CA
3. Issue Server Certificate
4. Install Certificate
5. Verify Certificate
6. Renew Before Expiration
7. Revoke if Compromised
8. Archive Old Certificates

---

# Security Recommendations

• Keep the Root CA offline whenever possible.

• Protect all private keys with appropriate file permissions.

• Never share private keys.

• Export only the Root Certificate to client devices.

• Always back up the PKI before making significant changes.

• Regularly review certificate expiration dates.

---

# Common Questions

## Why not Let's Encrypt?

PD-Element Local is designed for enterprise local networks where Internet access or public DNS may not be available.

An internal PKI provides complete control over certificate issuance and trust management.

---

## Do clients need to install the Root CA?

Yes.

Every client device must trust the Root CA to avoid TLS warnings and ensure secure communication with Matrix services.

---

## Can I replace the generated PKI with my organization's CA?

Yes.

Organizations with an existing Microsoft AD CS, HashiCorp Vault PKI, Smallstep CA, or another enterprise CA may replace the generated PKI with their own, provided the certificate chain remains trusted by client devices.