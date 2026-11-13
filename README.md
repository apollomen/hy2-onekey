## 一键运行命令

登录 VPS 终端（root 用户），执行以下命令即可安装：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/apollomen/hy2-onekey/refs/heads/main/hy2-onekey.sh)"
```

如果系统未预装 curl，可使用 wget 代替：

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/apollomen/hy2-onekey/refs/heads/main/hy2-onekey.sh)"
```
