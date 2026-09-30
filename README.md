# iStoreOS Tailscale Updater

解掉 iStore 商店 Tailscale 卡在 **1.80.3-1** 的问题。

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

当前最新稳定版：**1.102.4**。

## 交付物

| 文件 | 说明 |
| --- | --- |
| `tailscale-update.sh` | 核心更新脚本，任何 iStoreOS 都能直接跑（推荐） |
| `luci-app-tailscale-updater/` | LuCI / iStore 商店版源码（菜单项 + 页内“一键更新”） |
| `app-meta-tailscale-updater/` | iStore 目录元包 Makefile（要进 iStore 列表用） |
| `build-ipk.sh` | **不用 SDK** 直接打出可安装的 `.ipk` |
| `dist/luci-app-tailscale-updater_1.0.0-1_all.ipk` | 已构建好的安装包 |

## 下载

- 安装包：[Releases](https://github.com/xialiu000/istoreos-tailscale-updater/releases)（或仓库里的 `dist/luci-app-tailscale-updater_1.0.0-1_all.ipk`）
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
tailscale-update -v 1.102.4       # 指定版本
tailscale-update --dry-run        # 只打印将要执行的动作
tailscale-update --rollback       # 回滚到最近一次备份
tailscale-update --list-backups   # 查看备份
tailscale-update --check --json   # 机器可读状态
```

其它参数：`-f/--force` 强制重装、`--base-url <url>` 换下载镜像、`--no-hold`、`--bindir`、`--workdir`。

流程：探测架构 → 取最新版本 → **校验 sha256** → 备份 → 停服务 → 替换二进制 → 起服务 → `tailscale version` 复核（**不一致自动回滚**）。

---

## 方式 B：LuCI / iStore 商店版

装上后：LuCI 菜单出现 **服务 → Tailscale 更新**，页面里显示“已安装 / 最新 / 架构 / 是否可更新”，一个 **立即更新到最新版** 按钮，外加 **检查更新** 和 **回滚**，下面是实时日志。更新在后台跑（不会卡住页面），完成后自动刷新状态。

### B1. 直接用现成的 ipk

```sh
# 生成 dist/ 下的两个包（本仓库已构建好）
./build-ipk.sh

scp dist/luci-app-tailscale-updater_1.0.0-1_all.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'opkg install /tmp/luci-app-tailscale-updater_1.0.0-1_all.ipk'
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

- **包管理器里版本号仍显示 1.80.3-1**：`opkg`/`apk` 清单没变，变的只是磁盘二进制。脚本会给 `opkg` 打 `hold`；`apk` 无 hold，若日后 `apk upgrade` 覆盖，重跑一次即可。
- 只替换二进制、不动配置与登录状态，iStore 的 “Tailscale” 界面（`luci-app-tailscaler`）继续可用。
- 需要约 40 MB 下载 + 解压峰值约 150 MB 空闲空间；内核需有 `/dev/net/tun` + `kmod-tun`（iStoreOS 默认有）。
- 出问题随时 `tailscale-update --rollback`。

## 已验证

在对标 iStoreOS 同构路径上做过端到端测试：

- `--check` / `--check --json` / `--dry-run` 输出正确
- 模拟 1.80.3 → 下载、sha256 校验、解压、安装、复核得到 **1.102.4**
- `--rollback` 成功还原到 1.80.3
- `--start`（LuCI 用的后台模式）→ `status=done, rc=0`，版本已升到 1.102.4
- `build-ipk.sh` 产出的 `.ipk`：外层为 **gzip(tar(./debian-binary, ./data.tar.gz, ./control.tar.gz))**，与 iStore 官方仓库里的 ipk 容器格式一致；control/data 清单与权限正确
- 另出一份 `-ar.ipk` 供标准 OpenWrt opkg

> LuCI 页面的交互（按钮 → rpcd 执行 → 轮询日志）需在真实设备上做最终点击验证；脚本后端逻辑已测通。

## License

MIT — 见 [LICENSE](./LICENSE)。
