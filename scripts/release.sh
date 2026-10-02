#!/bin/zsh
# Publishes a new Orbit version: bump, commit, tag, push, build from the tag, GitHub release.
# Installed copies of Orbit pick the release up through the built-in updater.
#
#   scripts/release.sh 0.5.0            # release
#   scripts/release.sh 0.5.0 --install  # …and install the build into /Applications
#
# Needs: a clean main branch in sync with origin, a "## [X.Y.Z]" section in CHANGELOG.md,
# xcodegen, Xcode and an authenticated gh.
set -euo pipefail

version=${1:?usage: scripts/release.sh X.Y.Z [--install]}
install=${2:-}
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.2.3"; exit 1; }

root=$(git rev-parse --show-toplevel)
cd "$root"
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
tag="v$version"
work="${TMPDIR:-/tmp}orbit-release-$version"   # outside iCloud: codesign rejects synced files

say() { print -P "%F{green}▸%f $1"; }

# --- Preconditions --------------------------------------------------------
[[ $(git branch --show-current) == main ]] || { echo "Switch to main first"; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Commit or stash your changes first"; exit 1; }
git fetch -q origin
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "main is not in sync with origin"; exit 1; }
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && { echo "Tag $tag already exists"; exit 1; }
grep -q "^## \[$version\]" CHANGELOG.md || { echo "CHANGELOG.md has no '## [$version]' section"; exit 1; }

# --- Version bump, commit, tag, push --------------------------------------
build=$(( $(sed -nE 's/.*CURRENT_PROJECT_VERSION: "([0-9]+)".*/\1/p' project.yml) + 1 ))
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]+\"/MARKETING_VERSION: \"$version\"/" project.yml
sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[^\"]+\"/CURRENT_PROJECT_VERSION: \"$build\"/" project.yml
sed -i '' -E "s/version-[0-9.]+-C8F169/version-$version-C8F169/" README.md
if ! grep -q "^\[$version\]:" CHANGELOG.md; then
  awk -v line="[$version]: https://github.com/$repo/releases/tag/$tag" \
    '!done && /^\[[0-9]+\.[0-9]+\.[0-9]+\]:/ { print line; done = 1 } { print }' CHANGELOG.md > CHANGELOG.md.tmp
  mv CHANGELOG.md.tmp CHANGELOG.md
fi
git add project.yml README.md CHANGELOG.md
git commit -q -m "Release $version"
git tag -a "$tag" -m "Orbit $version"
git push -q origin main "$tag"
say "Pushed $tag ($(git rev-parse --short HEAD))"

# --- Build from the tag ---------------------------------------------------
rm -rf "$work"
git worktree add -q --detach "$work/src" "$tag"
trap 'git worktree remove --force "$work/src" 2>/dev/null || true' EXIT
(
  cd "$work/src"
  xcodegen generate --quiet
  xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release \
    -derivedDataPath "$work/dd" -destination 'platform=macOS' build -quiet
)
app="$work/dd/Build/Products/Release/Orbit.app"
built=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
[[ $built == "$version" ]] || { echo "Built $built, expected $version"; exit 1; }
codesign --verify --deep "$app"
zip="$work/Orbit-$version-macOS.zip"
ditto -c -k --keepParent "$app" "$zip"
say "Built $(basename "$zip") ($(du -h "$zip" | cut -f1 | tr -d ' '))"

# --- GitHub release -------------------------------------------------------
notes="$work/notes.md"
awk -v v="$version" '$0 ~ "^## \\[" v "\\]" { on = 1; next } on && /^## \[/ { exit } on { print }' CHANGELOG.md > "$notes"
cat >> "$notes" <<EOF

## Установка

Если Orbit уже установлен — он предложит обновиться сам (или «Orbit → Проверить обновления…»).

Первая установка: скачайте \`Orbit-$version-macOS.zip\`, распакуйте и перенесите \`Orbit.app\` в «Программы». Приложение не нотарифицировано, поэтому первый запуск — через правый клик → «Открыть» или:
\`\`\`sh
xattr -dr com.apple.quarantine /Applications/Orbit.app
\`\`\`

Требуется macOS 15 или новее. Данные хранятся локально в \`~/.orbit\`.
EOF
title="Orbit $version"
gh release create "$tag" -R "$repo" --title "$title" --notes-file "$notes" --latest "$zip" >/dev/null
say "Released https://github.com/$repo/releases/tag/$tag"

# --- Optional local install -----------------------------------------------
if [[ $install == --install ]]; then
  osascript -e 'tell application id "dev.tolib.orbit" to quit' 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Orbit.app
  ditto "$app" /Applications/Orbit.app
  xattr -dr com.apple.quarantine /Applications/Orbit.app 2>/dev/null || true
  open /Applications/Orbit.app
  say "Installed into /Applications"
fi
