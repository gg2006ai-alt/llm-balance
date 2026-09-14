# LLM Balance

A tiny native macOS menu-bar app that shows your **OpenRouter** and **DeepSeek** account balances at a glance.

No Electron, no web view — pure Swift + AppKit. The whole app is a single ~180 KB binary.

![macOS](https://img.shields.io/badge/macOS-12.0%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9+-orange)

## What it does

- Lives in the macOS **menu bar** and polls your provider balances
- Supported providers: **OpenRouter**, **DeepSeek** — each one can be enabled or disabled independently
- Shows current **balance** and **all-time usage** right in the dropdown menu
- Optional **launch at login** (LaunchAgent)
- API keys are stored **only** in macOS Keychain — never in plain files, never logged

## Download

Grab the latest `LLM Balance.dmg` from [Releases](../../releases), open it and drag the app to Applications.

Minimum system: macOS 12 (Monterey). Universal notes: built on Apple Silicon.

## Build from source

```bash
swiftc -O src/main.swift -o LLMBalance -framework AppKit -framework ServiceManagement
```

Then place the binary into an app bundle (see `dist/` for a ready-made `LLM Balance.app`).

## Privacy

- The app talks **only** to `openrouter.ai` and `api.deepseek.com` balance endpoints
- Keys live in the Keychain; nothing is sent anywhere else, nothing is logged
- No analytics, no telemetry

## Support

If the app is useful to you, you can support development with crypto:

**USDT (BNB Smart Chain / BEP20):**
```
0x6f1D0161aae17EB7Bf7cEC7e30BeE775CB149a08
```

> ⚠️ Make sure the network is set to **BNB Smart Chain (BEP20)** in your wallet before sending.

---

© StormCore AI — free to use, donations welcome.
