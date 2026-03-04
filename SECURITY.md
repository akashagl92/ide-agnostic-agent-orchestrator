# Security Policy

## Reporting
Please report vulnerabilities privately to maintainers before public disclosure.

## Scope
Security-sensitive areas:
- command policy evaluation
- runtime profile transitions
- adapter event bridges
- telemetry/audit integrity

## Expectations
- Never commit secrets.
- Prefer deny-by-default controls.
- Keep SHADOW-safe behavior as default.
