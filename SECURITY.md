# Security policy

## Reporting a vulnerability

If you believe you have found a security issue in Capfire, **do NOT open a
public GitHub issue**. Instead:

1. Report it privately via
   [GitHub Security Advisories](https://github.com/ricardo5401/capfire/security/advisories/new).
2. Include enough detail for us to reproduce (affected endpoints, token
   claims, HTTP payload, version of Capfire).

You will get an acknowledgement within 72 hours and a plan within a week.

## Supported versions

Capfire is pre-1.0; only the latest tagged release receives security fixes.
After 1.0 we will commit to a published support window.

## Attack surface summary

Capfire is a **deploy orchestrator with direct shell access** to the host.
Compromising the server is equivalent to compromising every app it deploys.
See [docs/server/security.md](docs/server/security.md) for the full threat
model, input validation rules, JWT hygiene, and production checklist.

## Hardening the repository

If you fork Capfire and run it in production, at minimum:

- Rotate `CAPFIRE_JWT_SECRET` immediately — the default installer generates
  a fresh one, but verify it.
- Do NOT expose the Capfire server to the public internet. Keep it behind a
  VPN, Tailscale, or Cloudflare Tunnel.
- Audit `bin/capfire tokens list` periodically — revoke anything you don't
  recognize.
- Keep the box patched (`unattended-upgrades` on Debian/Ubuntu).
