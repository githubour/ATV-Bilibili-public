# ATV-Bilibili · Apple TV（tvOS）哔哩哔哩客户端

在 Apple TV 上观看哔哩哔哩的**非官方**第三方客户端，派生自开源项目
**[yichengchen/ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo)**，
在其基础上持续打磨播放体验、弹幕与界面。

> 与哔哩哔哩官方无任何关联，仅用于个人学习与研究。本项目以 **GPL-2.0** 分发，详见文末「协议」。
>
> 本仓库是**发布镜像**：日常开发在私有仓库进行，这里按版本同步；**不接受 PR**，欢迎提 Issue。

---

## 环境要求

| 项目 | 要求 |
|---|---|
| 开发机 | macOS + Xcode（最新稳定版） |
| 运行设备 | Apple TV HD / 4K，**tvOS 18.0 及以上** |
| 语言 | Swift 5.0 |
| 签名 | 免费 Apple ID 自动签名即可（描述文件 7 天到期，到期后重新构建安装） |

---

## 构建与安装

### 一键脚本

仓库根目录的 `装机.command`：双击或命令行执行，完成「Release 构建 + 直装真机」。

```bash
xcrun devicectl list devices          # 查 Apple TV 的 UDID（设备名可能显示 ?? ，属正常）

ATV_UDID=00008110-xxxxxxxxxxxxxxxx \
ATV_TEAM_ID=YYYYYYYYYY \
./装机.command
```

可选变量：`ATV_BUNDLE_ID`、`ATV_DISPLAY_NAME`、`ATV_ICON_NAME`（覆盖工程默认值）。
也可以在同目录建 `本机-配置.sh`（已被 `.gitignore` 忽略）写好这些变量，就不用每次传参。

### 手动构建

```bash
xcodebuild -project ATV-Bilibili.xcodeproj \
  -scheme ATV-Bilibili \
  -configuration Release \
  -destination 'platform=tvOS,id=<Apple TV UDID>' \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<你的 Team ID> \
  build

APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'ATV-Bilibili.app' -path '*Release-appletvos*' -print0 | xargs -0 ls -td | head -1)
xcrun devicectl device install app --device <Apple TV UDID> "$APP"
```

**实测踩过的坑：**

- 产物只认 `*Release-appletvos*` 目录；误装模拟器产物会报 `0xe8008014 invalid signature`
- 不要给 `xcodebuild` 指定新的 `-derivedDataPath`，否则会重新解析 SPM 依赖导致构建失败
- Apple TV 待机时安装可能成功但启动被拒，构建前先唤醒电视
- **Xcode 里必须登录 Apple ID**，否则自动签名无法续签描述文件（报 `No Accounts` / `No profiles`）

### 图标与显示名

`APP_BUNDLE_ID` / `APP_ICON_NAME` / `BUNDLE_DISPLAY_NAME` 是工程里的变量挂点，
改它们就能用同一份代码构建出**外观不同、数据互不干扰**的多个 App
（App Group 跟随 Bundle ID 生成，所以各版本的 Top Shelf 数据彼此独立）：

```bash
xcodebuild ... \
  APP_BUNDLE_ID=com.example.myversion \
  BUNDLE_DISPLAY_NAME="我的哔哩哔哩" \
  APP_ICON_NAME="App Icon & Top Shelf Image Blue" \
  build
```

图标资源共三套（`ATV-Bilibili/Supporting Files/Assets.xcassets/`）：粉色为缺省兜底，另有蓝色与黑金。

---

## 相对上游的主要改动

### 播放与画质

- **选流规则集中化**（`BVideoStreamSelection`）：动态范围优先（杜比视界 > HDR > SDR）→ 最高画质档位 → 同档优先 AVC → 同档取最高码率
- 每次请求把**全部 CDN 候选**写进播放列表，由 AVPlayer 择优 —— 单个 CDN 慢或挂掉不再影响起播
- **音轨清单声明补全**：`#EXT-X-MEDIA` 带 `CHANNELS`、variant 的 `CODECS` 带音频编码，杜比全景声作为默认音轨
- 编码故障自动切换（AVC ↔ HEVC）
- **片头 / 片尾标记与自动跳过**：按番剧 / 普通视频持久化；片头绝对秒跨集沿用，片尾按片长换算回推；各带独立自动跳过开关，关闭时区间内常驻手动跳过按钮
- 倍速播放（0.5×–2×，带音调校正）并记住上次选择
- 字幕：菜单手动切换 + 起播自动选中偏好轨道（含 AI 中文字幕）并记忆选择
- SponsorBlock 赞助片段跳过（自动跳转 / 手动提示两种模式）
- 播放诊断浮层（码率、卡顿次数、丢帧）

### 弹幕

- 弹幕防挡（`MaskProvider`，矢量遮罩数据经 PocketSVG 解析）
- 云端屏蔽词同步（关键字 + 正则，默认开启、每日节流刷新）+ 本地自定义屏蔽词
- 字号、显示时长、不透明度等调节
- Protobuf 定义入库 `protos/`，用与运行时同版本的 `protoc-gen-swift` 重新生成

### 播放器内面板与交互

- 长按菜单重排（一键三连、投币、稍后再看、我不想看）
- 选集面板：控制栏浮现时左下角出现横向分集卡，当前集高亮并自动滚动到可见位置
- **B 站官方 AI 视频总结**：摘要与章节大纲，点章节跳转
- 定时关闭；播放器内查看详情与相关推荐
- 侧栏胶囊化（Liquid Glass）与焦点动效收口

### 信息架构

- 可自由排序的 Tab 栏
- 番剧 / 影视等多集内容**固定先进详情页**，不再受「不显示详情页直接播放」影响
- 关注页顶部 UP 主头像条，点击直达其投稿列表
- 推荐流卡片「不感兴趣」反馈（当前视频 / 该 UP 主）
- **Top Shelf**：主屏海报墙（稍后再看 + 最新动态），选中进详情页、播放键直达播放，数据源可在设置页切换或关闭
- 深链：`bilibilitv://video?aid=`（详情页）、`bilibilitv://play?aid=`（直接播放）

### 工程与安全

- 账号凭证（token / cookies）迁移到 **Keychain**（历史版本明文写在 UserDefaults，读取时自动迁移）
- 新增单元测试 target，覆盖选流规则、片头片尾换算、WBI 签名纯函数、LRU 原语、`SettingsKey` rawValue 冻结契约、模型解码
- 性能：列表分页增量 apply、sidx 进程级共享缓存、弹幕主线程收敛、DLNA 降频与延迟启动
- 重构：`WebRequest` 按域拆分、命名统一（`Response` / `Danmaku`）、单文件多类拆出
- 移除：直播模块、TV 推荐功能、`SwiftyXMLParser` 死依赖、CI / fastlane 遗留

### 与上游共享的部分

基础能力几乎全部来自上游：自定义 `AVURLAsset` ResourceLoader 驱动的 MPEG-DASH 播放、
二维码登录与多账号、WBI 请求签名、弹幕渲染引擎接入、评论、内容页（推荐 / 热门 / 排行榜 / 搜索 / 关注 / 历史 / 稍后再看 / 番剧）、
云视听小电视投屏协议与 DLNA、以及播放器「插件化」架构与通用 Feed 基类。

---

## 项目结构

```
ATV-Bilibili/    主 App。Component/ 复用子系统（播放器容器与插件、视频、评论、Feed、
                 焦点控件、TopShelf 同步、Settings）；Module/ 功能页面（Tabbar、我的、
                 内容页、DLNA）；Request/ 网络层与 WBI 签名；Vendor/ DanmakuKit 弹幕引擎
TopShelf/        Top Shelf 扩展 target
protos/          弹幕 Protobuf 定义与重新生成说明
BuildTools/      构建期工具（SwiftFormat）
装机.command      一键真机构建安装
```

**架构要点**

- **DASH 播放**：`BilibiliVideoResourceLoaderDelegate` 拦截注册给 AVPlayer 的 `bilibili://` 地址，拉取真实 DASH manifest、解析 SIDX 分段并改写 URL —— 清晰度选择的核心
- **播放器插件**：`CommonPlayerViewController` 持有若干 `CommonPlayerPlugin`；协议方法均有空默认实现，按需覆写即可挂载弹幕、字幕、AI 总结等能力
- **请求签名**：接口调用同时需要 MD5 签名（`ApiRequest`）与 WBI 签名（`WebRequest+WbiSign`），漏签会直接鉴权失败

---

## 依赖

| 包 | 用途 |
|---|---|
| [Alamofire](https://github.com/Alamofire/Alamofire) | HTTP 网络层 |
| [SwiftProtobuf](https://github.com/apple/swift-protobuf) | 弹幕 Protobuf 解码 |
| [Kingfisher](https://github.com/onevcat/Kingfisher) | 图片加载与缓存 |
| [SnapKit](https://github.com/SnapKit/SnapKit) | Auto Layout |
| [CocoaLumberjack](https://github.com/CocoaLumberjack/CocoaLumberjack) | 日志 |
| [CocoaAsyncSocket](https://github.com/robbiehanson/CocoaAsyncSocket) | DLNA 的 TCP/UDP |
| [GzipSwift](https://github.com/1024jp/GzipSwift) | 压缩流 |
| [MarqueeLabel](https://github.com/cbpowell/MarqueeLabel) | 卡片标题跑马灯 |
| [PocketSVG](https://github.com/pocketsvg/PocketSVG) | SVG 解析（弹幕防挡遮罩） |
| [Swifter](https://github.com/yichengchen/swifter) | 投屏接收用的 HTTP 服务（上游维护的 fork） |

内置源码：`ATV-Bilibili/Vendor/DanmakuKit`（弹幕渲染引擎）及若干通用组件。

---

## 版本戳

每个功能批次结束后更新一次版本戳，构建号取该批次代码提交的 `git rev-list --count`：

- `ATV-Bilibili/BuildInfo.swift`：营销版本、构建号、对应提交短哈希
- 两个 target 的 `Info.plist`：`CFBundleShortVersionString` / `CFBundleVersion`

设置页「关于」可查看电视上实际安装的批次，便于排障时定位版本。

---

## 免责声明

- 本项目为**非官方**客户端，与哔哩哔哩官方无关，仅用于个人学习与研究。
- 本项目**从未在任何平台上架或收费**（包括 App Store 与 TestFlight），也**没有任何授权的 TestFlight 名额或付费版本**。
- 若你在任何平台看到有人以收费方式提供本项目的服务或应用，请注意这是**未经授权**的行为，与本项目原始意图不符；由此引发的任何风险与本项目无关。
- 请遵守哔哩哔哩的用户协议与相关法律法规，不要将本项目用于任何商业用途。

---

## 协议

[GNU General Public License v2.0](LICENSE.md)，派生自同样采用 GPL-2.0 的
[yichengchen/ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo)。

**任何形式的分发（含打包 IPA 提供给他人）都必须保留 GPL-2.0 协议全文与版权声明，并提供完整对应源码。**

---

## 致谢

- [yichengchen/ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo) —— 本项目的上游与基础
- [thmatuza/MPEGDASHAVPlayerDemo](https://github.com/thmatuza/MPEGDASHAVPlayerDemo) —— DASH 播放参考
- [dreamCodeMan/B-webmask](https://github.com/dreamCodeMan/B-webmask) —— 弹幕防挡参考
- [分析 Bilibili 客户端的「哔哩必连」协议](https://xfangfang.github.io/028)
- App Icon 素材来源：[【22娘×33娘】亲爱的UP主，你怎么还在咕咕咕？](https://www.bilibili.com/video/BV1AB4y1k7em)
