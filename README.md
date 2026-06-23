# Cortex — public distribution

Tokenless install of the **Cortex** macOS app. This repo mirrors the
installer and the prebuilt release artifacts (`Cortex-arm64.zip`,
`support.tar.gz`) published from the private source repo.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/appfactory123/cortex-ai-sessions-dist/main/install.sh | bash
```

Installs `Cortex.app` to `/Applications` and provisions `~/.cortex-ai-sessions`.
Runs alongside the separate AMC app without conflict.
