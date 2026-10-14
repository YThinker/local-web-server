# LocalWeb — iOS 本地静态服务器（自用，不上架）

在 iPhone / iPad 上跑一个只监听 `127.0.0.1` 的静态文件服务器，并用内置 WKWebView 打开它。
用来预览「一个 index.html + 若干 js 文件」的前端文件夹 —— 因为是 `http://` 而不是 `file://`，
所以 **ES Module、fetch、CORS、Service Worker 全都正常**。

零第三方依赖，只用 `Network.framework` + `WKWebView`。

---

## 为什么需要它

把 index.html 直接丢进「文件」App 用 Safari 打开，是 `file://` 协议，会遇到：

- `<script type="module">` 因为跨源被拦，直接报 CORS 错误
- `fetch('./data.json')` 失败
- 相对路径的资源加载行为诡异

起一个本地 HTTP 服务就全部解决了。

---

## 功能

| 功能 | 说明 |
|---|---|
| 本地 HTTP 服务 | 默认只绑 `127.0.0.1`，端口 8080 起自动找空闲端口 |
| 内置浏览器 | 页面在 App 内加载，切后台不断连（这是它比 a-Shell 强的地方） |
| 目录选择 | 可从「文件」App 里挑任意文件夹（iCloud 云盘 / 本机），会记住授权 |
| 文件共享 | App 的文件夹会出现在「文件」→「我的 iPhone」→「LocalWeb」 |
| 局域网开关 | 默认关闭；打开后同 Wi-Fi 的电脑/平板也能访问，会显示可访问地址 |
| 目录索引 | 访问没有 index.html 的目录时自动生成列表页 |
| 完整的 MIME 表 | html/js/mjs/css/json/wasm/svg/字体/媒体等 |

支持 `GET` / `HEAD`，做了 `..` 路径穿越防护。

---

## 怎么装到自己手机上

### 1. 打开工程

```
open LocalWeb.xcodeproj
```

需要 Xcode 15 以上（工程用的是 Xcode 16+ 的文件夹同步格式，已在 Xcode 26.5 上验证通过）。

### 2. 配置签名

Xcode 里选中左侧 **LocalWeb** 项目 → **Signing & Capabilities**：

- 勾上 **Automatically manage signing**
- **Team** 选你的 Apple ID（没有的话：Xcode → Settings → Accounts → 加一个普通 Apple ID 即可，**免费**）
- **Bundle Identifier** 改成一个全球唯一的，比如 `com.你的名字.localweb`

> 免费 Apple ID 也能装到真机，只是签名 **7 天后过期**，到期重跑一次 Xcode 就行。

### 3. 装到手机

1. iPhone 用数据线连上 Mac，手机上点「信任此电脑」
2. Xcode 顶部设备选择器里选中你的 iPhone
3. 按 `⌘R`
4. 手机上首次会提示「不受信任的开发者」→ 设置 → 通用 → VPN与设备管理 → 信任你的 Apple ID

### 4. 放你的前端文件

方式 A（推荐）：手机「文件」App → 我的 iPhone → **LocalWeb** → 把 `index.html` 和 js 文件拷进去。
（可以先在 Mac 上 AirDrop 整个文件夹到手机，再拖进这个目录）

方式 B：App 里点「选择文件夹…」，直接指向 iCloud 云盘或本机的任意文件夹。

### 5. 打开

App 里点「打开页面」。地址是 `http://127.0.0.1:8080/`。

---

---

## 打包成安装包（IPA）

已经打好了：**`LocalWeb-unsigned.ipa`**（122 KB，arm64）。重新生成跑 `./make-ipa.sh`。

### 先说清楚一个绕不过去的限制

**iOS 上不存在「一个 IPA 装遍所有设备」这回事。** 系统在启动 App 前会校验签名，
签名必须是这台设备信任的证书。所以 IPA 只是个**容器**，能不能装、装完能活多久，
完全取决于你用**什么签名**去装它 —— 跟打包方式无关。

### 四种安装方式对比

| 方式 | 要连电脑吗 | 有效期 | 说明 |
|---|---|---|---|
| Xcode 无线调试 | 首次配对要，之后不用 | 7 天 | 最省事。数据线配对一次，之后 `⌘R` 走 Wi-Fi |
| **Sideloadly** | 首次要，之后可无线 | 7 天 | 免费，Win/Mac。直接拖这个 IPA 进去，填 Apple ID 即可签名安装 |
| **SideStore** | 仅首次 | 自动续签 | 装好后手机上自动续签，不用再碰电脑 |
| **AltStore** | 需要 | 自动续签 | 靠电脑上的 AltServer 续签，电脑要常开 |
| **TrollStore** | 完全不用 | **永久** | 见下方限制 |
| 付费开发者账号 | 不用 | 1 年 | $99/年，可走 Ad Hoc / TestFlight |

### 免费 Apple ID 的硬限制（Apple 官方）

- 每台设备**最多同时装 3 个**自签 App
- 描述文件**发布后 7 天过期**，过期后 App 打不开，必须重新签名安装

### TrollStore —— 唯一能永久安装的路

前提是你的 **iOS 版本在支持范围内**：`14.0 beta 2 – 16.6.1`、`16.7 RC (20H18)`、`17.0`。

官方明确写了：**16.7.x（除 16.7 RC）和 17.0.1 及以上永远不会被支持。**
所以如果你的手机是新系统，这条路直接断了，别浪费时间。

符合条件的话，装好 TrollStore 后，把 `LocalWeb-unsigned.ipa` 用 AirDrop 发到手机、
点一下用 TrollStore 打开就装好了，**永久有效、不用续签、不用电脑**。
装完记得在 TrollStore 设置里配好 Persistence Helper，否则图标缓存刷新后 App 会失效。

### 不推荐的路子

网上那些「企业签名」「共享证书」的第三方商店（各类签名平台），用的是被滥用的企业证书。
苹果会批量吊销，装完过几天集体失效，而且证书持有方能给你的 App 注入任意代码。
自用工具没必要冒这个风险。

---

## 不想编译？现成的免费 App

如果只是想临时跑一下、不介意折腾，App Store 上有两个免费的：

**a-Shell**（推荐，免费，无需越狱）

```
pickFolder            # 选中你的前端文件夹
cd 进去
python3 -m http.server 8080
```

然后 Safari 打开 `http://localhost:8080`。

> 缺点：切到 Safari 后 iOS 会挂起 a-Shell，服务可能中断。首屏资源加载完还能看，
> 但后续的动态 `fetch` 会失败。这也正是我做这个 App 的原因。

**iSH**（免费，Alpine Linux 模拟）

```
apk add python3
cd /mnt/你的目录
python3 -m http.server 8080
```

> 缺点：x86 模拟，慢；同样有后台挂起问题。

---

## 代码结构

```
LocalWeb/
├── LocalWeb-unsigned.ipa     打好包的安装文件（122 KB, arm64）
├── make-ipa.sh               重新打包脚本
├── LocalWeb.xcodeproj/
└── LocalWeb/
    ├── LocalWebApp.swift     入口
    ├── ContentView.swift     主界面 + 文件夹选择器 + 内置浏览器页
    ├── AppModel.swift        状态管理、目录切换、示例站点、Wi-Fi 地址
    ├── HTTPServer.swift      基于 Network.framework 的 HTTP/1.1 服务器
    ├── BrowserView.swift     WKWebView 的 SwiftUI 封装
    └── Info.plist            ATS 例外、文件共享开关
```

### 调试钩子

带环境变量启动可以让 App 自动打开页面，方便回归测试：

```bash
SIMCTL_CHILD_LOCALWEB_OPEN_BROWSER=1 xcrun simctl launch <device-udid> com.localweb.app
```

---

## 已验证

- iOS 模拟器（iPhone 17 / iOS 26.5）Debug 编译 + 真机 arm64 Release 编译，均通过
- 实测：ES Module 跨文件 import 正常、`fetch('./data.json')` 正常返回、404 正常、MIME 类型正确
- 实测：服务只监听 `127.0.0.1`，不会和本机其他服务抢端口，也不会触发本地网络授权弹窗
