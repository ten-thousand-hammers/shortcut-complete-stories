# shortcut-complete-stories

Moves the Shortcut stories a release shipped to **Completed** once the release
is deployed. Shortcut's GitHub integration links branches and pull requests to
stories but never completes them, and a story isn't done until it's in
production.

Used with the changelog actions suite:
`changelog-generate` → `changelog-merge` → `changelog-release` → deploy →
**`shortcut-complete-stories`** → `changelog-notify`.

## How it works

- **The release** is every commit since the last successful deploy, not since
  the previous tag, so a failed deploy's stories complete with the next deploy
  that works. The last deploy is the newest successful run of `workflow` titled
  `Deploy: <tag>` or `Release <tag>`, for a tag other than `release-tag`.
- **A failed Shortcut update is retried** by the next deploy. With
  `continue-on-error`, the run still succeeds and the API reports the failed
  step as a success too, so the action logs `shortcut-complete-stories: started`
  and, when it succeeds, `shortcut-complete-stories: finished`. A run whose job
  log has the first line but not the second is passed over. A run without
  either line (from before v1.1.0, or whose logs have expired) counts. A dry run
  or a release with no stories succeeds, so it counts too.
- **The stories** are read as `sc-NNNN` from the branch name and title of each
  pull request merged into `base-branch` in that range. The description doesn't
  count: it often mentions related or stacked stories that must stay open.
- **A redeploy of an older release** completes nothing, because the compare
  from the last deploy to an older tag has no commits.
- **A Shortcut error** skips only that story. The others are still moved, and
  the step fails at the end so the warning shows on the run and the next deploy
  retries. Stories that are
  already done, missing, or whose workflow has no `end-state` state are noted
  and skipped.
- **The run summary** lists the pull requests deployed and each story moved.

The action is a bash script (`complete-stories.sh`) that uses `gh`, `curl` and
`jq`, which GitHub-hosted runners have.

## Usage

Title the deploy runs so the next deploy can find this one, and run the action
after the deploy is verified:

```yaml
name: Deploy
run-name: "Deploy: ${{ github.event.release.tag_name || inputs.release_tag }}"

on:
  release:
    types: [released]
  workflow_dispatch:
    inputs:
      release_tag:
        required: true
        type: string

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      # Reads earlier deploy runs and the merged pull requests in the release.
      actions: read
      pull-requests: read
    steps:
      - run: ./deploy.sh

      # A story isn't done until it's in production, so this runs after the
      # deploy. A Shortcut problem shouldn't mark the deploy failed.
      - name: Complete Shortcut stories
        continue-on-error: true
        uses: ten-thousand-hammers/shortcut-complete-stories@v1
        with:
          release-tag: ${{ github.event.release.tag_name || inputs.release_tag }}
          shortcut-token: ${{ secrets.SHORTCUT_TOKEN }}
```

Pin a commit SHA instead of `@v1` when the job holds secrets you don't want an
upstream change to run with.

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `release-tag` | _(required)_ | Tag of the release that was just deployed. |
| `shortcut-token` | `""` | Shortcut API token. Not needed with `dry-run`. |
| `github-token` | `${{ github.token }}` | Reads deploy runs and their job logs, the compare and the pull requests. Needs `actions: read`, `contents: read` and `pull-requests: read`. |
| `workflow` | `deploy.yml` | Deploy workflow file whose successful runs give the previous release. |
| `base-branch` | `main` | Only pull requests merged into this branch count. |
| `end-state` | `Completed` | Workflow state the stories move to. |
| `workspace` | `apsure` | Shortcut workspace slug, for the story links in the summary. |
| `dry-run` | `"false"` | `"true"` lists the pull requests and stories and stops before Shortcut. |

## Try it locally

With `gh` signed in to an account that can read the repository:

```sh
DRY_RUN=1 GITHUB_REPOSITORY=owner/repo ./complete-stories.sh 2026.10.25+3
```

`WORKFLOW`, `BASE_BRANCH`, `END_STATE` and `SHORTCUT_WORKSPACE` match the
inputs. Without `DRY_RUN`, set `SHORTCUT_TOKEN`.

## Development

```sh
ruby test/complete_stories_test.rb
shellcheck --severity=warning complete-stories.sh
```

The tests stub `gh` and `curl` on `PATH`.
