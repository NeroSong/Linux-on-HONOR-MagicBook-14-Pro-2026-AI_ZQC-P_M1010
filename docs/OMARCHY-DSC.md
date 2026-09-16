# Omarchy 内屏 DSC 修复及维护记录

验证日期：2026-09-16。机器：HONOR ZQC-P / M1050；目标内核：`7.2.5-3-omarchy`。

## 问题与最终行为

内屏在 3120×2080、120 Hz 下，无压缩链路只能容纳 18 bpp。原驱动允许降至每色 6 位并开启抖动，因此没有进入 DSC 尝试路径。补丁在内屏支持更高色深且具备 DSC 能力时优先尝试压缩；不直接改变外接 DP/HDMI 的选择条件。

本机正常启动入口实测从 **18 bpp、dither=yes、DSC=no** 改善为 **24 bpp、dither=no、DSC=yes**；刷新率仍为 120 Hz。桌面输出格式为 XRGB8888。实际验证到每色 8 位，不宣称端到端 10 位或 HDR。

优化原补丁的失败回退：保存并恢复完整 `dsc` 状态和 `fec_enable`。原来的 `intel_dp_dsc_reset_config()` 不清除 `compression_enabled_on_link`，在 DSC 计算成功而后续 dotclock 检查失败时会留下压缩标志。保留原作者署名，并在补丁说明中区分本地修改。

## 上次黑屏的原因与构建约束

普通 Linux 源码编译出的 xe 遗漏了 Omarchy 的 DRM 公共结构修改。事故模块读取 `drm_crtc.state` 的偏移为 `0x5c8`，而当前原生内核使用 `0x5d8`；仅匹配 vermagic 和 Module.symvers 无法防止这种 ABI 不兼容。

新路径在 `lib/xe-build.sh` 中单独处理 Omarchy，绝不回退到 vanilla 构建：

1. 按已安装的 linux-omarchy 包版本定位官方 PKGBUILD，核验内核归档和全部发行版补丁的校验和。
2. 非 root 构建，保留目标内核配置及工具链要求；BTF 使用目标包的 vmlinux，而不是可能属于旧内核的 sysfs BTF。
3. 加入 DSC 之前，核对共有头文件、不含 DSC 的基线四个可执行代码段和导入符号集合。
4. 通过后才加入 DSC、编译并安装；缓存绑定内核版本、原生模块、配置、vmlinux、Module.symvers、补丁及产物哈希。
5. 配方、工具链、配置、基线或补丁不匹配时停止安装，不以一个“版本号看起来正确”的模块覆盖系统驱动。

当前官方源码提交：`7b11c97603dd9d751d803746560ee51640709725`。

当前本机验证的模块：

- srcversion：`EB6B9F5D6EFDBC933EBAB2B`
- 压缩模块 SHA-256：`2b098eeb54a438963f33c18d98f717e9b943afd753475dd8e1f5a3af22062fb3`

## 安装与升级流程

`patch/edp-dsc/install.sh` 在 Omarchy 上转入 `install-omarchy.sh`。该路径要求先配置 `/etc/honor-autorebuild.conf` 中的非 root `BUILD_USER`、`DSC_CACHE` 和可选的 `DSC_TOOLCHAIN`；`REPO` 指向本仓库。新机器可先运行 `patch/auto-rebuild/install.sh` 配置钩子，再运行 DSC 安装器。构建依赖需与目标内核匹配；本机缺少的 Rust 源码及 bindgen 使用已验证发行版签名的包解压到独立目录，没有替换系统软件。

`85-honor-edp-dsc.hook` 同步运行，位于发行版的 `90-mkinitcpio-install.hook` 之前。构建结束后再由系统生成启动镜像，避免后台任务尚未完成就结束更新。仅维护 edp-dsc；旧的 95 整组后台重建钩子保持禁用。构建失败会显示在更新输出及 `/var/log/honor-autorebuild.log` 中，后续系统 initramfs 流程仍会执行。

本地 M1050 配置已移除 `cdclk-ptl`、`headset-mic`、`sof-audio`：当前 Omarchy 已内置 CDCLK 和 SOF 修复，耳麦补丁按用户决定停用。蓝牙耳机与外放正常不代表 3.5 mm 麦克风已经验证。其他主板配置不变。

未恢复热键模块自动覆盖；触摸板 ACPI/HID-BPF、DKMS 和指纹继续使用原有各自的机制。内核安装器不会重载当前 xe 或自动重启。

## 验证结果

- 官方内核归档及 91 个发行版补丁校验通过。
- 完整内核配置一致，7,140 个共有头文件逐字节一致。
- 基线主 `.text` 与发行版原生 xe 逐字节一致；登记缓存时另核对 `.init.text`、`.exit.text`、`.static_call.text` 及导入符号。
- 抽取实际修改函数、以硬件调用桩执行的 10 个策略和失败分支测试通过；原 reset-only 回退在相同测试中失败。此测试不等于硬件验收。
- 内核模块编译通过；独立测试入口与正常入口均完成真实重启验收，DSC 自动开启、8 位色深且无抖动。
- 正常启动镜像解包核实优化 xe、触摸板 ACPI SSDT 和 VBT；未发现本次验收启动的 GPU 超时或 DRM 崩溃，系统无失败服务。
- 专用更新钩子以当前验证缓存测试通过：重复内核目标去重，旧 Arch 内核目标跳过。
- 已清理临时 DSC 测试/原生恢复菜单项及对应 EFI 镜像，归档备份留在本机；正常新旧内核入口保留。
- `tools/selftest.sh` 与 `git diff --check` 通过；ShellCheck 未安装，相关检查跳过。

## 尚未解决与适用范围

**睡眠后外屏仍无法正常连接。** 初次外屏连接正常，但不能据此排除 DSC 与睡眠问题的相互影响。该提交不声称修复外屏恢复，也不声称完成所有机型的回归验证。

新的自动构建器完整冷构建路径并未在一次真实的未来内核升级中验收；已验证的是当前版本完整源码构建、缓存登记/复用、安装和钩子集成。未来源码或工具链变化可能触发保护而停止补丁安装，届时需要查看日志并适配。

源码解析目前限定已审查的稳定内核 PKGBUILD 格式，并最多查询最近 60 次配方修改；未知格式不猜测。构建源码和失败产物留在缓存父目录便于诊断，需自行维护磁盘占用。此本地维护方案不是 Omarchy 或 Linux 上游已接受的通用补丁。
