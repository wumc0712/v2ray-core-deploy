# syntax=docker/dockerfile:1

# 官方镜像 v2fly/v2fly-core 由 v2fly/docker 仓库的 Dockerfile 构建：
# 从 GitHub Release 下载 v2ray-linux-<arch>.zip，校验 SHA512 后解包，
# 产物为 v2ray 二进制 + geoip.dat / geosite.dat。这里把它当构建源抽产物。
ARG V2RAY_VERSION=v5.41.0

# --------------------------------------------------------------- builder ----
FROM v2fly/v2fly-core:${V2RAY_VERSION} AS builder

COPY docker/extract-artifacts.sh /tmp/extract-artifacts.sh
RUN sh /tmp/extract-artifacts.sh /out

# --------------------------------------------------------------- runtime ----
FROM alpine:3.21

ARG V2RAY_VERSION

LABEL org.opencontainers.image.title="v2ray-core-deploy" \
      org.opencontainers.image.description="v2ray-core 服务端，VLESS + WebSocket" \
      org.opencontainers.image.source="https://github.com/v2fly/v2ray-core" \
      org.opencontainers.image.version="${V2RAY_VERSION}"

# V2RAY_LOCATION_ASSET 显式指定 geo 数据目录，不依赖 v2ray 的隐式查找顺序。
ENV V2RAY_LOCATION_ASSET=/usr/local/share/v2ray \
    V2RAY_BIN=/usr/local/bin/v2ray \
    V2RAY_TEMPLATE=/usr/local/share/v2ray/config.json.template \
    V2RAY_VERSION_FILE=/usr/local/share/v2ray/.v2ray-version \
    V2RAY_CONFIG=/run/v2ray/config.json \
    V2RAY_UUID_FILE=/etc/v2ray/uuid

RUN set -eux; \
    apk add --no-cache ca-certificates; \
    mkdir -p /usr/local/share/v2ray /run/v2ray /etc/v2ray

COPY --from=builder /out/v2ray       /usr/local/bin/v2ray
COPY --from=builder /out/geoip.dat   /usr/local/share/v2ray/geoip.dat
COPY --from=builder /out/geosite.dat /usr/local/share/v2ray/geosite.dat

COPY config/config.json.template /usr/local/share/v2ray/config.json.template
COPY docker/entrypoint.sh        /usr/local/bin/docker-entrypoint.sh

RUN set -eux; \
    chmod +x /usr/local/bin/v2ray /usr/local/bin/docker-entrypoint.sh; \
    printf '%s\n' "${V2RAY_VERSION}" > "${V2RAY_VERSION_FILE}"; \
    # 冒烟测试：确认二进制可执行且是 v2ray。v4 认 -version，v5 只有 version 子命令。
    ( /usr/local/bin/v2ray -version || /usr/local/bin/v2ray version ) 2>&1 | grep -q 'V2Ray'

EXPOSE 10000/tcp

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
