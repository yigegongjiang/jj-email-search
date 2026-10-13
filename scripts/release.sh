#!/bin/bash
# 用法: release.sh [minor] [DEVELOPMENT_TEAM]  默认递增 PATCH
# 前提: 改动 + CHANGELOG.md / CHANGELOG.dev.md 顶部 `## [Unreleased]` 段已 commit 到当前分支, 工作区干净。
# 流程: 验证 -> rebase 到 master -> 按 master 版本号重算 -> 查 tag 未占用 -> 写版本 / changelog
#       -> 预部署 -> commit -> merge --ff-only -> annotated tag -> push (有 remote 时)。
# 任一步失败即停。MUST 以脚本执行: Bash 工具的 shell 是 zsh, 内联 `set -e` 无效, 管道会吞掉失败。
set -euo pipefail

main=master
bump="patch"
if [ "${1:-}" = minor ]; then
  bump=minor
  shift
fi
team="${1:-}"

fail() {
  echo "release: $*" >&2
  exit 1
}

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

branch="$(git branch --show-current)"
[ -n "$branch" ] || fail "detached HEAD"
[ -z "$(git status --porcelain)" ] || fail "工作区不干净, 先 commit 改动"
for file in CHANGELOG.md CHANGELOG.dev.md; do
  grep -q '^## \[Unreleased\]$' "$file" || fail "$file 缺少 '## [Unreleased]' 段"
done

swiftformat --lint Sources
swiftlint --strict

remote="$(git remote)"
if [ -n "$remote" ]; then
  git fetch origin "$main"
  git merge-base --is-ancestor "origin/$main" "$main" || fail "本地 $main 落后 origin/$main"
fi
# 多会话并行发布: master 随时会动, 版本号以 rebase 后的 master 为准。
[ "$branch" = "$main" ] || git rebase "$main"

read_setting() {
  git show "$main:version.xcconfig" | awk -F' *= *' -v key="$1" '$1 == key { print $2 }'
}
current="$(read_setting MARKETING_VERSION)"
build="$(read_setting CURRENT_PROJECT_VERSION)"
IFS=. read -r major minor patch <<<"$current"
case "$bump" in
  minor) version="$major.$((minor + 1)).0" ;;
  *) version="$major.$minor.$((patch + 1))" ;;
esac
tag="v$version"

git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "本地已存在 tag $tag"
if [ -n "$remote" ]; then
  if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null; then
    fail "origin 已存在 tag $tag"
  else
    # --exit-code: 2 = 未找到; 其他非 0 = 查询失败。
    [ $? -eq 2 ] || fail "查询 origin tag 失败"
  fi
fi

# commit 前失败: 还原版本文件, 重跑不被脏工作区阻塞。
committed=0
restore() {
  [ "$committed" = 1 ] || git checkout -- version.xcconfig CHANGELOG.md CHANGELOG.dev.md
}
trap restore EXIT

sed -i '' "s/^## \[Unreleased\]$/## [$version] - $(date +%F)/" CHANGELOG.md CHANGELOG.dev.md
sed -i '' -e "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $version/" \
  -e "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $((build + 1))/" version.xcconfig

./scripts/install-local.sh ${team:+"$team"}

git commit -m "chore(release): $tag" -- version.xcconfig CHANGELOG.md CHANGELOG.dev.md
committed=1

if [ "$branch" != "$main" ]; then
  main_dir="$(git worktree list --porcelain | awk -v ref="branch refs/heads/$main" \
    '/^worktree / { dir = substr($0, 10) } $0 == ref { print dir }')"
  [ -n "$main_dir" ] || fail "$main 未在任何 worktree 检出"
  git -C "$main_dir" merge --ff-only "$branch"
fi
git tag -a "$tag" -m "$tag" "$main"
if [ -n "$remote" ]; then
  git push --atomic origin "$main" "$tag"
fi
echo "已发布 $tag"
