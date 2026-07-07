\# Main Menu Guide



This document explains every option available in the \*\*PD-Element Local\*\* main menu.



The goal is not only to describe what each option does, but also when it should be used, what prerequisites it has, and what to expect after running it.



\---



\# 1. Install / Reinstall Matrix + Element + TURN



\## Purpose



Deploy or reinstall the complete Matrix communication stack.



This option installs and configures:



\- Matrix Synapse

\- Element Web

\- Coturn TURN Server

\- Nginx

\- Internal PKI

\- TLS Certificates

\- Matrix configuration

\- Element configuration

\- TURN integration

\- Health validation



\## When should I use it?



\- First installation

\- Reinstalling a damaged installation

\- Migrating to a new server

\- Rebuilding the environment



\## Required Information



The installer will ask for:



\- Matrix Homeserver Domain

\- Element Domain

\- Base Domain

\- Server LAN IP

\- PKI Directory

\- Root CA Lifetime

\- Server Certificate Lifetime

\- Additional SANs (optional)



\## Notes



This operation is safe to run multiple times.



Existing configuration will be reused whenever possible.



\---



\# 2. Create Admin User



\## Purpose



Create a new Matrix administrator.



The account receives administrator privileges and can manage the server from Matrix administration tools.



\## When to use



\- Initial server setup

\- Creating additional administrators



\## Recommendation



Only trusted users should receive administrator privileges.



\---



\# 3. Create Normal User



\## Purpose



Create a standard Matrix user.



The account has no administrative permissions.



\## Typical Usage



Use this option when onboarding employees or organization members.



\---



\# 4. Create User with Random Password



\## Purpose



Automatically generate a strong password.



The script:



\- Generates a secure random password

\- Creates the user

\- Prints the generated password



\## Recommended For



\- Large deployments

\- Enterprise onboarding

\- Temporary accounts



\---



\# 5. Reactivate User



\## Purpose



Enable an existing user that has previously been disabled.



\## Typical Usage



Employee returns to the organization.



Temporary suspension has ended.



\---



\# 6. List Users



\## Purpose



Display all Matrix users currently registered on the server.



Useful for:



\- Administration

\- Auditing

\- Verifying user creation



\---



\# 7. Deactivate User



\## Purpose



Disable an account without deleting it.



The user:



\- Cannot log in

\- Cannot access Matrix services



The account information remains in the database.



\## Recommended Instead of Deletion



Deactivation preserves historical messages and audit information.



\---



\# 8. Set Upload Limits



\## Purpose



Change the maximum upload size.



This updates both:



\- Nginx

\- Matrix Synapse



The services are automatically reloaded.



\## Example



Increase upload size from 50 MB to 250 MB.



\---



\# 9. Toggle Registration



\## Purpose



Enable or disable public registration.



When disabled:



\- Users cannot register themselves

\- Administrators can still create users using this script



\## Enterprise Recommendation



Disable public registration after initial deployment.



\---



\# 10. Health Check



\## Purpose



Run a complete health inspection.



Checks include:



\- Matrix Synapse

\- Element

\- Coturn

\- Nginx

\- Certificates

\- Internal DNS

\- Ports

\- Disk Usage

\- Memory Usage



\## Recommended



Run after:



\- Installation

\- Updates

\- Certificate renewal

\- Network changes



\---



\# 11. Fix Wizard



\## Purpose



Automatically repair common deployment problems.



Examples include:



\- Broken Nginx configuration

\- Missing symbolic links

\- Disabled services

\- Incorrect service state



\## Recommendation



Run this before attempting manual troubleshooting.



\---



\# 12. Backup Server



\## Purpose



Create a complete backup.



The backup includes:



\- Matrix configuration

\- Database

\- Nginx

\- Coturn

\- PKI

\- Certificates

\- Server configuration



\## Recommended



Create a backup before:



\- Updating

\- Renewing certificates

\- Major configuration changes



\---



\# 13. Restore Backup



\## Purpose



Restore a previously created backup.



This operation returns the server to an earlier working state.



\## Warning



Restoring a backup may overwrite current configuration and certificates.



\---



\# 14. Call Diagnostics



\## Purpose



Troubleshoot voice and video call issues.



The diagnostic tool verifies:



\- TURN server

\- Synapse TURN configuration

\- Required ports

\- Network configuration

\- WebRTC readiness



\## Recommended



Run whenever users experience:



\- Failed voice calls

\- Failed video calls

\- ICE negotiation problems



\---



\# 15. Update Element Web



\## Purpose



Upgrade Element Web to a newer version.



The updater:



\- Downloads the requested release

\- Preserves your configuration

\- Replaces application files

\- Reloads Nginx



\## Recommendation



Always create a backup before updating.



\---



\# 16. Full Uninstall / Purge



\## Purpose



Completely remove the Matrix deployment.



Removed components include:



\- Matrix Synapse

\- Element

\- Coturn

\- Nginx configuration

\- Matrix database

\- Configuration files



Optionally:



\- Local PKI



\## Warning



This operation is destructive.



Use only when permanently removing the server.



\---



\# 17. PKI Management



\## Purpose



Open the Enterprise PKI management menu.



This menu provides:



\- Root CA management

\- Intermediate CA management

\- Certificate issuance

\- Certificate renewal

\- Certificate verification

\- Certificate export

\- PKI backup

\- PKI restore



The PKI menu is documented separately in \*\*pki-menu.md\*\*.



\---



\# 18. Exit



Exit the installer.



No changes are made to the system.



\---



\# Best Practices



For a new deployment, the recommended workflow is:



1\. Install Matrix Stack

2\. Run Health Check

3\. Export Root Certificate

4\. Install the Root CA on client devices

5\. Create an Administrator

6\. Disable Public Registration

7\. Create User Accounts

8\. Create a Backup



Following this order helps ensure a clean and secure deployment.

