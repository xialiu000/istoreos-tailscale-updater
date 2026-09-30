# 提交到 iStore 商店（两个 PR）

iStore 上架需要往两个官方仓库各发一个 PR。本目录里的文件就是**直接拖拽上传**用的。

- 源码仓库（PR 说明里要附）：https://github.com/xialiu000/istoreos-tailscale-updater

---

## PR ①：`linkease/istore-repo`（二进制包仓库）

1. Fork https://github.com/linkease/istore-repo
2. 在 fork 里，从 `main` 建一个临时分支，例如 `add_tailscale_updater`
3. 上传文件到：
   ```
   bin/packages/all/nas_luci/luci-app-tailscale-updater_1.0.0-1_all.ipk
   ```
   （本目录 `istore-repo/` 下已按此路径放好）
4. 发 PR，**目标分支选 `pending`**（不是 main）
5. PR 说明写上：源码地址 + 一句话简介

## PR ②：`linkease/openwrt-app-meta`（上架元数据）

1. Fork https://github.com/linkease/openwrt-app-meta
2. 从 `main` 建临时分支，例如 `add_app_tailscale_updater`
3. 上传整个目录：
   ```
   applications/app-meta-tailscale-updater/Makefile
   applications/app-meta-tailscale-updater/logo.png
   ```
   （本目录 `openwrt-app-meta/` 下已放好）
4. 发 PR（目标 `main`）

---

## 官方规则核对（已满足）

| 规则 | 状态 |
| --- | --- |
| 文件名带版本号、不重名 | ✅ `..._1.0.0-1_all.ipk` |
| 架构无关的包放 `all/` | ✅ `bin/packages/all/nas_luci/` |
| logo ≤ 256×256 且 ≤ 50KB | ✅ 256×256、约 10KB |
| 开源软件在 PR 里附仓库地址 | ⬜ 发 PR 时填 |
| 不提交 OpenWrt 官方已有的包 | ✅ `luci-app-tailscale-updater` 是新包（官方只有 `tailscale`） |

## 备注

- iStore 目前只收 **aarch64 / x86_64**；本插件是架构无关（`Architecture: all`），放 `all/` 即可。
- 若以后要同时支持 **apk** 版 iStoreOS，需要额外构建 `.apk` 并放到 `bin/apks/...`（目前只出了 ipk）。
- 两个 PR 合并后，iStore 里就能搜到「Tailscale 更新」。
