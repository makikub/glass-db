---
name: glassdb-issue-batch
description: Coordinate GlassDB GitHub issues from one Sol implementation task per issue through batched release verification. Use when selecting, starting, resuming, or handing off GlassDB issues; when an issue reaches PR merge; when preparing the batch release; or when GitHub CLI authentication, Computer Use bundle selection, notarization, or duplicate-task prevention affects this workflow.
---

# GlassDB Issue Batch

Use this workflow for the GlassDB issue automation.

## Ownership

- The management thread selects work, prevents duplicate tasks, collects handoffs, and performs the batched release after several issues are merged.
- A single `gpt-5.6-sol` task with `medium` reasoning owns one issue's investigation, implementation, tests, HIG review when UI changes, Computer Use, self-review, PR updates, and merge.
- Keep merged issues open until the batch release passes. The management thread then validates the public release across all included issues and closes them together.

## Start Or Resume An Issue

1. Read the open issues and their dependency text.
2. Select one issue whose implementation dependencies are already merged to `main`.
3. Search tasks by both `GlassDB issue #<number>` and the exact issue title.
4. If a matching task is active, wait. If it is idle, blocked, completed, or archived while the issue remains unfinished, resume that same task. Create a task only when neither search finds one.
5. Record the task id immediately. Never create a second task for the same issue.

## Sol Task Contract

Require the Sol task to:

- read `AGENTS.md`, the issue, current `main`, and relevant file history;
- implement the narrow issue scope, test it, and correct its own review findings;
- run `swift build -c debug`, `swift test`, relevant real-DB integration tests, `$apple-hig-review` for UI changes, and Computer Use on a uniquely named debug bundle;
- create and merge the PR only after review threads and CI are clear;
- leave release, Pages, public-zip validation, issue close, and goal completion to the management batch;
- return a compact handoff with PR, merge SHA, test/HIG/Computer Use evidence, and any batch-release risks.

If nested agents are available without creating another Codex task, use a separate internal review pass. Otherwise the Sol task performs the review itself.

## GitHub CLI And Keychain

In Codex sandboxed commands, `gh` can falsely report the stored token as invalid because it cannot read the macOS Keychain. This is not a worktree-specific authentication failure.

- Use the GitHub connector for normal issue and PR metadata when possible.
- Before any CLI-based GitHub diagnosis or mutation, run `gh auth status` with escalated permissions.
- Run subsequent `gh` PR, issue, and Actions commands with the same scoped escalation.
- Do not run `gh auth login`, replace credentials, or declare the token invalid based only on a sandboxed result.

Read [references/environment-boundaries.md](references/environment-boundaries.md) before running real-DB integration, Computer Use, signing, or release commands.

## Batch Release

Read [references/release-gates.md](references/release-gates.md) only when beginning the shared release phase.
