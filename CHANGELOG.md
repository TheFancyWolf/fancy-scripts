# Changelog

All notable changes to Fancy Scripts will be documented here.

## [Unreleased]

### Added
- **Shared Library (`_lib/`)** — shared modules loaded via `require()`
  - `theme.lua` — 3-mode palette builder (Fancy Dark / Match Theme / Full Theme), shared font management, ImGui push/pop, settings combo widget
  - `json.lua` — lightweight JSON encoder/decoder (consolidated from inline copies)
  - `utils.lua` — dependency checks, undo block wrapper, track helpers, math utilities

## [1.0.0] - 2026-08-27

### Added
- **Fancy ParameterLink** — Link FX parameters between tracks (Follow/Inverse/adjustable strength)
- **Fancy Selected Track Meter** — Real-time visual metering for selected tracks
- **Fancy Copy Fader to Send** — Copy Main Fader volume to a Send
- ReaPack distribution with automated CI/CD pipeline
- GitHub Sponsors integration

---

*This changelog follows [Keep a Changelog](https://keepachangelog.com/) format.*
