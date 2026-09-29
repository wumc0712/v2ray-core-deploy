# v2ray-core-deploy

[v2ray-core](https://github.com/v2fly/v2ray-core) 的服务端 Docker 方案，协议为 **VLESS + WebSocket**。

本方案只跑 **一个 v2ray 容器**：容器内是**明文 WebSocket**，TLS 由 CDN（Cloudflare 等）或外层 Nginx/Caddy 终止。这样容器本身无需证书，回源配置与 CDN 天然兼容。

## 文件结构

```
.
├── Dockerfile                  多阶段构建：官方镜像取二进制 → alpine 运行时
├── docker-compose.yml
├── .env.example                变量说明，复制为 .env 使用
├── config/
│   └── config.json.template    配置模板，占位符由入口脚本替换
└── docker/
    ├── entrypoint.sh           渲染配置 + 校验环境变量 + 分支 v4/v5 CLI
    └── extract-artifacts.sh    在 builder 阶段定位并抽出发行产物
```

## 构建方式

镜像来源为 Docker Hub 官方仓库 `v2fly/v2fly-core`（由 [v2fly/docker](https://github.com/v2fly/docker) 构建）。该镜像内含 `v2ray` 二进制与 `geoip.dat` / `geosite.dat`。

`Dockerfile` 做的是**多阶段资源抽取**：builder 阶段用官方镜像，只 COPY 出 `v2ray` 二进制与两份 geo 数据，再放进干净的 `alpine` 运行时层。好处是运行层不含编译期与官方镜像里的其他冗余内容，且不需要在构建时访问 GitHub Release。

> 注意：`ghcr.io/v2fly/...` 的匿名拉取会被拒绝，因此这里只用 Docker Hub 的官方镜像。

## 快速开始

```bash
cp .env.example .env
# 编辑 .env：至少设置一个强随机 V2RAY_WS_PATH；V2RAY_UUID 可留空自动生成
docker compose up -d --build

# 未设置 V2RAY_UUID 时，查看自动生成并持久化的 UUID
cat data/uuid

# 看日志
docker compose logs -f v2ray
```

仅用 Docker 不借助 compose：

```bash
docker build -t v2ray-core-deploy:v5.41.0 .

docker run -d --name v2ray \
  -p 10000:10000 \
  -e V2RAY_PORT=10000 \
  -e V2RAY_WS_PATH=/vless-ws \
  -e V2RAY_UUID=97a8d9c0-1b2e-4f30-8a41-5c6d7e8f9012 \
  -v "$PWD/data:/etc/v2ray" \
  v2ray-core-deploy:v5.41.0
```

## 服务端配置

容器启动时由 `docker/entrypoint.sh` 把 `config/config.json.template` 渲染成 `/run/v2ray/config.json`，渲染结果可在容器内直接查看：

```bash
docker compose exec v2ray cat /run/v2ray/config.json
```

关键字段：

| 字段 | 值 | 说明 |
| --- | --- | --- |
| `inbounds[0].protocol` | `vless` | |
| `inbounds[0].settings.decryption` | `none` | VLESS 服务端固定为 `none` |
| `inbounds[0].settings.clients[].flow` | `""` | **必须为空**，`xtls-rprx-vision` 仅用于 TLS 直连，与 WS 不兼容 |
| `inbounds[0].streamSettings.network` | `ws` | |
| `inbounds[0].streamSettings.security` | `none` | TLS 在外层终止 |
| `inbounds[0].streamSettings.wsSettings.path` | 由 `V2RAY_WS_PATH` 指定 | 需与客户端一致 |
| `outbounds[0]` | `direct` / `freedom` | **出站列表第一项即默认出站**，不要把 `blocked` 放前面 |

### 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `V2RAY_VERSION` | `v5.41.0` | 构建参数，指定官方镜像 tag（仅 Dockerfile/compose 使用） |
| `V2RAY_PORT` | `10000` | 明文 WS 监听端口 |
| `V2RAY_WS_PATH` | `/vless-ws` | WS 路径，**建议改成不易猜测的值** |
| `V2RAY_UUID` | 空 | 留空则首次启动生成并持久化到 `./data/uuid` |
| `V2RAY_EMAIL` | `vless-ws` | 日志中标识该客户端，便于区分 |
| `V2RAY_WS_HOST` | 空 | 限定 `Host` 头，留空不校验；配合 CDN 时可设为你的域名 |
| `V2RAY_LOG_LEVEL` | `warning` | `debug`/`info`/`warning`/`error`/`none` |
| `V2RAY_LOG_ACCESS` | 空 | 留空输出到容器 stdout |
| `V2RAY_LOG_ERROR` | 空 | 留空输出到容器 stderr |
| `V2RAY_SNIFFING` | `true` | 流量嗅探，用于按域名分流 |
| `V2RAY_DOMAIN_STRATEGY` | `UseIP` | 出站解析策略 |
| `V2RAY_BLOCK_PRIVATE` | `true` | 丢弃目标为私网地址的出站流量，避免服务端被当作内网跳板 |
| `V2RAY_CLI` | `auto` | 主版本探测；仅有异常时才需强制 `v4`/`v5` |
| `LISTEN_ADDR` | `0.0.0.0` | 仅 compose 端口映射使用，本机自测可设 `127.0.0.1` |

脚本会对 `V2RAY_PORT`、`V2RAY_WS_PATH`、`V2RAY_UUID`、`V2RAY_EMAIL`、`V2RAY_LOG_LEVEL`、`V2RAY_SNIFFING`、`V2RAY_DOMAIN_STRATEGY`、`V2RAY_BLOCK_PRIVATE`、`V2RAY_WS_HOST`、`V2RAY_CLI` 做校验，非法值会让容器直接以非零码退出并打印原因，而不是带着坏配置启动。其中 `V2RAY_WS_PATH`、`V2RAY_EMAIL`、`V2RAY_WS_HOST` 只允许安全字符集，避免破坏生成的 JSON。

## v4 / v5 差异

两个大版本的命令行参数**互不兼容**，入口脚本会自动探测并分支：

| | v4（如 `v4.45.2`） | v5（如 `v5.41.0`） |
| --- | --- | --- |
| 启动参数 | `v2ray -c <config>` | `v2ray run -c <config>` |
| 版本输出 | `v2ray -version` | `v2ray version` |
| 配置校验 | `v2ray -test -config <config>` | `v2ray test -c <config>` |

切换版本只需改 `V2RAY_VERSION`。实测两个版本的服务端配置模板通用（`v4.45.2` 与 `v5.53.0` 均已通过校验并完成 VLESS+WS 连通）。

## CDN 回源

以 Cloudflare 为例：

- 添加一条 A/AAAA 记录（可开橙云代理），指向你的服务器。
- SSL/TLS 模式建议 **Full (strict)**，回源端口填 `V2RAY_PORT`。
- 本方案容器是明文回源，所以**不要**用 Flexible 模式。
- Cloudflare 默认只代理特定 HTTP/HTTPS 端口，回源端口若不在列表内需自行调整；也可将 v2ray 监听在 `80`/`443` 之外但仍被 CF 支持的端口上。

`V2RAY_WS_PROXY` 无需设置：v2ray 的 WS 入站不校验 `Origin`/`Referer`，客户端只需 `path` 与 `host` 一致。

## 客户端配置（参考）

```json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "listen": "127.0.0.1", "port": 10808, "protocol": "socks",
      "settings": { "udp": true } }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "your.domain.com",
            "port": 443,
            "users": [
              { "id": "与服务端一致的-UUID", "encryption": "none", "flow": "" }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": { "serverName": "your.domain.com" },
        "wsSettings": { "path": "/vless-ws", "headers": { "Host": "your.domain.com" } }
      }
    }
  ]
}
```

分享链接形式：

```
vless://<UUID>@your.domain.com:443?encryption=none&security=tls&type=ws&host=your.domain.com&sni=your.domain.com&path=%2Fvless-ws#v2ray-core-deploy
```

## 生成分享链接

`scripts/share-link.sh` 按 `.env` 拼出可直接导入客户端的 VLESS 链接，在仓库根目录执行（脚本无 shebang 可执行位，统一用 `sh` 调用；想直接 `./scripts/share-link.sh` 需先 `chmod +x`）：

```bash
sh scripts/share-link.sh .env                # 完整输出：参数回显 + 链接
sh scripts/share-link.sh .env | tail -n 1    # 只要链接本身
```

不传参数则直接读当前环境变量：

```bash
set -a; . ./.env; set +a; sh scripts/share-link.sh | tail -n 1
```

取值顺序与来源：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `V2RAY_UUID` / `./data/uuid` | — | 环境变量优先，其次读 `V2RAY_UUID_FILE`，再退回 `./data/uuid`（容器生成的 UUID 就落在这里） |
| `V2RAY_SHARE_HOST` 或 `V2RAY_WS_HOST` | — | **必填**，客户端实际连接的域名（走 CDN 就填 CDN 域名） |
| `V2RAY_SHARE_PORT` | `443` | 客户端连接端口 |
| `V2RAY_WS_PATH` | `/vless-ws` | 与服务端保持一致 |
| `V2RAY_SHARE_SNI` | 同 HOST | TLS SNI |
| `V2RAY_SHARE_LABEL` | `v2ray-core-deploy` | 链接 `#` 后的备注名 |
| `V2RAY_SHARE_INSECURE` | `false` | 置 `true` 会在链接里带上 `allowInsecure=1` |

Windows 上脚本不能在 PowerShell 里直接跑，用 WSL 或 Git Bash（`sh scripts/share-link.sh .env`）：

```powershell
wsl -e sh scripts/share-link.sh .env
# 或
& "C:\Program Files\Git\bin\bash.exe" -c "sh scripts/share-link.sh .env"
```

## 安全注意事项

- **服务端不做 TLS，明文 WS 端口不要直接暴露到公网**；务必置于 CDN 或反代之后。
- WS 路径用强随机值，降低被主动探测识别的概率。
- 容器以 `read_only` + `cap_drop: [ALL]` + `no-new-privileges` 运行，仅挂载 `./data` 与临时 `tmpfs`。
- 若设置了 `V2RAY_LOG_ACCESS` / `V2RAY_LOG_ERROR` 为文件路径，在 `read_only: true` 下需额外挂载可写卷，否则容器启动即失败。

## 已验证的行为

以下均在本机用真实 v2ray 二进制（`v4.45.2`、`v5.53.0`）配合 busybox（容器内同一套 shell/sed 实现）实测确认：

- 渲染出的配置在 v4 与 v5 下均通过 `test` 校验，并能完成 VLESS + WS 端到端代理。
- 明文 WS 端口对未升级 HTTP 请求返回 `404`，对错误路径返回 `404`，仅在路径匹配且携带 WS 升级头时返回 `101`。
- `V2RAY_BLOCK_PRIVATE=true` 时，私网目标被 `[blocked]`，公网目标走 `[direct]`。
- 所有环境变量校验分支均按预期拒绝非法输入并以非零码退出。
