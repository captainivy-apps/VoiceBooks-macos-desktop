#!/usr/bin/env bash
#
# tts-model-mirror.sh — 下载全部内置 TTS 模型并同步到自建镜像服务器
#
# 管理员指定 rsync 服务器地址、SSH 用户名和远程目录后，脚本会读取
# VoiceBooks/TTS/BuiltInTtsModels.swift 中登记的全部模型（含声码器等附属
# 文件），先下载到本地缓存，再通过 rsync 上传到远程目录。模型清单直接来自
# 应用内置目录，新增模型后无需改动本脚本。
#
# 前置条件：
#   请提前配置 SSH 公钥免密登录，否则脚本无法运行：
#       ssh-copy-id <user>@<host>
#   依赖：curl、rsync、ssh、python3
#
# 用法：
#   scripts/tts-model-mirror.sh -H es.galaxyrover.com -u root \
#       -d /root/src.galaxyrover.com/statics/mirrors
#
# 选项：
#   -H, --host <host>     rsync/ssh 服务器地址（必填）
#   -u, --user <user>     SSH 用户名（必填）
#   -d, --dir  <path>     远程目录（必填）
#   -c, --cache <path>    本地缓存目录（默认 <repo>/build/tts-mirror-cache）
#   -f, --filter <regex>  仅处理文件名匹配该正则的模型
#       --list            仅列出将要处理的文件，不下载也不上传
#       --download-only   仅下载到本地缓存
#       --upload-only     仅上传本地缓存（不下载）
#       --force           缓存中已存在的文件也重新下载
#       --dry-run         仅演示 rsync，不实际传输
#   -h, --help            显示帮助
#
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CATALOG="$REPO_ROOT/VoiceBooks/TTS/BuiltInTtsModels.swift"

HOST=""
USER_NAME=""
REMOTE_DIR=""
CACHE_DIR="$REPO_ROOT/build/tts-mirror-cache"
FILTER=""
DO_DOWNLOAD=1
DO_UPLOAD=1
LIST_ONLY=0
DRY_RUN=0
FORCE=0

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--host)     HOST="${2:-}"; shift 2 ;;
        -u|--user)     USER_NAME="${2:-}"; shift 2 ;;
        -d|--dir)      REMOTE_DIR="${2:-}"; shift 2 ;;
        -c|--cache)    CACHE_DIR="${2:-}"; shift 2 ;;
        -f|--filter)   FILTER="${2:-}"; shift 2 ;;
        --list)        LIST_ONLY=1; shift ;;
        --download-only) DO_UPLOAD=0; shift ;;
        --upload-only) DO_DOWNLOAD=0; shift ;;
        --force)       FORCE=1; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; echo; usage; exit 2 ;;
    esac
done

# --- 模型清单解析 -------------------------------------------------------------
# 从 Swift 目录中提取：每个 entry("id") 对应 "<id>.tar.bz2"，以及每个
# TtsAuxiliaryFile(url:relativePath:) 对应的附属文件。URL 中的 \(常量) 会被
# 替换为文件中对应 static let 的值（如 \(vocoderBaseUrl)）。
parse_manifest() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "错误：需要 python3 来解析模型清单 $CATALOG" >&2
        return 1
    fi
    if [[ ! -f "$CATALOG" ]]; then
        echo "错误：找不到模型目录文件 $CATALOG" >&2
        return 1
    fi
    python3 - "$CATALOG" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()

def const(name):
    m = re.search(r'static\s+let\s+' + re.escape(name) + r'\s*=\s*"([^"]*)"', src)
    return m.group(1) if m else ""

consts = {name: const(name) for name in re.findall(r'static\s+let\s+(\w+)\s*=\s*"', src)}

def interp(s):
    def repl(m):
        return consts.get(m.group(1), "")
    return re.sub(r'\\\((\w+)\)', repl, s)

seen = set()

def emit(name, url):
    if not name or not url or name in seen:
        return
    seen.add(name)
    sys.stdout.write("%s\t%s\n" % (name, url))

base = consts.get("baseUrl", "")

for m in re.finditer(r'entry\(\s*"([^"]+)"', src):
    mid = m.group(1)
    emit("%s.tar.bz2" % mid, "%s/%s.tar.bz2" % (base, mid))

for m in re.finditer(
    r'TtsAuxiliaryFile\(\s*url:\s*"([^"]+)"\s*,\s*relativePath:\s*"([^"]+)"',
    src, re.S,
):
    url = interp(m.group(1))
    name = m.group(2).rsplit("/", 1)[-1]
    emit(name, url)
PY
}

echo "==> 读取模型清单: $CATALOG"
ENTRIES=()
while IFS=$'\t' read -r name url; do
    [[ -z "$name" ]] && continue
    ENTRIES+=("$name"$'\t'"$url")
done < <(parse_manifest)

if [[ ${#ENTRIES[@]} -eq 0 ]]; then
    echo "错误：模型清单为空（解析失败？）" >&2
    exit 1
fi

SELECTED=()
for entry in "${ENTRIES[@]}"; do
    name="${entry%%$'\t'*}"
    if [[ -n "$FILTER" ]] && ! printf '%s' "$name" | grep -Eq "$FILTER"; then
        continue
    fi
    SELECTED+=("$entry")
done

echo "    共 ${#ENTRIES[@]} 个文件，选中 ${#SELECTED[@]} 个"

if [[ $LIST_ONLY -eq 1 ]]; then
    printf '%s\n' "文件名                                  下载地址"
    for entry in "${SELECTED[@]}"; do
        name="${entry%%$'\t'*}"
        url="${entry#*$'\t'}"
        printf '  %-38s %s\n' "$name" "$url"
    done
    exit 0
fi

# --- 参数校验 -----------------------------------------------------------------
if [[ $DO_UPLOAD -eq 1 && ( -z "$HOST" || -z "$USER_NAME" || -z "$REMOTE_DIR" ) ]]; then
    echo "错误：上传时必须指定 --host、--user 和 --dir" >&2
    echo
    usage
    exit 2
fi

SSH_TARGET="$USER_NAME@$HOST"
RSYNC_TARGET="$SSH_TARGET:$REMOTE_DIR"

# --- 下载 ---------------------------------------------------------------------
download_one() {
    local name="$1" url="$2" dest="$CACHE_DIR/$name"
    if [[ -s "$dest" && $FORCE -eq 0 ]]; then
        echo "  [跳过] ${name}（已存在，用 --force 重新下载）"
        return 0
    fi
    echo "  [下载] $name"
    if ! curl -fL --retry 3 --retry-delay 3 -C - -o "$dest.part" "$url"; then
        echo "  失败: $name <- $url" >&2
        return 1
    fi
    mv -f "$dest.part" "$dest"
}

if [[ $DO_DOWNLOAD -eq 1 ]]; then
    mkdir -p "$CACHE_DIR"
    echo "==> 下载模型到缓存: $CACHE_DIR"
    failed=0
    for entry in "${SELECTED[@]}"; do
        name="${entry%%$'\t'*}"
        url="${entry#*$'\t'}"
        download_one "$name" "$url" || failed=$((failed + 1))
    done
    if [[ $failed -ne 0 ]]; then
        echo "错误：有 $failed 个文件下载失败。" >&2
        exit 1
    fi
else
    echo "==> 跳过下载（--upload-only）"
fi

if [[ $DO_UPLOAD -eq 0 ]]; then
    echo "==> 跳过上传（--download-only）"
    echo "完成。缓存目录: $CACHE_DIR"
    exit 0
fi

# --- SSH 预检 -----------------------------------------------------------------
echo "提示：请提前配置 SSH 公钥免密登录，否则无法上传。"
echo "      如未配置：ssh-copy-id $SSH_TARGET"
echo "==> 检查 SSH 免密登录: $SSH_TARGET"
if ! ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
        "$SSH_TARGET" "mkdir -p '$REMOTE_DIR' && test -d '$REMOTE_DIR'"; then
    cat >&2 <<EOF

无法通过 SSH 免密登录访问 ${SSH_TARGET}，或远程目录不可写:
    $REMOTE_DIR

请先配置公钥免密登录：
    ssh-copy-id $SSH_TARGET

然后确认远程目录存在/可写：
    ssh $SSH_TARGET "mkdir -p '$REMOTE_DIR'"
EOF
    exit 1
fi

# --- 上传 ---------------------------------------------------------------------
RSYNC_OPTS=(-a -z --partial --human-readable)
if [[ $DRY_RUN -eq 1 ]]; then
    RSYNC_OPTS+=(--dry-run)
fi

echo "==> rsync 上传: $CACHE_DIR/ -> $RSYNC_TARGET/"
rsync "${RSYNC_OPTS[@]}" "$CACHE_DIR/" "$RSYNC_TARGET/"

echo
if [[ $DRY_RUN -eq 1 ]]; then
    echo "完成（dry-run，未实际传输）。"
else
    echo "完成。已同步到 $RSYNC_TARGET/"
fi
