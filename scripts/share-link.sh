#!/bin/sh
# 从 .env（或环境变量）生成 VLESS + WebSocket 分享链接。
#
# 用法：
#   ./scripts/share-link.sh .env
#   ./scripts/share-link.sh            # 直接读环境变量
#
# 想拿到可直接复制的链接，建议不带注释执行：
#   set -a; . ./.env; set +a; ./scripts/share-link.sh | tail -n 1
set -eu

# ---------------------------------------------------------------- 读取 ----
ENV_FILE="${1:-}"
if [ -n "$ENV_FILE" ]; then
    [ -f "$ENV_FILE" ] || { echo "找不到配置文件：$ENV_FILE" >&2; exit 1; }
    # 只取 KEY=VALUE 行，忽略注释与空行；最后一个赋值生效。
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        case "$line" in
            *=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        # 去掉 key 两端空白
        key="$(printf '%s' "$key" | tr -d ' \t')"
        case "$key" in
            ''|*[!A-Za-z0-9_]*) continue ;;
        esac
        # 去掉值两端空白，并剥掉成对的单/双引号
        val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        export "$key=$val"
    done < "$ENV_FILE"
fi

# ---------------------------------------------------------------- 取值 ----
UUID="${V2RAY_UUID:-}"
if [ -z "$UUID" ] && [ -s "${V2RAY_UUID_FILE:-/etc/v2ray/uuid}" ]; then
    UUID="$(tr -d ' \t\r\n' < "${V2RAY_UUID_FILE:-/etc/v2ray/uuid}")"
fi
# 本地部署时 uuid 常落在 ./data/uuid
if [ -z "$UUID" ] && [ -s "./data/uuid" ]; then
    UUID="$(tr -d ' \t\r\n' < ./data/uuid)"
fi

HOST="${V2RAY_SHARE_HOST:-${V2RAY_WS_HOST:-}}"
PORT="${V2RAY_SHARE_PORT:-443}"
WS_PATH="${V2RAY_WS_PATH:-/vless-ws}"
SNI="${V2RAY_SHARE_SNI:-$HOST}"
INSECURE="${V2RAY_SHARE_INSECURE:-false}"
LABEL="${V2RAY_SHARE_LABEL:-v2ray-core-deploy}"

if [ -z "$UUID" ]; then
    echo "错误：拿不到 UUID。请先在 .env 里设置 V2RAY_UUID，或让容器生成后读取 ./data/uuid。" >&2
    exit 1
fi
if [ -z "$HOST" ]; then
    echo "错误：拿不到域名/Host。请设置 V2RAY_SHARE_HOST（或 V2RAY_WS_HOST）。" >&2
    exit 1
fi

# ------------------------------------------------------------ URL 编码 ----
# busybox 无现代 sed，用 od 逐字节判断，按 RFC 3986 unreserved 之外全部百分号编码。
# 转义用 POSIX 的 \NNN（八进制）：printf 的 \xHH 在 dash/bash 下不通用，容器里是 ash。
urlencode() {
    str="$1"
    out=""
    hex="$(printf '%s' "$str" | od -An -v -tx1 | tr -d ' \n' | tr 'a-f' 'A-F')"
    while [ -n "$hex" ]; do
        byte="${hex%"${hex#??}"}"
        hex="${hex#??}"
        case "$byte" in
            2D|2E|5F|7E|3[0-9]|4[1-9A-F]|5[0-9A]|6[1-9A-F]|7[0-9A]) out="$out$(printf "\\$(printf '%03o' "0x$byte")")" ;;
            *) out="$out$(printf '%%%s' "$byte")" ;;
        esac
    done
    printf '%s' "$out"
}

# ---------------------------------------------------------------- 校验 ----
case "$UUID" in
    ????????-????-????-????-????????????) ;;
    *) echo "警告：UUID 格式看起来不标准：$UUID" >&2 ;;
esac

SEC="tls"
SECURITY_PARAM="tls"
if [ "$INSECURE" = "true" ]; then
    SECURITY_PARAM="tls&allowInsecure=1"
fi

ENC_UUID="$(urlencode "$UUID")"
ENC_PATH="$(urlencode "$WS_PATH")"
ENC_SNI="$(urlencode "$SNI")"
ENC_LABEL="$(urlencode "$LABEL")"

LINK="vless://${ENC_UUID}@${HOST}:${PORT}?encryption=none&security=${SECURITY_PARAM}&type=ws&host=${HOST}&sni=${ENC_SNI}&path=${ENC_PATH}#${ENC_LABEL}"

# ---------------------------------------------------------------- 输出 ----
cat <<EOF
# 生成参数（请核对与 .env 一致）
UUID     = ${UUID}
地址     = ${HOST}
端口     = ${PORT}
SNI      = ${SNI}
WS 路径  = ${WS_PATH}
标签     = ${LABEL}

# 分享链接（整行复制）
${LINK}
EOF
