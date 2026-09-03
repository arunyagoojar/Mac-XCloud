#!/bin/bash
# Mac Xcloud — one-command release.
#
#   ./release.sh "What I changed"
#
# Stages everything, commits, pushes to main, and watches GitHub Actions
# build + publish the release. Installed apps update automatically.
set -euo pipefail
cd "$(dirname "$0")"

MESSAGE="${1:-Update}"
BRANCH=$(git rev-parse --abbrev-ref HEAD)

if [ "$BRANCH" != "main" ]; then
  echo "⚠️  On branch '$BRANCH' — releases are built from pushes to main."
  read -r -p "Switch to main and continue? [y/N] " answer
  if [ "${answer:-n}" != "y" ]; then exit 1; fi
  git checkout main
  git pull --ff-only
fi

git add -A
if git diff --cached --quiet; then
  echo "Nothing to commit — pushing any local commits."
else
  git commit -m "$MESSAGE"
fi
git push origin main

echo "⏳ Watching the release workflow…"
RUN_ID=$(gh run list --branch main --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --exit-status

TAG=$(gh release list --limit 1 --json tagName --jq '.[0].tagName')
echo
echo "✅ Released $TAG"
gh release view "$TAG" --web 2>/dev/null || gh release view "$TAG" --json url --jq .url
