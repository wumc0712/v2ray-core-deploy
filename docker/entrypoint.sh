#!/bin/sh
# v2ray-core-deploy 容器入口。
#
# 职责：把 config/config.json.template 与容器环境变量合成为运行时配置，启动 v2ray。
# 只依赖 /bin/sh，不引入外部解释器。
set -eu

V2RAY_BIN="${V2RAY_BIN:-/usr/local/bin/v2ray}"
TEMPLATE="${V2RAY_TEMPLATE:-/usr/local/share/v2ray/config.json.template}"
CONFIG="${V2RAY_CONFIG:-/run/v2ray/config.json}"
ASSET_DIR="${V2RAY_LOCATION_ASSET:-/usr/local/share/v2ray}"
UUID_FILE="${V2RAY_UUID_FILE:-/etc/v2ray/uuid}"

log() { printf '%s [entrypoint] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "错误：$*"; exit 1; }

# 配置模板用 %%NAME%% 作为占位符，值里出现 % 会造成占位符错配。
no_percent() {
    case "$2" in
        *%*) die "$1 不能包含百分号：$2" ;;
    esac
}

# 由 32 个十六进制字符按 RFC 4122 v4 规则组装 UUID。
# 第 7 字节高半字节固定为 4（版本），第 9 字节高半字节固定为 a（variant）。
make_uuid_from_hex() {
    hex="$1"
    [ ${#hex} -eq 32 ] || return 1
    printf '%s-%s-4%s-a%s-%s\n' \
        "$(printf '%s' "$hex" | cut -c1-8)" \
        "$(printf '%s' "$hex" | cut -c9-12)" \
        "$(printf '%s' "$hex" | cut -c14-16)" \
        "$(printf '%s' "$hex" | cut -c18-20)" \
        "$(printf '%s' "$hex" | cut -c21-32)"
}

# ---------------------------------------------------------------- UUID ------
# 未显式提供 V2RAY_UUID 时，首次启动生成并持久化到挂载卷，避免重启后服务端
# UUID 变化导致已下发的客户端配置失效。
if [ -z "${V2RAY_UUID:-}" ]; then
    if [ -s "$UUID_FILE" ]; then
        V2RAY_UUID="$(tr -d ' \t\r\n' < "$UUID_FILE")"
        log "复用已持久化的 UUID（$UUID_FILE）"
    else
        if [ -r /proc/sys/kernel/random/uuid ]; then
            V2RAY_UUID="$(cat /proc/sys/kernel/random/uuid)"
        elif [ -r /dev/urandom ]; then
            V2RAY_UUID="$(make_uuid_from_hex "$(od -An -N16 -tx1 < /dev/urandom | tr -d ' \n')")" \
                || die "无法生成 UUID，请显式设置 V2RAY_UUID"
        else
            die "无法生成 UUID（/proc/sys/kernel/random/uuid 与 /dev/urandom 均不可读），请显式设置 V2RAY_UUID"
        fi
        mkdir -p "$(dirname "$UUID_FILE")"
        ( umask 077; printf '%s\n' "$V2RAY_UUID" > "$UUID_FILE" )
        log "已生成新的 UUID 并写入 $UUID_FILE"
    fi
fi

V2RAY_UUID="$(printf '%s' "$V2RAY_UUID" | tr 'A-Z' 'a-z')"
case "$V2RAY_UUID" in
    ????????-????-????-????-????????????) ;;
    *) die "V2RAY_UUID 不是合法 UUID：$V2RAY_UUID" ;;
esac
case "$V2RAY_UUID" in
    *[!0-9a-f-]*) die "V2RAY_UUID 含有非法字符：$V2RAY_UUID" ;;
esac

# ------------------------------------------------------- 环境变量与校验 -----
V2RAY_PORT="${V2RAY_PORT:-10000}"
case "$V2RAY_PORT" in
    ''|*[!0-9]*) die "V2RAY_PORT 必须为数字，当前为：$V2RAY_PORT" ;;
esac
[ "$V2RAY_PORT" -ge 1 ] && [ "$V2RAY_PORT" -le 65535 ] || die "V2RAY_PORT 超出 1-65535：$V2RAY_PORT"

V2RAY_WS_PATH="${V2RAY_WS_PATH:-/vless-ws}"
case "$V2RAY_WS_PATH" in
    /*) ;;
    *) die "V2RAY_WS_PATH 必须以 / 开头：$V2RAY_WS_PATH" ;;
esac
# 路径会原样写进 JSON，限制字符集避免引号/反斜杠破坏配置。
if ! printf '%s' "$V2RAY_WS_PATH" | grep -Eq '^/[A-Za-z0-9._~/-]*$'; then
    die "V2RAY_WS_PATH 只能包含字母、数字与 . _ ~ / - ：$V2RAY_WS_PATH"
fi

V2RAY_EMAIL="${V2RAY_EMAIL:-vless-ws}"
if ! printf '%s' "$V2RAY_EMAIL" | grep -Eq '^[A-Za-z0-9._@-]+$'; then
    die "V2RAY_EMAIL 只能包含字母、数字与 . _ @ - ：$V2RAY_EMAIL"
fi

V2RAY_WS_HOST="${V2RAY_WS_HOST:-}"
if [ -n "$V2RAY_WS_HOST" ] && ! printf '%s' "$V2RAY_WS_HOST" | grep -Eq '^[A-Za-z0-9.-]+$'; then
    die "V2RAY_WS_HOST 含有非法字符：$V2RAY_WS_HOST"
fi

no_percent V2RAY_UUID "$V2RAY_UUID"
no_percent V2RAY_EMAIL "$V2RAY_EMAIL"
no_percent V2RAY_WS_PATH "$V2RAY_WS_PATH"
no_percent V2RAY_WS_HOST "$V2RAY_WS_HOST"
# 这两项在下面才赋默认值，此处用安全展开，避免未设置时被 set -u 中断。
no_percent V2RAY_LOG_ACCESS "${V2RAY_LOG_ACCESS:-}"
no_percent V2RAY_LOG_ERROR "${V2RAY_LOG_ERROR:-}"

V2RAY_LOG_LEVEL="${V2RAY_LOG_LEVEL:-warning}"
case "$V2RAY_LOG_LEVEL" in
    debug|info|warning|error|none) ;;
    *) die "V2RAY_LOG_LEVEL 只能是 debug/info/warning/error/none：$V2RAY_LOG_LEVEL" ;;
esac

V2RAY_SNIFFING="${V2RAY_SNIFFING:-true}"
case "$V2RAY_SNIFFING" in
    true|false) ;;
    *) die "V2RAY_SNIFFING 只能是 true 或 false：$V2RAY_SNIFFING" ;;
esac

V2RAY_DOMAIN_STRATEGY="${V2RAY_DOMAIN_STRATEGY:-UseIP}"
case "$V2RAY_DOMAIN_STRATEGY" in
    AsIs|UseIP|UseIPv4|UseIPv6) ;;
    *) die "V2RAY_DOMAIN_STRATEGY 只能是 AsIs/UseIP/UseIPv4/UseIPv6：$V2RAY_DOMAIN_STRATEGY" ;;
esac

V2RAY_BLOCK_PRIVATE="${V2RAY_BLOCK_PRIVATE:-true}"
case "$V2RAY_BLOCK_PRIVATE" in
    true|false) ;;
    *) die "V2RAY_BLOCK_PRIVATE 只能是 true 或 false：$V2RAY_BLOCK_PRIVATE" ;;
esac

V2RAY_LOG_ACCESS="${V2RAY_LOG_ACCESS:-}"
V2RAY_LOG_ERROR="${V2RAY_LOG_ERROR:-}"
if [ -n "$V2RAY_LOG_ACCESS" ]; then
    case "$V2RAY_LOG_ACCESS" in
        /*) ;;
        *) die "V2RAY_LOG_ACCESS 必须是绝对路径（或留空以输出到 stdout）：$V2RAY_LOG_ACCESS" ;;
    esac
    mkdir -p "$(dirname "$V2RAY_LOG_ACCESS")" || die "无法创建日志目录：$(dirname "$V2RAY_LOG_ACCESS")"
fi
if [ -n "$V2RAY_LOG_ERROR" ]; then
    case "$V2RAY_LOG_ERROR" in
        /*) ;;
        *) die "V2RAY_LOG_ERROR 必须是绝对路径（或留空以输出到 stderr）：$V2RAY_LOG_ERROR" ;;
    esac
    mkdir -p "$(dirname "$V2RAY_LOG_ERROR")" || die "无法创建日志目录：$(dirname "$V2RAY_LOG_ERROR")"
fi

[ -r "$TEMPLATE" ] || die "模板不存在或不可读：$TEMPLATE"
[ -x "$V2RAY_BIN" ] || die "v2ray 二进制不存在或不可执行：$V2RAY_BIN"
[ -f "$ASSET_DIR/geoip.dat" ] || log "警告：$ASSET_DIR/geoip.dat 缺失，geoip 相关规则将失效"

# ------------------------------------------------------------- 路由规则 -----
# 只在需要时生成规则条目。注意：绝不能生成 "ip": [] 这类空字段规则，
# 空规则会被 v2ray 判定为 "this rule has no effective fields" 并拒绝启动。
if [ "$V2RAY_BLOCK_PRIVATE" = "true" ]; then
    ROUTING_RULES="      {
        \"type\": \"field\",
        \"ip\": [ \"geoip:private\" ],
        \"outboundTag\": \"blocked\"
      }"
else
    ROUTING_RULES=""
fi

# --------------------------------------------------------------- 合成 -------
mkdir -p "$(dirname "$CONFIG")"
tmp="${CONFIG}.tmp.$$"
scalar="${CONFIG}.scalar.$$"
trap 'rm -f "$tmp" "$scalar"' EXIT INT TERM

# sed 替换串里先转义反斜杠、与和 & 及分隔符 |，避免值中的特殊字符破坏替换。
escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# 占位符用 %%NAME%%，各变量在校验阶段已禁止出现 % 字符，
# 因此替换结果不会被后续占位符二次匹配（__NAME__ 形式配合自由文本值会串扰）。
#
# 第一步：标量替换。只处理单值占位符，路由规则留到第二步，因为 busybox sed
# 的替换串不支持跨行内容（会报 unmatched '|'）。
sed \
    -e "s|%%UUID%%|$(escape "$V2RAY_UUID")|g" \
    -e "s|%%EMAIL%%|$(escape "$V2RAY_EMAIL")|g" \
    -e "s|%%PORT%%|$(escape "$V2RAY_PORT")|g" \
    -e "s|%%WS_PATH%%|$(escape "$V2RAY_WS_PATH")|g" \
    -e "s|%%WS_HOST%%|$(escape "$V2RAY_WS_HOST")|g" \
    -e "s|%%SNIFFING%%|$(escape "$V2RAY_SNIFFING")|g" \
    -e "s|%%DOMAIN_STRATEGY%%|$(escape "$V2RAY_DOMAIN_STRATEGY")|g" \
    -e "s|%%LOG_LEVEL%%|$(escape "$V2RAY_LOG_LEVEL")|g" \
    -e "s|%%LOG_ACCESS%%|$(escape "$V2RAY_LOG_ACCESS")|g" \
    -e "s|%%LOG_ERROR%%|$(escape "$V2RAY_LOG_ERROR")|g" \
    "$TEMPLATE" > "$scalar" || die "渲染配置失败（标量替换）"

# 第二步：展开路由规则占位行，替换为多行规则片段（或空）。
: > "$tmp"
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        *%%ROUTING_RULES%%*) printf '%s\n' "$ROUTING_RULES" ;;
        *)                   printf '%s\n' "$line" ;;
    esac
done < "$scalar" >> "$tmp" || die "渲染配置失败（路由规则）"
rm -f "$scalar"

chmod 0600 "$tmp"
mv "$tmp" "$CONFIG"
trap - EXIT INT TERM

# ------------------------------------------------------------- 版本分支 -----
# v5 用 "run -c"，v4 用 "-c"；两个版本的 flag 互不兼容（v5 不认 -c/-version，
# v4 不认 run 子命令，且会退回去读二进制同目录的配置）。因此分别探测：
#   v4 支持 -version，v5 只支持 version 子命令。
detect_major() {
    ver="$("$V2RAY_BIN" -version 2>&1 | head -n 1 | awk '{print $2}')"
    case "$ver" in
        4.*|v4.*) printf '4'; return ;;
    esac
    ver="$("$V2RAY_BIN" version 2>&1 | head -n 1 | awk '{print $2}')"
    case "$ver" in
        4.*|v4.*) printf '4'; return ;;
        5.*|v5.*) printf '5'; return ;;
    esac
    printf ''
}

MAJOR=""
case "${V2RAY_CLI:-auto}" in
    v4|4) MAJOR="4" ;;
    v5|5) MAJOR="5" ;;
    auto) MAJOR="$(detect_major)" ;;
    *)    die "V2RAY_CLI 只能是 auto/v4/v5：$V2RAY_CLI" ;;
esac

case "$MAJOR" in
    4) set -- -c "$CONFIG" ;;
    5) set -- run -c "$CONFIG" ;;
    *) log "警告：无法识别 v2ray 主版本，按 v5 的 CLI 启动（可用 V2RAY_CLI=v4 强制）"
       set -- run -c "$CONFIG" ;;
esac

# 记录镜像内实际部署的 v2ray 版本（构建时写入），便于排障。
V2RAY_VERSION_FILE="${V2RAY_VERSION_FILE:-/usr/local/share/v2ray/.v2ray-version}"
BUILT_VERSION="$(cat "$V2RAY_VERSION_FILE" 2>/dev/null || echo '未知')"

# ------------------------------------------------------------ 分享链接 -----
# 启动前顺手生成一次 VLESS 分享链接，落盘到挂载目录，省得再进容器手动拼。
# 部署完成后仍可在容器内随时重跑（结果同样写到该文件）：
#   V2RAY_SHARE_HOST=你的域名 sh /usr/local/bin/share-link.sh
SHARE_LINK_BIN="${V2RAY_SHARE_BIN:-/usr/local/bin/share-link.sh}"
SHARE_LINK_FILE="${V2RAY_SHARE_FILE:-$(dirname "$UUID_FILE")/share-link.txt}"
# 域名：V2RAY_SHARE_HOST 优先，未设置时退回 V2RAY_WS_HOST（它的语义是校验 Host 头）。
V2RAY_SHARE_HOST="${V2RAY_SHARE_HOST:-$V2RAY_WS_HOST}"
V2RAY_SHARE_PORT="${V2RAY_SHARE_PORT:-443}"

if [ -n "$V2RAY_SHARE_HOST" ]; then
    if ! printf '%s' "$V2RAY_SHARE_HOST" | grep -Eq '^[A-Za-z0-9.-]+$'; then
        die "V2RAY_SHARE_HOST 含有非法字符：$V2RAY_SHARE_HOST"
    fi
else
    # 不阻断启动：域名是客户端侧的参数，服务端照样能跑起来。
    V2RAY_SHARE_HOST="your.domain.com"
    log "警告：V2RAY_SHARE_HOST 与 V2RAY_WS_HOST 均未设置，链接里的域名暂用占位符 $V2RAY_SHARE_HOST"
fi

case "$V2RAY_SHARE_PORT" in
    ''|*[!0-9]*) die "V2RAY_SHARE_PORT 必须为数字：$V2RAY_SHARE_PORT" ;;
esac

if [ -x "$SHARE_LINK_BIN" ]; then
    # V2RAY_UUID 是 shell 变量（未导出），显式传给脚本，不依赖环境继承。
    # 脚本失败绝不能拖垮 entrypoint（set -e 下命令替换失败会直接终止），
    # 因此这里用 if 兜住退出码，再按情况回显。
    SHARE_TEXT=""
    if SHARE_TEXT="$(V2RAY_SHARE_OUT="$SHARE_LINK_FILE" \
                     V2RAY_UUID="$V2RAY_UUID" \
                     V2RAY_UUID_FILE="$UUID_FILE" \
                     V2RAY_WS_PATH="$V2RAY_WS_PATH" \
                     V2RAY_SHARE_HOST="$V2RAY_SHARE_HOST" \
                     V2RAY_SHARE_PORT="$V2RAY_SHARE_PORT" \
                     "$SHARE_LINK_BIN" 2>&1)"; then
        :
    else
        log "警告：生成分享链接时脚本返回非零码，以下为其输出"
    fi
    # 逐行套上时间戳前缀，便于 docker logs 里辨认。
    printf '%s\n' "$SHARE_TEXT" | while IFS= read -r SHARE_LINE; do log "$SHARE_LINE"; done
    if [ -s "$SHARE_LINK_FILE" ]; then
        log "分享链接已写入 $SHARE_LINK_FILE"
    else
        log "警告：未能写入 $SHARE_LINK_FILE，链接见上方日志"
    fi
else
    log "警告：未找到分享链接脚本 $SHARE_LINK_BIN，跳过生成"
fi

log "启动 v2ray：version=$BUILT_VERSION uuid=$V2RAY_UUID port=$V2RAY_PORT path=$V2RAY_WS_PATH host=${V2RAY_WS_HOST:-<任意>}"
exec "$V2RAY_BIN" "$@"
