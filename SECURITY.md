# Security policy

## Reporting a vulnerability

Please report security problems privately. Do not open a public issue.

Use GitHub's private reporting: on this repository, go to **Security → Report a vulnerability**. If that option isn't available, contact [@divingsbysangam](https://github.com/divingsbysangam) on GitHub and ask for a private channel before sharing details.

Include what you found, the Sotto version (Help → About Sotto), your macOS version, and steps to reproduce. A proof of concept helps. Please don't include real transcripts, audio or other personal data.

This is a small project maintained by one person. I aim to acknowledge reports within a week and to tell you what I plan to do. I'll credit you in the release notes if you'd like that.

## Supported versions

Only the latest release gets security fixes. Sotto updates itself through Sparkle, so please update before reporting.

## What counts

Sotto runs locally with several sensitive macOS permissions, so these areas matter most:

- **Permissions and event taps.** Microphone, Accessibility, Screen Recording and Input Monitoring use, including the key and mouse event taps and the Space-swallowing tap that is active while the dictation key is held.
- **Data handling.** Transcript text, audio, clipboard contents, selected text and screen text leaving the Mac, being logged, or being stored when they shouldn't be. Sotto is meant to send none of these anywhere.
- **Model downloads.** Weakened pinning or SHA-256 verification in `Sotto/Resources/*manifest.json` and the downloaders, or a way to make the app load an unverified model.
- **Updates.** Anything that lets an update be served or installed without a valid Sparkle EdDSA signature.
- **Coding-agent relay and the `sotto` command-line tool.** File permissions and trust in `Application Support/Sotto/AgentRelay`, the hook protocol, and automation links (`sotto://`).
- **Paste safety.** Text pasted into the wrong app, or into a password field.

## Out of scope

- Issues that need an attacker who already has your user account, root access, or physical access to an unlocked Mac.
- Problems in a dependency that don't affect Sotto. Report those upstream. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the list.
- Release builds are signed with a self-signed certificate, not an Apple Developer ID, so Gatekeeper shows a warning on first open. That is known and documented in the release notes.
