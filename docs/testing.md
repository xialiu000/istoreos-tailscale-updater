# 干净安装测试流程（每版必跑）

目标：排除“升级残留”和“测试残留”，确保新装的用户第一次打开页面时状态正确。

## 前置

- 设备已安装社区版 Tailscale（示例 1.104.1）
- 有上一版本 updater 的 ipk 或本地构建环境
- 记录当前 Tailscale 版本、登录状态文件：`/etc/tailscale/tailscaled.state`

## 1. 把 Tailscale 降到目标基线版本

优先使用 updater 的备份（`/etc/tailscale/.update-backup/<ts>/`）：

```sh
/etc/init.d/tailscale stop
B=/etc/tailscale/.update-backup/<ts>
cp -f "$B/tailscaled" /usr/sbin/tailscaled
chmod 0755 /usr/sbin/tailscaled
ln -sf tailscaled /usr/sbin/tailscale
/etc/init.d/tailscale start
tailscale version            # 期望 1.104.1
opkg status tailscale | grep Version
```

## 2. 彻底卸载 updater

```sh
/usr/libexec/tailscale-update --set-auto 0 2>/dev/null || true
opkg remove luci-app-tailscale-updater
rm -f /etc/config/tailscale-updater
rm -f /usr/libexec/tailscale-update
rm -f /www/luci-static/resources/view/tailscale-updater.js
sed -i '/tailscale-update --auto/d; /tailscale-updater auto-update/d' /etc/crontabs/root
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
```

确认：

```sh
opkg list-installed | grep tailscale-updater || echo clean
ls /etc/config/tailscale-updater 2>/dev/null || echo no-config
```

## 3. 安装待测 ipk

```sh
opkg install /tmp/luci-app-tailscale-updater_<ver>_all.ipk
```

## 4. 首启断言（关键）

```sh
tailscale-update --check --json
```

必须满足：

- `mode` = `pkg`（社区版）
- `installed` = 基线版本（如 1.104.1）
- `update_source` = `feed`
- `auto_update` = `false`
- `cron_installed` = `false`
- `candidate` = 软件源最高版本（可能低于已装）
- `update_available` = `false`（源里没有更高版本时）

并且：

- `/etc/config/tailscale-updater` 不存在（或 auto_update=0）
- `/etc/crontabs/root` 没有 tailscale-update 行
- LuCI 页面「自动更新」未勾选，「定时任务」显示未启用

## 5. 开关测试

```sh
tailscale-update --set-auto 1 03:15
tailscale-update --check --json      # auto_update=true, cron_installed=true
cat /etc/crontabs/root               # 有且仅有一行 --auto

tailscale-update --set-auto 0
tailscale-update --check --json      # auto_update=false, cron_installed=false
cat /etc/crontabs/root               # 没有 --auto 行，其它任务保留
```

## 6. 来源切换测试

```sh
tailscale-update --set-source official
tailscale-update --check --json      # mode=official, latest=官方最新（如 1.104.5）

tailscale-update --set-source feed
tailscale-update --check --json      # mode=pkg（源里候选可能低于已装）
```

## 7. 记录

把每版的以下内容记录到 PR/发布说明：

- 基线 Tailscale 版本
- updater 版本
- 首启 JSON
- 开关前后 cron 内容
- 来源切换前后 mode/latest
