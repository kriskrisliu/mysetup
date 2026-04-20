## 说明

这个仓库用于自动化初始化新的 Ubuntu 用户环境。执行 `setup.sh` 后，可完成常用的个人开发环境配置。

当前包含：
- 先检查必须依赖是否已安装；若缺少依赖，则提示用户并在确认后使用 sudo 安装
- 从仓库根目录的 `authorized_keys` 读取 SSH 公钥，并追加到用户的 `~/.ssh/authorized_keys`
- 配置脚本执行时使用的代理
- 安装 Miniconda
- 安装 oh-my-zsh
- 安装 zsh-autosuggestions
- 安装 Claude Code，并确保 `~/.zshrc` 中包含 Claude Code 所需 PATH
- 将仓库内 `.claude/skills` 覆盖复制到全局 `~/.claude/skills`
- 将默认 shell 切换为 zsh；该步骤不使用 sudo，但在交互模式下可能要求用户输入登录密码，非交互模式下则跳过
