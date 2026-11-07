# reality-nat

适合小内存 NAT VPS 的 VLESS + REALITY 安装脚本。支持 Alpine/OpenRC 和 Debian、Ubuntu/systemd，以及 x86_64、aarch64。

## 一行安装

在待部署的新 VPS 上以 root 运行，需要已有 `wget` 和可用的 HTTPS CA 证书：

```sh
wget -O install-reality.sh https://raw.githubusercontent.com/kazeyo666/reality-nat/main/install-reality.sh && sh install-reality.sh
```

下载成功后才会执行，交互填写公网入口、商家分配的公网 TCP 端口、内部监听端口和伪装域名。

例如公网 `20443` 映射到内部 `443`：公网端口用于生成客户端链接，内部端口用于 Xray 监听。商家 NAT 映射需要预先设置；公网入口应使用商家提供的入站地址。

已有脚本时也可以通过环境变量无人值守安装：

```sh
PUBLIC_HOST=nat.example.com PUBLIC_PORT=20443 LISTEN_PORT=443 SNI=www.tesla.cn sh install-reality.sh
```

## 安装行为

- 默认固定官方 Xray `v26.10.31`，可用 `XRAY_VERSION=vX.Y.Z` 指定版本。
- 校验官方发布包的 SHA-256，只安装 Xray 可执行文件，不安装面板、Docker 或地理数据库。
- 自动生成 UUID、X25519 密钥和 shortId，使用独立非登录用户运行。
- 自动配置服务、开机自启和故障重启，完成后输出 `vless://` 导入链接。
- 发现常见已有 Xray 配置或服务会退出；不接管、覆盖或升级已有节点。
- 不修改 SSH、防火墙、swap、sysctl 或商家 NAT 映射。
- 使用 `GOMEMLIMIT=32MiB`、`GOGC=50`，关闭访问日志，警告日志交给系统日志。

`32MiB` 是 Go 运行时软内存目标，不是进程总内存上限。下载缓存使用 `/var/tmp`；该目录仍需足够空间，若它挂载为内存盘，也会占用内存。

默认伪装域名为 `www.tesla.cn`，可在安装时更换。该域名可能触发 Xray 的封锁风险警告；目标是否适合应以目标 VPS 的实际测试为准。参见 [REALITY 官方说明](https://xtls.github.io/en/config/transports/reality.html)。

## 管理

查看导入链接：

```sh
cat /opt/reality-nat/client.txt
```

Alpine：

```sh
rc-service reality-nat status
rc-service reality-nat restart
rc-service reality-nat stop
```

日志查看 `logread -e reality-nat` 或 `/var/log/messages`，取决于系统日志配置。

Debian / Ubuntu：

```sh
systemctl status reality-nat
systemctl restart reality-nat
journalctl -u reality-nat -n 50
```

配置保存在 `/opt/reality-nat/config.json`，其中包含私钥，请勿公开。

## 验证范围

本地已通过 `sh`、BusyBox `sh` 语法检查、非法参数拒绝、密钥生成及 Xray `26.3.27` 的配置检查。默认下载版本为 `26.10.31`，尚未完成完整下载安装、OpenRC/systemd 启动、ARM64 运行和公网 REALITY 连接测试。

安装脚本报告成功仅表示配置检查、服务状态和本机监听通过。公网 NAT 映射与实际转发需要在外部客户端导入链接后验证。

离线测试（需要 Python 3.9+、BusyBox 和 Xray）：

```sh
TEST_XRAY=/path/to/xray python3 test_installer.py
```

测试不安装软件、不启动服务，也不修改系统配置。
