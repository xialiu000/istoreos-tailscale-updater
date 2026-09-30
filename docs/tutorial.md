# iStoreOS 一键更新 Tailscale 教程（从 1.80.3 升到最新版）

> 适用设备：iStoreOS（x86_64 / arm64 / arm / mips 等）
> 难度：★☆☆☆☆　耗时：约 3 分钟

---

## 一、为什么要做这件事

iStore 商店里的 **Tailscale** 应用，装的其实是 iStoreOS 固件源里**被冻结的版本**，长期停在 **1.80.3-1**。

因为固件源为了稳定性把版本锁死了，所以无论你怎么点商店里的升级、或者 `opkg upgrade`，都升不上去。

本教程用一个小编号工具，把 `tailscale` / `tailscaled` **两个二进制**替换成 Tailscale 官方最新稳定版（当前 **1.102.4**），并且：

- ✅ 保留原有配置文件
- ✅ 保留你的**登录状态**（不用重新登录）
- ✅ 保留 iStore 的 Tailscale 界面

---

## 二、准备工作

1. 一台 iStoreOS 设备，已用 iStore 装好 Tailscale（否则没什么可更新的）。
2. 能访问 `pkgs.tailscale.com`（国内网络可能偏慢，耐心等）。
3. 电脑或路由器能 SSH 登录路由器（默认用户 `root`）。

---

## 三、方法一：LuCI / iStore 一键更新（推荐）

### 第 1 步：下载更新工具包

从下面的地址下载 `luci-app-tailscale-updater_1.0.0-1_all.ipk`：

> 【这里放你的下载链接：仓库 / 网盘】

### 第 2 步：安装

把 ipk 上传到路由器 `/tmp/`，然后 SSH 执行：

```sh
opkg install /tmp/luci-app-tailscale-updater_1.0.0-1_all.ipk
```

> 第一次安装会自动重载 LuCI，几秒后菜单就出来了。

【截图 1：安装成功的终端输出】

### 第 3 步：打开更新页面

刷新浏览器，进入 **服务 → Tailscale 更新**。
（也可以在 iStore 里找到「Tailscale 更新」，点「打开」。）

【截图 2：LuCI 菜单入口】

页面会自动检查，显示：

- 已安装版本
- 最新稳定版
- 设备架构
- 是否可更新

【截图 3：检查结果页面】

### 第 4 步：一键更新

点 **「立即更新到最新版」**，后台自动下载、校验、替换，页面下方会**实时打印日志**：

```
[i] arch=arm64  installed=1.80.3  target=1.102.4
[i] downloading tailscale_1.102.4_arm64.tgz
[+] checksum ok
[+] backup saved to /etc/tailscale/.update-backup/...
[+] now running Tailscale 1.102.4
[+] Tailscale updated to 1.102.4
```

【截图 4：更新中的日志】

完成后状态变成「已是最新」，并提示「Tailscale 更新完成」。

【截图 5：更新完成】

### 第 5 步（可选）：回滚

万一有问题，点页面上的 **「回滚」** 即可还原到上一个版本。

---

## 四、方法二：SSH 命令行更新（进阶 / 无界面）

不想装 LuCI 插件，也可以直接用脚本：

```sh
# 下载脚本到路由器
wget -O /usr/bin/tailscale-update 【脚本下载链接】
chmod +x /usr/bin/tailscale-update

# 先看：已装 vs 最新
tailscale-update --check

# 一键更新
tailscale-update -y
```

其它常用命令：

```sh
tailscale-update -v 1.102.4   # 更新到指定版本
tailscale-update --rollback   # 回滚
tailscale-update --dry-run    # 只看会做什么，不真改
```

---

## 五、验证是否成功

在 SSH 里执行：

```sh
tailscale version
```

看到 `1.102.4`（或你想要的目标版本）就成功了。再确认服务正常：

```sh
tailscale status
```

---

## 六、常见问题

**Q1：安装时提示 `Malformed package file`？**
装错包了。iStoreOS 用的是 `gzip(tar)` 格式的 ipk，注意别装成 `-ar.ipk` 那个（那是给标准 OpenWrt 的）。

**Q2：装完在 LuCI 里找不到「Tailscale 更新」菜单？**
rpcd 还没重载。SSH 执行一次：
```sh
rm -f /tmp/luci-indexcache.*; rm -rf /tmp/luci-modulecache/; /etc/init.d/rpcd reload
```
然后刷新浏览器（`Ctrl+F5`）。

**Q3：点了更新，日志一直是"等待日志"？**
稍等几秒；若一直不动，把页面日志区的报错内容发出来定位。

**Q4：更新后 iStore 里还显示 1.80.3-1？**
正常。包管理器里的版本号不会变，变的只是磁盘上的二进制，实际运行的是新版本（用 `tailscale version` 验证）。脚本已给 `opkg` 打了 `hold`，防止被覆盖。

**Q5：想换下载源/网络慢？**
命令行版支持 `--base-url` 指定镜像。

---

## 七、原理与安全性

- 只替换 `/usr/sbin/tailscale`、`/usr/sbin/tailscaled` 两个文件；
- **不改** 启动脚本 `/etc/init.d/tailscale`、配置 `/etc/config/tailscale` 和登录状态 `/etc/tailscale/tailscaled.state`；
- 下载的官方包会做 **sha256 校验**，校验不过拒绝安装；
- 更新前**自动备份**，出错或版本不符会**自动回滚**。

---

## 八、下载地址

- 更新工具包（ipk）：【链接】
- 命令行脚本：【链接】
- 项目地址：【链接】

如果这个教程帮到了你，欢迎在 iStore 共创活动中支持一下～
