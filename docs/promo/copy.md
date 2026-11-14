# DSH Pocket iOS · 宣传文案

> 规则来自 `skill/上架与宣传/dsh插件/references/copy.md`：**写动机，不写形容词。**
> 每个数字、每个判断都要能验证。

## 一句话（朋友圈）

**主推版**

```
出门在外想看电脑上的 DSH 会话，官方没有手机端，所以写了个 iOS 客户端。
扫码连上，电脑上的会话在手机上接着看。
```

**更短的版本**

```
不想为了看一眼 DSH 的会话去开电脑，于是写了个手机客户端。扫码即连。
```

**为什么这两句能用**

- 说清了替代什么（开电脑）
- 说清了前提（电脑上装插件、扫码）
- 没有形容词，「接着看」就是结果

**被否掉的写法**

| 写法 | 问题 |
| --- | --- |
| 你的 DSH 手机伴侣来了 | 空，没信息 |
| 随时随地管理你的 AI 会话 | 「管理」不对，它就是看/发消息 |
| 全新移动体验，效率提升 300% | 数字无来源 |

## 引导安装

**电脑端（插件）**

```
电脑上装两个包：

dsh plugin --profile desktop add dsh-pocket
dsh plugin --profile desktop add dsh-pocket-ios

装完 DSH 设置里多一个「手机访问（iOS）」，上面有下载二维码。
```

> 注：`dsh-pocket` 提供手机访问服务，`dsh-pocket-ios` 只加那个设置页卡片。
> 两者都要装——这点必须在文案里说，否则用户只装一个是空页面。

**手机端**

```
App Store 搜「DSH Pocket」，或者直接扫设置页那个二维码。
装完扫码连接，不用注册账号。
```

## 公众号 / 长文

**标题建议**

- `DSH 没有手机端，所以我自己写了一个`
- `在手机上打开电脑里的 DSH 会话`

**正文**

> 我白天在电脑上用 DSH 跑任务，晚上出门吃饭时会想看一眼某个会话跑到哪了。
> 为了这个去开电脑、翻终端，很麻烦。
>
> DSH 官方没有手机客户端，`dsh-pocket` 这个插件能让你在浏览器里用手机访问，
> 但在手机上用网页版，键盘弹起来就挡住半个屏幕，图片也看不清。
>
> 所以写了个原生 iOS 客户端。电脑上装插件开入口，手机上扫码连上，
> 会话列表、实时消息、图片、Markdown 都能看，还能直接发消息。
>
> **做了什么**
>
> - 扫码连接：电脑设置页出二维码，手机扫一下就连上，不用输地址密码
> - 原生界面：会话列表、对话、实时流、图片、Markdown 表格，不是网页套壳
> - 断网补发：地铁里发出去的消息存本地，恢复网络自动发
> - 不用重扫码：凭证存 Keychain，重装 App、电脑重启都不用再扫
> - 连不上也能看：内置演示模式，没电脑时能看完整界面
>
> **两条安装路径**
>
> 电脑：`dsh plugin --profile desktop add dsh-pocket dsh-pocket-ios`
> 手机：App Store 搜「DSH Pocket」
>
> 仓库：https://github.com/jqlong17/dsh-pocket-ios
> 插件索引（供 DSH 插件市场）：https://raw.githubusercontent.com/jqlong17/dsh-plugins-ui/main/index.json

## 插件市场卡片用（短描述）

**中文**

```
在 DSH 设置页新增「手机访问（iOS）」：App Store 下载二维码、Tailscale 固定地址与二维码、本机访问密码管理。配合手机上的 DSH Pocket iOS 客户端使用。
```

**英文**

```
Adds a native "Phone access (iOS)" settings page: App Store QR, fixed Tailscale address/QR, and local access-password management. Pairs with the DSH Pocket iOS app on the phone.
```

## 事实核查清单

发布前逐条确认：

- [ ] 「App Store 搜 DSH Pocket」——**目前只上架非大陆区**，大陆用户搜不到。文案对大陆受众要改成「需要非大陆 Apple ID」或先不提 App Store
- [ ] 「扫码即可连」——依赖电脑端装好 `dsh-pocket` 且手机能访问到电脑（局域网/Tailscale/公网）
- [ ] 「断网补发」——已实现，但只在「恢复网络后」补发，不是离线可用
- [ ] 「不用重扫码」——凭证存 Keychain，但**换电脑**要重扫
- [ ] 不写性能数字（内存、启动时间），除非有实测
