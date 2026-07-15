# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in BetterCast, please report it
privately so it can be addressed before public disclosure.

- **Email:** hi@stephenlovino.com
- Please use the subject line `BetterCast Security` and include:
  - A description of the vulnerability and its potential impact
  - Steps to reproduce (proof-of-concept if possible)
  - The affected version, platform, and connection mode (Wi-Fi or USB)

Please do **not** open a public GitHub issue for security vulnerabilities.

## What to Expect

- We aim to acknowledge your report within **72 hours**.
- We will keep you updated as we investigate and work on a fix.
- Once a fix is released, we are happy to credit you for the disclosure
  (let us know if you would prefer to remain anonymous).

## Scope

BetterCast streams display content directly between your own devices over
your local network (Wi-Fi or USB-C). It does not use relay servers, cloud
services, accounts, or telemetry, and it does not collect personal data.
Reports most relevant to this project include, for example:

- Flaws in the peer-to-peer streaming or device-discovery protocol
- Issues that could let an unauthorized device on the network connect,
  intercept, or inject display content
- Memory-safety or input-handling bugs in the sender or receiver apps

## Supported Versions

Security fixes are applied to the latest released version. Please make sure
you are running the most recent release before reporting an issue.
