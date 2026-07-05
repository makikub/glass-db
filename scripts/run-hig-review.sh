#!/usr/bin/env bash
set -u

repo_root="$(git rev-parse --show-toplevel)" || exit 1
cd "$repo_root" || exit 1

if [ "${GLASSDB_SKIP_HIG_REVIEW:-}" = "1" ]; then
  echo "GlassDB HIG review skipped because GLASSDB_SKIP_HIG_REVIEW=1." >&2
  exit 0
fi

changed_files="$(git diff --cached --name-only --diff-filter=ACM)"

case "$changed_files" in
  *Sources/GlassDB/*.swift*|*AGENTS.md*|*README.md*|*.agents/skills/apple-hig-review/*)
    ;;
  *)
    exit 0
    ;;
esac

codex_candidates=()
if [ -n "${GLASSDB_HIG_REVIEW_CODEX:-}" ]; then
  codex_candidates+=("$GLASSDB_HIG_REVIEW_CODEX")
fi
if command -v codex >/dev/null 2>&1; then
  codex_candidates+=("$(command -v codex)")
fi
codex_candidates+=("/Applications/Codex.app/Contents/Resources/codex")

codex_cli=""
for candidate in "${codex_candidates[@]}"; do
  if [ -x "$candidate" ] && "$candidate" exec --help >/dev/null 2>&1; then
    codex_cli="$candidate"
    break
  fi
done

if [ -z "$codex_cli" ]; then
  echo "GlassDB HIG review skipped: working codex exec CLI not found." >&2
  exit 0
fi

prompt='Use the repo skill $apple-hig-review. Act as a HIG reviewer subagent for the staged diff only. Review Apple HIG and macOS UI regressions. Do not edit files. Return only the required HIG_REVIEW verdict format.'

output_file="$(mktemp "${TMPDIR:-/tmp}/glassdb-hig-review.XXXXXX")"
error_file="$(mktemp "${TMPDIR:-/tmp}/glassdb-hig-review.err.XXXXXX")"

git diff --cached -- . \
  | "$codex_cli" exec --ephemeral --sandbox read-only "$prompt" \
    >"$output_file" 2>"$error_file"
status=$?

if [ "$status" -ne 0 ]; then
  echo "GlassDB HIG review skipped: codex exec failed." >&2
  sed -n '1,40p' "$error_file" >&2
  if [ "${GLASSDB_HIG_REVIEW_REQUIRED:-}" = "1" ]; then
    exit "$status"
  fi
  exit 0
fi

cat "$output_file"

if grep -q '^HIG_REVIEW: FAIL' "$output_file"; then
  echo "Commit blocked by GlassDB HIG review." >&2
  exit 1
fi

if ! grep -q '^HIG_REVIEW: PASS' "$output_file"; then
  echo "Commit blocked: HIG review did not return a PASS verdict." >&2
  exit 1
fi

exit 0
