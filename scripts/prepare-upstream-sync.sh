#!/bin/bash
set -euo pipefail
[[ "${GITHUB_REPOSITORY:-}" == 'shaoyou11/Aidoku' ]] || { echo '仅在个人 AidokuT 仓库运行'; exit 1; }
mkdir -p build
python3 scripts/check_customizations.py snapshot build/customization-baseline.json
git fetch https://github.com/Aidoku/Aidoku.git refs/heads/main:refs/remotes/upstream/main
if git merge-base --is-ancestor refs/remotes/upstream/main HEAD; then
    echo 'changed=false' >> "$GITHUB_OUTPUT"
    echo '上游没有新增提交，跳过编译。'
    exit 0
fi
git config user.name shaoyou11
git config user.email shaoyou11@users.noreply.github.com
upstream_sha=$(git rev-parse refs/remotes/upstream/main)
if ! git merge --no-ff --no-commit refs/remotes/upstream/main; then
    git diff --name-only --diff-filter=U > build/merge-conflicts.txt
    echo '::error::上游与定制存在冲突，未推送、未发布；保留当前内部测试版本。'
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        printf '上游合并发生冲突，已停止自动发布。冲突文件：\n' >> "$GITHUB_STEP_SUMMARY"
        cat build/merge-conflicts.txt >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 1
fi
python3 scripts/check_customizations.py compare build/customization-baseline.json
python3 scripts/check_customizations.py
git diff --check
git commit -m '实现：自动合并上游更新并保留 AidokuT 定制' -m "上游提交：${upstream_sha}。NAS、iCloud、隐私、图标与关键界面保护检查通过；后续由 Xcode Cloud 编译和回归，成功后推送家庭内部 TestFlight。"
source_sha=$(git rev-parse HEAD)
printf 'changed=true\ncommit=%s\n' "$source_sha" >> "$GITHUB_OUTPUT"
