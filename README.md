# Mirasim 卸载工具

此工具仅支持 macOS。默认只读检查；只有显式使用 `--uninstall` 才会进入卸载流程。

```bash
./mirasim-uninstall.sh                         # 默认 --check
./mirasim-uninstall.sh --check --scan-root /path/to/home
./mirasim-uninstall.sh --check --report /path/to/report.txt
./mirasim-uninstall.sh --uninstall --scan-root /path/to/home
./mirasim-uninstall.sh --uninstall --yes --backup-dir /path/to/backup
./mirasim-uninstall.sh --help
```

`--check` 将日期、模式、扫描根目录和发现结果输出到终端，不修改扫描目标。只有明确指定 `--report PATH` 时才新建该报告文件；路径必须不存在，已有文件或符号链接均会被拒绝。

## 本机检查与卸载前核对

在此仓库目录运行以下只读检查。报告是这条命令唯一预期创建的文件；时间戳文件名若已存在，请换一个新路径。

```bash
./mirasim-uninstall.sh --check --scan-root "$HOME" --report "$HOME/Desktop/mirasim-check-$(date +%Y%m%d-%H%M%S).txt"
```

检查报告中的 `Delete candidate`、`Project state`、`Launchd plist`、`Warning` 和 `Scan root`，确认每个路径的归属及扫描范围。检查模式不会删除、移动或恢复文件；如需让扫描根目录在检查期间完全不产生新文件，请将 `--report` 指向根目录之外的一个尚不存在的绝对路径。

同时检查终端的 stderr。目录无读取权限时，`find` 的 `Permission denied` 等错误可能只出现在 stderr，不会写入 `--report`，而 `--check` 仍可能返回 `0`。出现此类警告时不能认为扫描已覆盖所有目录；先处理权限或缩小扫描范围，再重新检查并复核输出，然后才决定是否卸载。

真实主机上的 `--uninstall` 不属于自动验收。决定卸载前，先核对上述报告和 Skills 备份位置，尤其确认 `~/.claude/skills`、`~/.agents/skills` 是否指向 `~/.mirasim/skills`，并自行保留重要数据的独立备份。启动卸载后还要逐项核对终端列出的精确删除路径；不确定时取消，不要使用 `--yes`。

`--uninstall` 会发现候选项，在记录对象及父目录身份、App/plist/CLI 归属证据后列出编号的精确删除路径和备份位置。交互确认只接受单独的小写 `y` 并按回车；空输入、EOF（包括没有换行的 `y`）、`Y`、前后空格及其他输入均取消，退出码为 2。`--yes` 跳过确认提示，只允许与 `--uninstall` 一起使用。若需恢复 Skills，默认备份到 `$HOME/Desktop/mirasim-uninstall-backup-YYYYmmdd-HHMMSS`；可用 `--backup-dir PATH` 指定尚不存在的绝对路径。备份必须位于删除候选项之外。

确认后再次核对清单，停止已验证的 Mirasim 进程，并确认没有存活的写入进程，然后备份并恢复被接管的 Skills。源 Skills 内允许可在备份及恢复目录中继续解析的内部相对链接，以及解析到源 Skills 树外、存在的普通文件的绝对链接；后者会原样保留，不会复制或删除其目标文件。也允许技能根目录下一层的 `SKILL.md` 保留指向外部同名 `SKILL.md` 的绝对链接，即使该外部目标已缺失；这样不会因已失效的外部引用阻塞 Mirasim 清理。绝对内部链接、目录链接、普通断链和相对越界链接会退出 3，保留 Host state，需先人工恢复。删除 Host state 前会重新比较源目录、备份与已记录的 SHA-256 清单，发现备份后的变更即停止。候选对象或归属证据在确认期间或执行期间发生变化也会中止。

确认后，工具仅停止可验证为 Mirasim 可执行文件的进程，对已发现的启动项先执行 `launchctl bootout`，再删除经过验证的路径。系统启动项需要已有 root 权限；工具不会自动调用 `sudo`。无法卸载系统启动项时保留其 plist 并以失败状态退出。最后重新扫描，发现可自动处理的残留时也以失败状态退出。

Keychain 证书、TCC 权限、系统代理、通用模型路由配置和凭据轮换只在报告中提示人工复核，不自动修改。请按报告给出的证据和命令逐项判断，尤其不要因通用的 `ANTHROPIC_BASE_URL` 或 `OPENAI_BASE_URL` 设置就删除自己的配置。成功退出不代表这些人工复核项已处理。

退出码：`0` 表示只读检查完成或自动清理项已清除；`1` 表示参数、权限、删除或验收失败；`2` 表示确认取消；`3` 表示 Skills 状态不安全，需要人工恢复。
