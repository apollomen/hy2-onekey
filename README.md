# hy2-onekey

Hysteria2 一键安装脚本（Debian / Ubuntu，systemd，root 运行）。

## 特点

- 每次自动安装官方最新版，下载后按该版本官方 `hashes.txt` 校验 SHA256，不一致即中止
- 固定部署口径：UDP 443 ＋ 端口跳跃 20000-40000、Salamander 混淆、自签证书（SNI www.bing.com）、masquerade 转发 bing、每台机器独立随机密码
- 幂等：重复运行复用已有证书和密码，不会把现有节点弄失效
- 标准输出只打印一行跳跃版分享链接，链接同时存到服务器 `/root/hy2-link.txt`（600 权限）

## 用法

```bash
git clone https://github.com/apollomen/hy2-onekey.git
cd hy2-onekey
chmod +x hy2-onekey.sh
./hy2-onekey.sh
```

- 轮换密码（旧链接作废）：`./hy2-onekey.sh --rotate`
- 卸载：`./hy2-onekey.sh --uninstall`

## 说明

- 服务由 systemd 管理：`hy2.service`（主服务）、`hy2-hop.service`（跳跃端口转发），开机自启
- 配置在 `/etc/hy2/`，密码在 `/etc/hy2/secrets.env`（600 权限）
- 升级即重跑脚本：新版二进制替换前会备份为 `hysteria2.bak`
