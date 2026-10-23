# Claude Code instructions for Slant Studio

@AGENTS.md

## Claude-specific notes

- Follow "How work is done" in AGENTS.md for every task. Run every sub agent on Opus 5.5: pass `model: "opus"` on each Agent call.
- Agent worktrees (`isolation: "worktree"`) may be created from a stale commit. Tell each worktree agent to branch from current `main` and confirm it with `git log --oneline -1` before starting.
- Run long `swift test` and `./scripts/build-app.sh` runs in the background, and save the full log to a file. Don't let filters hide which test failed.
- Reviewers and auditors stay read-only and must not compile while another build or test run is using the same checkout.
- Every `./scripts/build-app.sh` changes the ad-hoc signature, so the next launch asks the owner to approve Keychain access again. When testing the packaged app, batch fixes into one rebuild before relaunching, and tell the owner when a prompt is waiting.
- Live testing against Slant may go up to, never including, payment. Don't rotate webhook secrets, disable platforms or send test webhooks without asking, and keep test drafts to a minimum, because Slant can't remove drafts.
