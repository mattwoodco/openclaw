---
name: github
description: >
  Interact with GitHub using the `gh` CLI — create repos, manage issues & PRs,
  publish GitHub Pages, run CI workflows, and query the API. Use when:
  (1) creating or managing repositories, (2) opening/reviewing pull requests,
  (3) publishing GitHub Pages sites, (4) checking CI/CD status,
  (5) managing issues and releases, (6) any GitHub API operation.
  The `gh` CLI is pre-authenticated via GH_TOKEN.
metadata:
  openclaw:
    category: "development"
    requires:
      bins: ["gh", "git"]
---

# GitHub Skill

Use the `gh` CLI to interact with GitHub. The CLI is pre-authenticated — no login needed.

## Repository Operations

```bash
# Create a new public repo
gh repo create owner/my-project --public --description "My project"

# Create a private repo and clone it
gh repo create owner/my-project --private --clone

# List your repos
gh repo list owner --limit 10

# Clone an existing repo
gh repo clone owner/repo

# View repo info
gh repo view owner/repo
```

## GitHub Pages

```bash
# Create a repo, add an index.html, and enable Pages — all in one flow:

# 1. Create repo
gh repo create owner/my-site --public --description "My site"

# 2. Clone and add content
gh repo clone owner/my-site && cd my-site
# (write your index.html, CSS, etc.)

# 3. Commit and push
git add -A && git commit -m "Initial site" && git push

# 4. Enable GitHub Pages on the main branch
gh api repos/owner/my-site/pages -X POST -f source.branch=main -f source.path=/

# 5. Check Pages deployment status
gh api repos/owner/my-site/pages --jq '.status, .html_url'
```

## File Operations (without cloning)

```bash
# Upload/create a file via the API
gh api repos/owner/repo/contents/index.html \
  -X PUT \
  -f message="Add index.html" \
  -f content="$(base64 < index.html)"

# Read a file
gh api repos/owner/repo/contents/README.md --jq '.content' | base64 -d

# Delete a file (requires sha)
gh api repos/owner/repo/contents/old-file.txt \
  -X DELETE \
  -f message="Remove old file" \
  -f sha="$(gh api repos/owner/repo/contents/old-file.txt --jq '.sha')"
```

## Pull Requests

```bash
# Create a PR
gh pr create --title "Add feature" --body "Description" --repo owner/repo

# List open PRs
gh pr list --repo owner/repo

# Check CI status on a PR
gh pr checks 55 --repo owner/repo

# Merge a PR
gh pr merge 55 --repo owner/repo --merge

# Review a PR
gh pr review 55 --repo owner/repo --approve
```

## Issues

```bash
# Create an issue
gh issue create --title "Bug report" --body "Details" --repo owner/repo

# List issues
gh issue list --repo owner/repo --json number,title --jq '.[] | "\(.number): \(.title)"'

# Close an issue
gh issue close 42 --repo owner/repo
```

## CI/CD Workflows

```bash
# List recent workflow runs
gh run list --repo owner/repo --limit 10

# View a run and its steps
gh run view <run-id> --repo owner/repo

# View logs for failed steps only
gh run view <run-id> --repo owner/repo --log-failed

# Trigger a workflow manually
gh workflow run deploy.yml --repo owner/repo
```

## Releases

```bash
# Create a release
gh release create v1.0.0 --repo owner/repo --title "v1.0.0" --notes "Release notes"

# Upload assets to a release
gh release upload v1.0.0 ./dist/app.zip --repo owner/repo

# List releases
gh release list --repo owner/repo
```

## API for Advanced Queries

```bash
# Get PR with specific fields
gh api repos/owner/repo/pulls/55 --jq '.title, .state, .user.login'

# Search repos
gh api search/repositories -f q="topic:ai language:python" --jq '.items[].full_name'

# List org members
gh api orgs/my-org/members --jq '.[].login'
```

## Tips

- Always use `--repo owner/repo` when not inside a cloned git directory.
- Use `--json` and `--jq` for structured output in pipelines.
- For GitHub Pages, use `gh api` to enable Pages after pushing content.
- Git operations (`git init`, `git commit`, `git push`) work alongside `gh`.
- The GitHub account is `mattwoodco-agent` (configured via GH_TOKEN).
