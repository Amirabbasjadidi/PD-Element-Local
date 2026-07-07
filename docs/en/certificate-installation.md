# Installing the Root CA on Client Devices

After installing PD-Element Local, client devices must trust your organization's Root Certificate Authority (Root CA).

Without installing the Root CA, browsers and Matrix clients will display security warnings because your certificates are issued by your own PKI instead of a public Certificate Authority such as Let's Encrypt.

This guide explains how to install the Root CA on supported operating systems.

---

# Exporting the Root CA

Before installing the certificate on client devices, export the Root CA from the PKI Management menu.

Main Menu

↓

PKI Management

↓

Export Root CA

The exported file is usually named:

```

root-ca.crt

```

Distribute this file securely to your users.

---

# Windows

## Supported Versions

- Windows 10
- Windows 11
- Windows Server

## Installation

1. Double-click the certificate.
2. Click **Install Certificate**.
3. Select:

```

Local Machine

```

4. Click **Next**.
5. Select:

```

Place all certificates in the following store

```

6. Choose:

```

Trusted Root Certification Authorities

```

7. Finish the wizard.

Administrator privileges are required.

---

## Verify

Open:

```

certmgr.msc

```

Navigate to:

```

Trusted Root Certification Authorities

↓

Certificates

```

Your Root CA should appear in the list.

---

# Ubuntu / Debian

Copy the certificate.

```

sudo cp root-ca.crt /usr/local/share/ca-certificates/

```

Update the certificate store.

```

sudo update-ca-certificates

```

Expected output:

```

1 added, 0 removed

```

---

# RHEL / Rocky / AlmaLinux

Copy:

```

sudo cp root-ca.crt /etc/pki/ca-trust/source/anchors/

```

Then run:

```

sudo update-ca-trust

```

---

# Arch Linux

Copy:

```

sudo cp root-ca.crt /etc/ca-certificates/trust-source/anchors/

```

Then run:

```

sudo trust extract-compat

```

---

# macOS

Open:

```

Keychain Access

```

Import:

```

root-ca.crt

```

Move it into:

```

System Keychain

```

Double-click the certificate.

Expand:

```

Trust

```

Set:

```

When using this certificate:

Always Trust

```

Close the window.

Enter the administrator password.

---

# Android

## Android 11+

Copy:

```

root-ca.crt

```

to the device.

Open:

```

Settings

↓

Security

↓

Encryption & Credentials

↓

Install a Certificate

↓

CA Certificate

```

Select:

```

root-ca.crt

```

Accept the warning.

The certificate is now trusted by Android.

---

## Note

Some applications only trust the system certificate store.

Depending on the Android version and application, additional configuration may be required.

---

# iPhone / iPad (iOS)

Send the certificate to the device.

Open:

```

root-ca.crt

```

Tap:

```

Install

```

After installation:

Open:

```

Settings

↓

General

↓

About

↓

Certificate Trust Settings

```

Enable trust for your Root CA.

Without enabling trust, Safari and other applications will continue to display certificate warnings.

---

# Firefox

Firefox maintains its own certificate database.

Open:

```

Settings

↓

Privacy & Security

↓

Certificates

↓

View Certificates

↓

Authorities

↓

Import

```

Import:

```

root-ca.crt

```

Enable:

- Trust this CA to identify websites.

Save the changes.

---

# Google Chrome

Windows

Chrome automatically uses the Windows Certificate Store.

Linux

Chrome uses the operating system certificate store.

No additional configuration is normally required.

---

# Microsoft Edge

Edge also uses the operating system certificate store.

No additional configuration is required after installing the Root CA.

---

# Element Desktop

Element Desktop follows the operating system trust store.

Once the Root CA has been installed correctly, no further configuration is required.

---

# Element Web

If the browser trusts the Root CA, Element Web will automatically trust your Matrix server certificates.

---

# Verifying the Installation

Open your Element Web URL.

Example:

```

https://element.company.local

```

The browser should display:

- Secure Connection
- Valid Certificate
- No Security Warnings

---

# Common Problems

## Certificate Not Trusted

Possible causes:

- Installed in the wrong certificate store
- Missing administrator privileges
- Browser requires its own certificate store
- Incorrect certificate exported

---

## Certificate Warning Persists

Verify:

- Root CA installed correctly
- Correct certificate chain
- Server certificate matches the hostname
- SAN entries include the requested hostname

---

## Mobile Devices Still Show Warnings

Verify:

- Root CA installed
- Trust enabled (iOS)
- Correct Android certificate installation
- Device time is correct

---

# Security Recommendations

- Never distribute the Root CA private key.
- Only distribute the public Root CA certificate.
- Keep the Root CA private key offline whenever possible.
- Protect PKI backups.
- Revoke certificates immediately if a private key is compromised.
- Regularly review certificate expiration dates.

---

# Next Step

After all client devices trust the Root CA:

1. Create Administrator Accounts
2. Create User Accounts
3. Test Messaging
4. Test Voice Calls
5. Test Video Calls
6. Create the First Backup

Your private Matrix communication platform is now ready for production use.