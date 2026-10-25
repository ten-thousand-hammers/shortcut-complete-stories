#!/usr/bin/env bash
# Completes the Shortcut stories shipped by a deployed release.
#
#   complete-stories.sh <release tag>
#
# Shortcut's GitHub integration links branches and pull requests to stories but
# never completes them, and a story isn't done until it's in production. The
# action runs this at the end of a deploy job, after the deploy is verified.
#
# The release covers every commit since the last successful deploy (not the
# previous tag, so a failed deploy's stories are completed by the next one that
# works). Each pull request merged into the base branch in that range names its
# stories as sc-NNNN in its branch name or title. The description doesn't
# count: it often mentions related or stacked stories that must stay open.
#
# Needs GH_TOKEN, SHORTCUT_TOKEN and GITHUB_REPOSITORY. WORKFLOW, BASE_BRANCH,
# END_STATE and SHORTCUT_WORKSPACE default to deploy.yml, main, Completed and
# apsure. Writes to GITHUB_STEP_SUMMARY when it's set. DRY_RUN=1 lists the
# stories and stops before Shortcut.
set -euo pipefail

tag="$1"
repo="$GITHUB_REPOSITORY"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
workflow_file="${WORKFLOW:-deploy.yml}"
base_branch="${BASE_BRANCH:-main}"
end_state="${END_STATE:-Completed}"
workspace="${SHORTCUT_WORKSPACE:-apsure}"

if [ -z "${SHORTCUT_TOKEN:-}" ] && [ -z "${DRY_RUN:-}" ]; then
  echo "::error::Set shortcut-token to complete stories when they deploy."
  exit 1
fi

# The newest successful deploy of another release. Deploy runs are titled
# "Deploy: <tag>" (the workflow's run-name). Runs titled with the release name,
# "Release <tag>", count too.
base="$(gh run list --repo "$repo" --workflow "$workflow_file" --status success --limit 20 \
  --json displayTitle --jq '.[].displayTitle' \
  | sed -nE 's/^(Deploy: |Release )//p' | grep -vxF "$tag" | head -1 || true)"
if [ -z "$base" ]; then
  echo "::notice::No earlier successful deploy, so no stories to complete."
  exit 0
fi

# compare returns nothing when the tag is behind the base (a redeploy of an
# older release), so a rollback completes nothing. It pages its commits, so a
# release that spans many fetches every page.
shas="$(gh api --paginate "repos/$repo/compare/$base...$tag?per_page=100" --jq '.commits[].sha')"

prs="$(for sha in $shas; do
  gh api "repos/$repo/commits/$sha/pulls" --jq ".[]
    | select(.merged_at != null and .base.ref == \"$base_branch\" and .head.repo.full_name == \"$repo\")
    | [.number, .head.ref, .title] | @tsv"
done | sort -u)"

ids="$(cut -f2- <<<"$prs" \
  | grep -oiE '(^|[^[:alnum:]])sc-[0-9]+' \
  | grep -oE '[0-9]+' | sort -un || true)"

{
  echo "### Shortcut"
  echo
  echo "Pull requests deployed since $base: $(cut -f1 <<<"$prs" | grep . | sed 's/^/#/' | paste -sd ' ' - | grep . || echo none)"
  echo
} >> "$summary"

if [ -z "$ids" ]; then
  echo "No stories named in those pull requests." >> "$summary"
  exit 0
fi

if [ -n "${DRY_RUN:-}" ]; then
  echo "Would complete: $(sed 's/^/sc-/' <<<"$ids" | paste -sd ' ' -)" >> "$summary"
  exit 0
fi

api="https://api.app.shortcut.com/api/v3"
shortcut() {
  curl -fsS -H "Shortcut-Token: $SHORTCUT_TOKEN" -H "Content-Type: application/json" "$@"
}

# A Shortcut error skips only that story; the rest are still attempted, and the
# step fails at the end so the warning shows on the run.
failed=""
for id in $ids; do
  if ! story="$(shortcut "$api/stories/$id")"; then
    echo "::warning::sc-$id was not found."
    echo "- sc-$id: not found" >> "$summary"
    continue
  fi

  if [ "$(jq -r .completed <<<"$story")" = true ]; then
    echo "- sc-$id: already done" >> "$summary"
    continue
  fi

  workflow_id="$(jq -r .workflow_id <<<"$story")"
  if ! workflow="$(shortcut "$api/workflows/$workflow_id")"; then
    echo "::warning::sc-$id's workflow could not be read."
    echo "- sc-$id: workflow could not be read" >> "$summary"
    failed=1
    continue
  fi
  state_id="$(jq -r --arg name "$end_state" '.states[] | select(.name == $name) | .id' <<<"$workflow")"
  if [ -z "$state_id" ]; then
    echo "::warning::sc-$id's workflow has no $end_state state."
    echo "- sc-$id: no $end_state state" >> "$summary"
    continue
  fi

  if ! shortcut -X PUT "$api/stories/$id" \
    -d "$(jq -cn --argjson state "$state_id" '{workflow_state_id: $state}')" > /dev/null; then
    echo "::warning::sc-$id could not be moved to $end_state."
    echo "- sc-$id: could not be moved to $end_state" >> "$summary"
    failed=1
    continue
  fi
  echo "- [sc-$id](https://app.shortcut.com/$workspace/story/$id): $end_state in $tag" >> "$summary"
done

[ -z "$failed" ]
