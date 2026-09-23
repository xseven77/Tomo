#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Tomo"
BINARY_NAME="Tomo"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${ROOT_DIR}/../.." && pwd)"
PLIST_PATH="${ROOT_DIR}/Resources/Info.plist"
DIST_DIR="${ROOT_DIR}/dist"
CURRENT_BRANCH="$(git -C "${REPO_ROOT}" branch --show-current)"
ORIGINAL_VERSION=""
ORIGINAL_BUILD=""
ROLLBACK_VERSION_ON_FAILURE="false"
PUBLISH_ONLY="false"
PUBLISH_RETRIES="${PUBLISH_RETRIES:-3}"

cd "${ROOT_DIR}"

info() {
  printf "\033[1;34m==>\033[0m %s\n" "$*"
}

warn() {
  printf "\033[1;33m!!\033[0m %s\n" "$*"
}

fail() {
  printf "\033[1;31merror:\033[0m %s\n" "$*" >&2
  exit 1
}

restore_version_on_failure() {
  local exit_status="$?"
  trap - EXIT

  if [[ "${exit_status}" -ne 0 && "${ROLLBACK_VERSION_ON_FAILURE}" == "true" ]]; then
    warn "发布在提交版本号之前失败，恢复版本 ${ORIGINAL_VERSION} (${ORIGINAL_BUILD})"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${ORIGINAL_VERSION}" "${PLIST_PATH}" || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${ORIGINAL_BUILD}" "${PLIST_PATH}" || true
  fi

  exit "${exit_status}"
}

trap restore_version_on_failure EXIT

confirm() {
  local prompt="$1"
  local answer
  read -r -p "${prompt} [y/N] " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]]
}

require_command() {
  local command_name="$1"
  local install_hint="$2"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    fail "缺少命令：${command_name}。${install_hint}"
  fi
}

ensure_github_auth() {
  require_command gh "请先安装 GitHub CLI：brew install gh"

  info "检查 GitHub CLI 登录状态"
  if gh auth status >/dev/null 2>&1; then
    gh auth status
    return
  fi

  warn "GitHub CLI 尚未登录，将启动交互式网页登录授权"
  gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web

  if ! gh auth status >/dev/null 2>&1; then
    fail "GitHub CLI 登录失败，请重新运行脚本并完成授权。"
  fi
}

require_clean_worktree() {
  local status
  status="$(git -C "${REPO_ROOT}" status --porcelain)"

  if [[ -n "${status}" ]]; then
    warn "检测到工作区存在未提交变动："
    printf "%s\n" "${status}"
    if ! confirm "是否继续并在此状态下进行构建与发布？"; then
      fail "已取消发布。请先提交、stash 或清理改动后再发布。"
    fi
  fi
}

require_branch() {
  if [[ -z "${CURRENT_BRANCH}" ]]; then
    fail "当前处于 detached HEAD，无法自动推送分支。请切回发布分支后再运行。"
  fi
}

validate_version() {
  local version="$1"
  [[ "${version}" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]
}

validate_build_number() {
  local build_number="$1"
  [[ "${build_number}" =~ ^[0-9]+$ ]]
}

bump_version() {
  local version="$1"
  local bump_type="$2"
  local major minor patch

  IFS='.' read -r major minor patch <<< "${version}"
  patch="${patch:-0}"

  case "${bump_type}" in
    patch)
      patch="$((patch + 1))"
      ;;
    minor)
      minor="$((minor + 1))"
      patch="0"
      ;;
    major)
      major="$((major + 1))"
      minor="0"
      patch="0"
      ;;
    *)
      fail "未知版本更新类型：${bump_type}"
      ;;
  esac

  printf "%s.%s.%s" "${major}" "${minor}" "${patch}"
}

read_release_inputs() {
  local current_version current_build default_build version_choice
  current_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST_PATH}")"
  current_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST_PATH}")"
  ORIGINAL_VERSION="${current_version}"
  ORIGINAL_BUILD="${current_build}"

  if [[ "${current_build}" =~ ^[0-9]+$ ]]; then
    default_build="$((current_build + 1))"
  else
    default_build="1"
  fi

  printf "\n当前版本：%s (%s)\n" "${current_version}" "${current_build}"
  printf "请选择版本更新方式：\n"
  printf "  1) 修复更新：%s -> %s\n" "${current_version}" "$(bump_version "${current_version}" patch)"
  printf "  2) 小版本更新：%s -> %s\n" "${current_version}" "$(bump_version "${current_version}" minor)"
  printf "  3) 大版本更新：%s -> %s\n" "${current_version}" "$(bump_version "${current_version}" major)"
  printf "  4) 手动输入版本号\n"
  printf "  5) 保持当前版本 (重新打包/覆盖远端 Release)：%s\n" "${current_version}"

  read -r -p "请输入选项 [1-5]（默认 1）： " version_choice
  version_choice="${version_choice:-1}"

  case "${version_choice}" in
    1)
      RELEASE_VERSION="$(bump_version "${current_version}" patch)"
      ;;
    2)
      RELEASE_VERSION="$(bump_version "${current_version}" minor)"
      ;;
    3)
      RELEASE_VERSION="$(bump_version "${current_version}" major)"
      ;;
    4)
      while :; do
        read -r -p "请输入本次发布版本号，例如 0.1.1： " RELEASE_VERSION
        if validate_version "${RELEASE_VERSION}"; then
          break
        fi
        warn "版本号格式不正确：${RELEASE_VERSION}。请使用类似 0.1.1 或 1.0.0 的格式。"
      done
      ;;
    5)
      RELEASE_VERSION="${current_version}"
      default_build="${current_build}"
      ;;
    *)
      fail "无效选项：${version_choice}"
      ;;
  esac

  if ! validate_version "${RELEASE_VERSION}"; then
    fail "版本号格式不正确：${RELEASE_VERSION}。请使用类似 0.1.1 或 1.0.0 的格式。"
  fi

  info "本次发布版本：${RELEASE_VERSION}"

  read -r -p "请输入 build number（留空使用 ${default_build}）： " RELEASE_BUILD
  RELEASE_BUILD="${RELEASE_BUILD:-${default_build}}"

  if ! validate_build_number "${RELEASE_BUILD}"; then
    fail "build number 必须是整数：${RELEASE_BUILD}"
  fi

  RELEASE_TAG="v${RELEASE_VERSION}"
  ZIP_PATH="${DIST_DIR}/${APP_NAME}-${RELEASE_VERSION}.zip"
  DMG_PATH="${DIST_DIR}/${APP_NAME}-${RELEASE_VERSION}.dmg"
}

update_plist_version() {
  info "写入版本号 ${RELEASE_VERSION} (${RELEASE_BUILD})"
  ROLLBACK_VERSION_ON_FAILURE="true"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${RELEASE_VERSION}" "${PLIST_PATH}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${RELEASE_BUILD}" "${PLIST_PATH}"
}

build_release_artifacts() {
  info "开始打包。发布前会重新生成 .app、.zip 和 .dmg"
  TOMO_REQUIRE_GEMINI_OAUTH_CONFIG=1 "${ROOT_DIR}/package_app.sh"

  [[ -f "${DMG_PATH}" ]] || fail "DMG 未生成：${DMG_PATH}"
  [[ -f "${ZIP_PATH}" ]] || fail "ZIP 未生成：${ZIP_PATH}"
}

verify_packaged_gemini_oauth_config() {
  local app_bundle="$1"
  local config_path="${app_bundle}/Contents/Resources/GeminiOAuthConfig.plist"
  local client_id

  if [[ ! -f "${config_path}" ]]; then
    echo "发布包缺少 GeminiOAuthConfig.plist。" >&2
    return 1
  fi
  if ! plutil -lint "${config_path}" >/dev/null; then
    echo "发布包中的 Gemini OAuth 配置格式无效。" >&2
    return 1
  fi
  client_id="$(plutil -extract clientID raw -o - "${config_path}" 2>/dev/null || true)"
  if [[ -z "${client_id}" ]]; then
    echo "发布包必须包含 OAuth Client ID。" >&2
    return 1
  fi
}

release_dmg_image_if_busy() {
  hdiutil detach "${DMG_PATH}" >/dev/null 2>&1 || true
}

verify_dmg() {
  local mount_output mount_point attempt

  info "挂载验证 DMG 内容"
  release_dmg_image_if_busy

  mount_output=""
  for attempt in 1 2 3 4 5 6; do
    if mount_output="$(hdiutil attach "${DMG_PATH}" -nobrowse -readonly 2>&1)"; then
      break
    fi
    if [[ "${attempt}" -eq 6 ]]; then
      printf "%s\n" "${mount_output}"
      fail "无法挂载 DMG：${DMG_PATH}。若仍失败，可先执行：hdiutil detach \"${DMG_PATH}\""
    fi
    release_dmg_image_if_busy
    sleep 1
  done

  mount_point="$(printf "%s\n" "${mount_output}" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"

  if [[ -z "${mount_point}" || ! -d "${mount_point}" ]]; then
    printf "%s\n" "${mount_output}"
    fail "无法识别 DMG 挂载点。"
  fi

  if [[ ! -d "${mount_point}/${APP_NAME}.app" ]]; then
    hdiutil detach "${mount_point}" >/dev/null || true
    fail "DMG 中缺少 ${APP_NAME}.app"
  fi

  if [[ ! -L "${mount_point}/Applications" ]]; then
    hdiutil detach "${mount_point}" >/dev/null || true
    fail "DMG 中缺少 Applications 快捷方式"
  fi

  if ! verify_packaged_gemini_oauth_config "${mount_point}/${APP_NAME}.app"; then
    hdiutil detach "${mount_point}" >/dev/null || true
    fail "拒绝发布无法登录 Gemini 的版本。"
  fi

  hdiutil detach "${mount_point}" >/dev/null
  info "DMG 验证通过"
}

commit_version_if_needed() {
  if git -C "${REPO_ROOT}" diff --quiet -- app/Tomo/Resources/Info.plist; then
    info "版本文件没有变化，无需提交版本号"
    return
  fi

  info "提交版本号变更"
  git -C "${REPO_ROOT}" add app/Tomo/Resources/Info.plist
  git -C "${REPO_ROOT}" commit -m "Release ${RELEASE_VERSION}"
}

push_branch_and_tag() {
  info "推送 ${CURRENT_BRANCH}"
  git -C "${REPO_ROOT}" push origin "${CURRENT_BRANCH}"
  git -C "${REPO_ROOT}" fetch --tags origin

  if git -C "${REPO_ROOT}" rev-parse "${RELEASE_TAG}" >/dev/null 2>&1; then
    local tag_commit head_commit
    tag_commit="$(git -C "${REPO_ROOT}" rev-list -n 1 "${RELEASE_TAG}")"
    head_commit="$(git -C "${REPO_ROOT}" rev-parse HEAD)"

    if [[ "${tag_commit}" != "${head_commit}" ]]; then
      fail "本地 tag ${RELEASE_TAG} 已存在，但不指向当前 HEAD。请手动检查后再发布。"
    fi

    warn "本地 tag ${RELEASE_TAG} 已存在，跳过创建。"
  else
    info "创建 tag ${RELEASE_TAG}"
    git -C "${REPO_ROOT}" tag -a "${RELEASE_TAG}" -m "${APP_NAME} ${RELEASE_VERSION}"
  fi

  info "推送 tag ${RELEASE_TAG}"
  git -C "${REPO_ROOT}" push origin "${RELEASE_TAG}"
}

release_notes_file() {
  local notes_path="${DIST_DIR}/release-notes-${RELEASE_VERSION}.md"
  local base_tag commits_list

  base_tag="${BASE_TAG_FOR_NOTES:-}"
  commits_list="${DETECTED_RECENT_COMMITS:-}"

  # 如果没有在 confirm_release_plan 中初始化过（例如 --publish-only 场景），则动态计算一次
  if [[ -z "${base_tag}" && -z "${commits_list}" ]]; then
    base_tag="$(git -C "${REPO_ROOT}" describe --tags --abbrev=0 2>/dev/null || true)"
    if [[ -n "${base_tag}" ]]; then
      commits_list="$(git -C "${REPO_ROOT}" log "${base_tag}..HEAD" --pretty=format:"- %s" 2>/dev/null | grep -v "^- Release " || true)"
    fi
  fi

  {
    echo "## ${APP_NAME} ${RELEASE_VERSION}"
    echo ""
    if [[ -n "${CUSTOM_RELEASE_NOTES:-}" ]]; then
      echo "### 更新要点"
      echo ""
      echo "${CUSTOM_RELEASE_NOTES}"
      echo ""
    fi
    if [[ -n "${commits_list}" ]]; then
      local section_title="### 更新记录"
      if [[ -n "${base_tag}" ]]; then
        section_title="### 更新记录（自 ${base_tag} 以来）"
      fi
      echo "${section_title}"
      echo ""
      echo "${commits_list}"
      echo ""
    fi
    echo "### 下载"
    echo ""
    echo "- \`${APP_NAME}-${RELEASE_VERSION}.dmg\`：推荐安装包"
    echo "- \`${APP_NAME}-${RELEASE_VERSION}.zip\`：备用压缩包"
    echo ""
    echo "> 当前构建使用 ad-hoc 签名，未做 Apple notarization。"
  } > "${notes_path}"

  printf "%s" "${notes_path}"
}

# 尝试上传资产，带重试；一次性提交 DMG+ZIP。返回 0 表示全部到位。
upload_assets_with_retry() {
  local release_tag="$1" repo="$2" attempt=0

  while :; do
    attempt=$((attempt + 1))
    if gh release upload "${release_tag}" "${DMG_PATH}" "${ZIP_PATH}" \
        --repo "${repo}" --clobber >/dev/null 2>&1; then
      info "资产上传成功"
      return 0
    fi

    if [[ "${attempt}" -ge "${PUBLISH_RETRIES}" ]]; then
      return 1
    fi
    warn "资产上传失败（第 ${attempt}/${PUBLISH_RETRIES} 次），重试中…"
    sleep 2
  done
}

publish_github_release() {
  local repo notes_path release_exists
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
  notes_path="$(release_notes_file)"

  info "发布到 GitHub Release：${repo} ${RELEASE_TAG}"
  if gh release view "${RELEASE_TAG}" --repo "${repo}" >/dev/null 2>&1; then
    release_exists="yes"
  else
    release_exists="no"
  fi

  if [[ "${release_exists}" == "yes" ]]; then
    warn "Release ${RELEASE_TAG} 已存在"
    if ! confirm "是否覆盖上传 DMG/ZIP，并更新 release notes？"; then
      fail "已取消发布。"
    fi

    gh release edit "${RELEASE_TAG}" \
      --repo "${repo}" \
      --title "${APP_NAME} ${RELEASE_VERSION}" \
      --notes-file "${notes_path}" || fail "更新 Release 信息失败。"

    if ! upload_assets_with_retry "${RELEASE_TAG}" "${repo}"; then
      fail "上传资产 ${RELEASE_TAG} 失败（已重试 ${PUBLISH_RETRIES} 次）。"
    fi
  else
    # 新建 Release 并直接带资产；create 不支持 --clobber（仅 upload 支持），
    # 新 release 本就不存在历史同名资产，无需覆盖。
    local attempt=0
    while :; do
      attempt=$((attempt + 1))
      if gh release create "${RELEASE_TAG}" "${DMG_PATH}" "${ZIP_PATH}" \
          --repo "${repo}" \
          --title "${APP_NAME} ${RELEASE_VERSION}" \
          --notes-file "${notes_path}"; then
        break
      fi
      if [[ "${attempt}" -ge "${PUBLISH_RETRIES}" ]]; then
        fail "创建/上传 Release ${RELEASE_TAG} 失败（已重试 ${PUBLISH_RETRIES} 次）。"
      fi
      warn "创建 Release 失败（第 ${attempt}/${PUBLISH_RETRIES} 次），重试中…"
      sleep 2
    done
  fi

  gh release view "${RELEASE_TAG}" --repo "${repo}" --web
}

usage() {
  cat <<EOF
用法：$(basename "$0") [选项]

发布 ${APP_NAME} 到 GitHub Release。

选项：
  --publish-only, -p   只发布当前已构建的产物到 GitHub Release，跳过打包/验证/提交/推送。
                       版本号取当前 Info.plist，直接上传 dist/ 下的 .zip 与 .dmg。
  --help, -h           显示本帮助。

环境变量：
  PUBLISH_RETRIES      上传失败时的重试次数（默认 3）。
  TOMO_GEMINI_OAUTH_CONFIG_PLIST
                       Tomo Gemini OAuth plist 的绝对路径。
  TOMO_GEMINI_OAUTH_CLIENT_ID
                       Tomo 自有 Google Desktop OAuth Client ID。
  TOMO_GEMINI_OAUTH_LEGACY_CLIENT_SECRET
                       仅兼容旧 OAuth Client；自有 Desktop Client 不应设置。

默认（不带参数）执行完整发布流程：
  授权 -> 版本号 -> 打包 -> DMG 验证 -> 提交版本号 -> 推送分支/tag -> 发布 Release。
EOF
}

parse_args() {
  [[ "$#" -eq 0 ]] && return 0
  for arg in "$@"; do
    case "$arg" in
      --publish-only|-p)
        PUBLISH_ONLY="true"
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        fail "未知参数：${arg}（可用 --publish-only / --help）"
        ;;
    esac
  done
}

# 只发布当前已构建的产物到 GitHub Release。
# 不重新打包、不验证 DMG、不提交、不推送分支/tag。
publish_only() {
  local current_version current_build
  current_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST_PATH}")"
  current_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST_PATH}")"

  RELEASE_VERSION="${current_version}"
  RELEASE_BUILD="${current_build}"
  RELEASE_TAG="v${current_version}"
  ZIP_PATH="${DIST_DIR}/${APP_NAME}-${current_version}.zip"
  DMG_PATH="${DIST_DIR}/${APP_NAME}-${current_version}.dmg"

  info "发布模式：仅上传当前已构建产物（版本 ${RELEASE_VERSION}，build ${RELEASE_BUILD}）"

  [[ -f "${DMG_PATH}" ]] || fail "未找到 DMG：${DMG_PATH}。请先运行 package_app.sh 或完整发布流程生成产物。"
  [[ -s "${DMG_PATH}" ]] || fail "DMG 为空文件：${DMG_PATH}"
  [[ -f "${ZIP_PATH}" ]] || fail "未找到 ZIP：${ZIP_PATH}。请先运行 package_app.sh 或完整发布流程生成产物。"
  [[ -s "${ZIP_PATH}" ]] || fail "ZIP 为空文件：${ZIP_PATH}"

  verify_dmg
  publish_github_release

  info "发布完成：${RELEASE_TAG}"
}

CUSTOM_RELEASE_NOTES=""
DETECTED_RECENT_COMMITS=""
BASE_TAG_FOR_NOTES=""

confirm_release_plan() {
  local latest_tag recent_commits
  latest_tag="$(git -C "${REPO_ROOT}" describe --tags --abbrev=0 2>/dev/null || true)"
  recent_commits=""
  if [[ -n "${latest_tag}" ]]; then
    recent_commits="$(git -C "${REPO_ROOT}" log "${latest_tag}..HEAD" --pretty=format:"- %s" 2>/dev/null | grep -v "^- Release " || true)"
  fi

  BASE_TAG_FOR_NOTES="${latest_tag}"
  DETECTED_RECENT_COMMITS="${recent_commits}"

  printf "\n========================================================\n"
  printf "  准备发布：%s %s (build %s, Tag: %s)\n" "${APP_NAME}" "${RELEASE_VERSION}" "${RELEASE_BUILD}" "${RELEASE_TAG}"
  printf "  目标分支：%s\n" "${CURRENT_BRANCH}"
  printf "========================================================\n"

  if [[ -n "${recent_commits}" ]]; then
    printf "\n自 %s 以来检测到的 Git 提交记录：\n%s\n\n" "${latest_tag}" "${recent_commits}"
  fi

  printf "是否输入自定义更新摘要？(留空直接回车使用自动提取的 Git 提交记录)\n"
  read -r -p "> " CUSTOM_RELEASE_NOTES

  if ! confirm "确认开始编译、打包并发布到 GitHub Release？"; then
    fail "已取消发布。"
  fi
}

check_web_plugin_status() {
  info "检查移动端伴生 Web 插件状态..."
  local plugin_dir="${HOME}/Library/Application Support/Tomo/Plugins/mobile-web"
  local manifest_file="${plugin_dir}/plugin-manifest.json"
  local index_file="${plugin_dir}/index.html"
  local mobile_repo_dir="${REPO_ROOT}/../TomoGo"

  if [[ -f "${index_file}" ]]; then
    local version="未知"
    if [[ -f "${manifest_file}" ]]; then
      version="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "${manifest_file}" | cut -d'"' -f4 || echo "未知")"
    fi
    info "本地已安装 Web 伴生插件：v${version} (${plugin_dir})"
  else
    warn "本地尚未安装 Web 伴生插件 (mobile-web)。"
    printf "  提示：若希望在桌面端发布时同步准备 Web 伴生插件，可前往 %s 执行 ./scripts/publish_release.sh\n" "${mobile_repo_dir}"
  fi
}

main() {
  parse_args "$@"

  require_command swift "请先安装 Xcode Command Line Tools。"
  require_command hdiutil "hdiutil 是 macOS 自带命令，请在 macOS 上运行。"
  require_command codesign "codesign 是 macOS 自带命令，请在 macOS 上运行。"
  require_command gh "请先安装 GitHub CLI：brew install gh"

  ensure_github_auth
  check_web_plugin_status

  if [[ "${PUBLISH_ONLY}" == "true" ]]; then
    publish_only
    return 0
  fi

  require_branch
  require_clean_worktree
  read_release_inputs
  confirm_release_plan
  update_plist_version
  build_release_artifacts
  verify_dmg
  commit_version_if_needed
  ROLLBACK_VERSION_ON_FAILURE="false"
  push_branch_and_tag
  publish_github_release

  info "发布完成：${RELEASE_TAG}"
}

main "$@"
