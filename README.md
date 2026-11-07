# iStoreOS Tailscale Updater

解决 iStoreOS 上 Tailscale 的更新问题，**自动识别两种安装方式**：

- **旧版**：iStore 商店「Tailscale」（冻结在 **1.80.3-1**）——替换官方静态二进制。
- **社区版**：商店「Tailscale（社区版）」/ OpenWrt feed 的 `tailscale` 包——通过 `opkg`/`apk` 升级软件包，不再碰二进制，也不会锁住官方升级。

两种模式都保留 `/etc/init.d/tailscale`、`/etc/config/tailscale` 和登录状态。LuCI 页面新增**自动更新**开关（每天定时检查，有新版才更新）。

## 背景（为什么会卡在 1.80.3-1）

iStore 商店里的 “Tailscale” 应用本身只是个**元包**：

```
applications/app-meta-tailscale/Makefile
  PKG_VERSION:=0.0.6
  META_DEPENDS:=+tailscaled +tailscale +luci-app-tailscaler
```

真正的 `tailscaled` / `tailscale` 二进制来自**固件被冻结的软件源**（iStoreOS 为稳定性把版本锁死，见 linkease/istore-packages 的说明：“缓存一些软件包，以避免插件的未知更新改动带来固件不稳定”）。所以 `opkg upgrade` / `apk upgrade` 也升不上去。

本工具的做法：**只替换这两个二进制**，换成 Tailscale 官方静态构建（[pkgs.tailscale.com/stable](https://pkgs.tailscale.com/stable/)），保留：

- `/etc/init.d/tailscale`（procd 启动脚本，含 `--state`、`--port`、nftables 模式）
- `/etc/config/tailscale`（UCI 配置）
- `/etc/tailscale/tailscaled.state`（**登录状态，不会被重置**）

当前最新稳定版可在脚本 `--check` 中查看（会随官方发布变化）。

## 工作模式（自动识别）

| 检测结果 | 触发条件 | 更新方式 | 是否 hold |
| --- | --- | --- | --- |
| `static` 旧版 | 装有 `tailscaled` 包，或 `tailscale` 包版本 ≤ 1.80.3 | 下载官方静态包、校验 sha256、替换 `/usr/sbin/tailscale*` | 是（防止冻结源覆盖） |
| `pkg` 社区版 | `tailscale` 包版本 > 1.80.3（feed 维护） | `opkg update && opkg install tailscale` / `apk update && apk add --upgrade tailscale` | 否（保持官方升级通道） |

可用 `--mode auto|static|pkg` 强制覆盖自动检测。

### 关于「Tailscale（社区版）」

- 二进制来自 [GuNanOvO/openwrt-tailscale](https://github.com/GuNanOvO/openwrt-tailscale)：**单个 UPX 压缩的 `/usr/sbin/tailscaled`**，`/usr/sbin/tailscale` 只是指向它的符号链接（`PROVIDES:=tailscale tailscaled`）。
- 编译参数包含 `ts_omit_clientupdate`，所以 **`tailscale update` 不可用**；升级只能走 `opkg`/`apk` 的软件源（iStore 源或 GuNanOvO/社区源）。
- iStore 里的社区版会**锚定**在某个版本（例如 1.104.1）。如果源里没有更高版本，包管理器不会“凭空”升级——需要先添加作者的软件源。
- **社区版本身没有自动更新功能**；本工具的「自动更新」开关就是补这一块：每天定时 `--auto`，有候选版本才升级。

### 社区版：选择更新来源

社区版装好后，LuCI 页面会出现「更新来源」：

| 来源 | 行为 | 适用 |
| --- | --- | --- |
| 社区软件包（默认） | `opkg/apk` 升级 `tailscale` 包 | 已配置社区源，想跟随 GuNanOvO 构建 |
| 官方 Tailscale 静态包 | 从 pkgs.tailscale.com 下载官方静态二进制，替换 `tailscaled` / `tailscale`，并 `hold` 住 `tailscale` 包 | 想直接跟官方版本（如 1.104.5），不依赖社区源 |

切回「社区软件包」时会自动清除 `opkg hold`。选官方静态包后，`opkg upgrade tailscale` 被 hold 挡住；要恢复社区更新，先切回 feed。

## 交付物

| 文件 | 说明 |
| --- | --- |
| `tailscale-update.sh` | 核心更新脚本，任何 iStoreOS 都能直接跑（推荐） |
| `luci-app-tailscale-updater/` | LuCI / iStore 商店版源码（菜单项 + 页内“一键更新”） |
| `app-meta-tailscale-updater/` | iStore 目录元包 Makefile（要进 iStore 列表用） |
| `build-ipk.sh` | **不用 SDK** 直接打出可安装的 `.ipk` |
| `dist/luci-app-tailscale-updater_1.1.3-1_all.ipk` | 已构建好的安装包 |

## 下载

- 安装包：[Releases](https://github.com/xialiu000/istoreos-tailscale-updater/releases)（或仓库里的 `dist/luci-app-tailscale-updater_1.1.3-1_all.ipk`）
- 命令行脚本：[`tailscale-update.sh`](./tailscale-update.sh)
- 图文教程：[`docs/tutorial.md`](./docs/tutorial.md)

> 本项目**非 Tailscale 官方项目**。"Tailscale" 是 Tailscale Inc. 的商标，本项目只是调用其官方发布的二进制。

---

## 方式 A：命令行脚本（最简单）

在路由器 SSH 里：

```sh
wget -O /usr/bin/tailscale-update \
  https://raw.githubusercontent.com/xialiu000/istoreos-tailscale-updater/main/tailscale-update.sh
chmod +x /usr/bin/tailscale-update
tailscale-update --check      # 先看：已装 vs 最新
tailscale-update -y           # 一键更新
```

命令：

```sh
tailscale-update --check          # 只看，不改动
tailscale-update                  # 更新到最新稳定版（先确认 y/N）
tailscale-update -y               # 免确认
tailscale-update -v 1.104.5       # 指定版本
tailscale-update --dry-run        # 只打印将要执行的动作
tailscale-update --rollback       # 回滚到最近一次备份
tailscale-update --list-backups   # 查看备份
tailscale-update --check --json   # 机器可读状态（含 mode / auto_update）
tailscale-update --auto           # 自动更新一次（cron 用）
tailscale-update --set-auto 1 03:00   # 开启每天 03:00 自动更新
tailscale-update --set-auto 0         # 关闭自动更新
tailscale-update --set-source official  # 社区版：改用官方静态包
tailscale-update --set-source feed      # 社区版：改回 opkg/apk 社区源
tailscale-update --official           # 本次强制走官方静态包
```

其它参数：`-f/--force` 强制重装、`--base-url <url>` 换下载镜像、`--no-hold`、`--bindir`、`--workdir`、`--mode auto|static|pkg`。

流程（static）：探测架构 → 取最新版本 → **校验 sha256** → 备份 → 停服务 → 替换二进制 → 起服务 → `tailscale version` 复核（**不一致自动回滚**）。

流程（pkg）：刷新软件源 → 比较已装/候选版本 → 记录检查点 → 停服务 → `opkg`/`apk` 升级 → 起服务 → 复核版本。

---

## 方式 B：LuCI / iStore 商店版

装上后：LuCI 菜单出现 **服务 → Tailscale 更新**，页面里显示“已安装 / 更新方式 / 最新（或软件源候选）/ 架构 / 是否可更新”，并提供 **自动更新** 开关（可设每天执行时间）。按钮为 **立即更新**、**检查更新**、**回滚**，下面是实时日志。更新在后台跑（不会卡住页面），完成后自动刷新状态。

### B1. 直接用现成的 ipk

```sh
# 生成 dist/ 下的两个包（本仓库已构建好）
./build-ipk.sh

scp dist/luci-app-tailscale-updater_1.1.3-1_all.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'opkg install /tmp/luci-app-tailscale-updater_1.1.3-1_all.ipk'
```

> **⚠ 两种 ipk 容器格式**：
> - `..._all.ipk` = **gzip(tar)**，即经典 ipkg 格式 —— **iStoreOS 要这个**。
> - `..._all-ar.ipk` = **ar** 归档（Debian/deb 那种）—— 标准 OpenWrt opkg 用。
>
> 用错了会报 `pkg_init_from_file: Malformed package file`。iStoreOS 用前者，别装成 `-ar` 那个。

装完刷新 LuCI 即可。包内还带了 iStore 的元数据（`usr/lib/opkg/meta/` 和 `lib/apk/meta/`），所以也会出现在 iStore 的列表里。

> apk 版 iStoreOS（24.10+）：apk 包需要签名，`build-ipk.sh` 只出 opkg 的 `.ipk`。用 apk 的设备请走 B2 的 SDK 编译，或直接用方式 A 的脚本。
>
> 判断你设备用哪种容器：看 iStore 仓库里的 ipk（`file xxx.ipk`）。iStoreOS 官方仓库（linkease/istore-repo）里全是 gzip(tar) 格式，所以 iStoreOS 认这个。

### B1b. 在 iStore 里“一键更新”

iStore 的 App 卡片只有「打开/卸载」按钮，没有自定义命令按钮机制（见 `linkease/istore` 的 `store.lua`：元数据只有 `entry` / `flags(entrysh)` / `autoconf` / `uci`）。
所以“一键”的做法是：把 App 的 `entry` 指向 `…/tailscale-updater?run=1`，iStore 的「打开」即自动检查并更新。

- iStore 读元数据的目录：`/tmp/run/istore-meta/meta/*.json`（启动时 `is-opkg link_meta` 把它软链到 `/usr/lib/opkg`）。
- 本包已把元数据写到 `/usr/lib/opkg/meta/tailscale-updater.json`，所以 iStore 的「已安装」里会出现「Tailscale 更新」。
- 强制刷新：`rm -f /tmp/cache/istore/installed.json`，再刷新 iStore 页面。
- 验证：`ls -l /tmp/run/istore-meta/meta/ | grep tailscale`。

### B2. SDK 编译（要进官方 iStore 目录）

```sh
# 放进 OpenWrt / iStoreOS SDK
cp -r luci-app-tailscale-updater $SDK/package/
make package/luci-app-tailscale-updater/compile V=s
make package/luci-app-tailscale-updater/install V=s

# 若要出现在 iStore 商店列表，把 app-meta-tailscale-updater/
# 放进 https://github.com/linkease/openwrt-app-meta 的 applications/ 下一起编译
```

---

## 架构支持

`amd64 / arm64 / arm / mips / mipsle / mips64 / mips64le / riscv64 / 386`。
脚本优先读 apk/opkg 的架构串（`aarch64_*`、`arm_*`、`mipsel_*`、`x86_64`…）再回退 `uname -m`，不确定可加 `--arch`。

## 注意事项

- **旧版模式下包管理器仍显示 1.80.3-1**：只替换磁盘二进制，`opkg` 清单不会变；脚本会给旧包打 `hold`（`apk` 无 hold，若被覆盖重跑一次即可）。**社区版走包管理器升级，会正常更新清单版本，也不会 hold。**
- 不动配置与登录状态，iStore 的 “Tailscale” 界面（`luci-app-tailscaler`）继续可用。
- **自动更新**：开启后写入 `/etc/config/tailscale-updater` 并在 `/etc/crontabs/root` 增加一条带标记的 cron（只改自己那一行，保留其它任务），日志在 `/tmp/tailscale-update-auto.log`。Tailscale 社区版本身**没有**内置自动升级，需要包管理器或本工具定时执行。
- 需要约 40 MB 下载 + 解压峰值约 150 MB 空闲空间；内核需有 `/dev/net/tun` + `kmod-tun`（iStoreOS 默认有）。
- 出问题随时 `tailscale-update --rollback`。

## 已验证

在对标 iStoreOS 同构路径上做过端到端测试：

- `--check` / `--check --json` / `--dry-run` 输出正确
- 模拟 1.80.3 → 下载、sha256 校验、解压、安装、复核得到 **1.104.5**
- `--rollback` 成功还原到 1.80.3
- `--start`（LuCI 用的后台模式）→ `status=done, rc=0`，版本已升到 1.104.5
- `build-ipk.sh` 产出的 `.ipk`：外层为 **gzip(tar(./debian-binary, ./data.tar.gz, ./control.tar.gz))**，与 iStore 官方仓库里的 ipk 容器格式一致；control/data 清单与权限正确
- 另出一份 `-ar.ipk` 供标准 OpenWrt opkg

> LuCI 页面的交互（按钮 → rpcd 执行 → 轮询日志）需在真实设备上做最终点击验证；脚本后端逻辑已测通。

## License

MIT — 见 [LICENSE](./LICENSE)。
