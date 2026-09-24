# Security policy

## Reporting a vulnerability
Please **do not open a public issue**. Report privately via GitHub's
"Report a vulnerability" button (Security tab → Advisories) on this repository.

## Ground rules for contributors
- Never commit secrets, `.env*` files, service-account JSON, `.p8/.p12/.pem` keys, or `Secrets.xcconfig`.
  Backend secrets live in Firebase Secret Manager (`firebase functions:secrets:set`); CI secrets in GitHub Actions secrets.
- `VITE_*` variables are public — never put secrets in them.
- Enable the repo hooks once per clone: `git config core.hooksPath githooks`
  (runs the contract tests, a secret scan via gitleaks, and the malware tripwire).
- If a secret is ever committed, **rotate it immediately** — removing it from history is not enough on a public repo.
