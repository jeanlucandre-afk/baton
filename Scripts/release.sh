#!/bin/zsh
# Publishes a release on GitHub: tags v<version>, builds with Scripts/package.sh and uploads
#   Baton-<version>.dmg, Baton-<version>.zip and Baton.dmg (a stable name for the download link).
#   Scripts/release.sh            # asks before publishing
#   Scripts/release.sh --draft    # uploads as a draft you publish on github.com
# Built on this Mac, not in CI, so it's signed with the same certificate every time: macOS then keeps
# Baton's Accessibility permission across updates (an ad hoc CI build would lose it on every update).
set -euo pipefail
root="${0:A:h}/.."
cd "$root"
root=$PWD

draft=()
[[ ${1:-} == --draft ]] && draft=(--draft)

command -v gh >/dev/null || { echo "Needs the GitHub CLI: brew install gh" >&2; exit 1; }
[[ -z $(git status --porcelain --untracked-files=no) ]] || { echo "Commit your changes first." >&2; exit 1; }

version=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' App/project.yml)
tag="v$version"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || gh release view "$tag" >/dev/null 2>&1; then
  echo "$tag already exists. Bump CFBundleShortVersionString (and CFBundleVersion) in App/project.yml." >&2
  exit 1
fi

swift test --quiet
Scripts/package.sh
cp "dist/Baton-$version.dmg" dist/Baton.dmg

notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
{
  echo "## Install"
  echo "Download **Baton.dmg**, drag Baton to Applications and open it. Needs macOS 26."
  echo
  echo "This build isn't notarized by Apple, so the first open is blocked once:"
  echo "System Settings › Privacy & Security › **Open Anyway**. Full steps: [INSTALL.md](https://github.com/jeanlucandre-afk/baton/blob/main/docs/INSTALL.md)."
  echo
  echo "## Changes"
  last=$(git describe --tags --abbrev=0 2>/dev/null || true)
  git log --format='- %s' ${last:+$last..}HEAD
} > "$notes"

echo
cat "$notes"
echo
read "ok?Publish $tag to GitHub${draft:+ as a draft}? [y/N] "
[[ $ok == [yY] ]] || { echo "Stopped. Nothing was published."; exit 1; }

git tag -a "$tag" -m "Baton $version"
git push origin "$tag"
gh release create "$tag" "${draft[@]}" --title "Baton $version" --notes-file "$notes" \
  "dist/Baton-$version.dmg" "dist/Baton-$version.zip" dist/Baton.dmg
echo "Released: $(gh release view "$tag" --json url -q .url)"
