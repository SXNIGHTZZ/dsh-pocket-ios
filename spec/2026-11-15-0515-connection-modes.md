# 连接方式切换：Tailscale / Cloudflare / EasyTier

> **Status**: Draft
> **起始日期**：2026-11-15
> **预估工时**：920 分钟（分三期，见文末）
> **文件名**：`spec/2026-11-15-0515-connection-modes.md`

## 背景 / 问题

当前 `dsh-pocket-ios` 插件**只做 Tailscale 一种连接方式**，其余靠第三方 `dsh-pocket` 插件
提供（局域网码 + Cloudflare 公网码）。

由此产生的问题（2026-11-15 用户反馈）：

1. **两套面板、四个二维码，用户分不清该扫哪个**：
   - `dsh-pocket-ios`：App Store 下载码（不能连）+ Tailscale 配对码（需先装 Tailscale）
   - `dsh-pocket`：局域网码 + Cloudflare 公网码
2. **扫错码的后果是「密码错误」**——局域网码不带 token 时手机会停在登录页，
   而密码就印在二维码正下方，用户根本没意识到要输它。
3. **依赖别人的插件**：升级/行为/文案都不受我们控制。

产品决策（用户 2026-11-15 明确要求）：

> 不再依赖 dsh-pocket，我们自己提供三种，默认 Tailscale，
> 二维码上方加小圆点单选切换，新增 EasyTier 作为第三选项。

## 目标与非目标

**目标**
1. 连接面板顶部加**三选一单选控件**（小圆点）：`Tailscale` / `Cloudflare` / `EasyTier`。
2. **默认选中 Tailscale**。
3. 切换到某个方式后，**下方二维码与状态文案同步切换**，只显示当前方式的那一张码。
4. 面板里写明：**仅局域网使用时优先选 Cloudflare**（不用装任何客户端、最快）。
5. 三种方式**互斥**：切换时停掉上一种的隧道，避免多个进程同时跑。
6. 不再调用 `dsh-pocket` 的任何能力。

**非目标**
- 不内嵌 Tailscale / EasyTier 的可执行文件（依赖用户自行安装，或后续单独讨论）。
- 不做多设备同时连接的管理界面。
- 不改手机 App（App 只需扫码拿到地址，三种方式产出的入口 URL 格式一致）。

## 参考实现（Prior art）

- **`dsh-pocket` 的 Cloudflare 隧道**（`lib/service.mjs` 的 `startQuickTunnel` /
  `startNamedTunnel`）：
  - quick 模式：`cloudflared tunnel --url http://127.0.0.1:<port>` → 从 stderr 抓
    `https://xxx.trycloudflare.com`
  - named 模式：用户提供 token + 固定 hostname
  → **采用**：quick 模式先做，named 留接口。
- **本项目现有的 Tailscale 面板**（`dsh-pocket-ios` 的「手机访问」页）：
  已有「固定地址 + 配对二维码 + 访问密码」三件套
  → **复用**：切换后其余两种方式产出同样形状的状态（address / qr / token）。
- **`dsh-pocket` 的进程管理**（`lib/tunnel.mjs`）：已有启动/停止/超时/日志抓取
  → **采用**：同样的「子进程 + 正则抓 URL + 超时兜底」模式。

## 方案

### 一期：UI 三选一 + Cloudflare quick 隧道

**UI（插件面板顶部）**

```
○ Tailscale   ● Cloudflare   ○ EasyTier
仅局域网使用时优先选 Cloudflare（无需额外客户端）
```

- 单选圆点用现有的面板组件风格（不用系统控件，保持视觉一致）
- 切换后立刻：停旧隧道 → 启新隧道 → 二维码区域换成新状态

**Cloudflare 实现**

1. 探测 `cloudflared`：
   - `which cloudflared`
   - 常见路径兜底：`/opt/homebrew/bin`、`/usr/local/bin`
   - 找不到 → 面板显示「未安装 cloudflared」+ 安装命令（brew）
2. 启动：`cloudflared tunnel --url http://127.0.0.1:<dshPort> --no-autoupdate`
3. 从 stderr 正则抓 `https://[a-z0-9-]+\.trycloudflare\.com`（超时 30 秒）
4. 生成二维码（复用现有 `qrDataUrl`）
5. 退出/切换时 `SIGTERM` 掉子进程

**状态模型**（三种方式共用）

```js
{ mode: 'tailscale' | 'cloudflare' | 'easytier',
  running: boolean,
  address: string | null,   // 入口地址
  qr: string | null,        // data URL
  state: 'idle' | 'starting' | 'ready' | 'error',
  error: string | null }
```

### 二期：EasyTier

**待调研**（写进「未决问题」）：
- EasyTier 的 CLI 与配置格式（`easytier-core`？`easytier-cli`？）
- 需不需要用户提供**网络名 + 密钥**（P2P 组网要有公共房间）
- 是否需要**公共中继节点**（国内可达性）
- 手机端是否也要装 EasyTier 客户端

**初步判断**：EasyTier 比 Cloudflare 复杂一档——它不是"给我一个公网 URL"，
而是"把两端放进同一个虚拟网络"。所以二维码里放的可能仍是一个 **局域网风格的地址**
（虚拟网段 IP），手机端需要**同样加入该网络**才连得上。

**这决定了一件事**：面板文案必须说清「**用 EasyTier 前，手机也要装 EasyTier 并入同一网络**」，
否则会重复今天「扫了却连不上」的困惑。

### 三期：清理对 dsh-pocket 的依赖

- 删掉面板里「局域网 / 公网二维码由 dsh-pocket 插件提供（可选）」这类指向文案
- 检查是否还有运行时代码引用 `dsh-pocket`（应该只有文案，逻辑本来就是独立的）

## 被否决的方案

| 方案 | 否决理由 |
| --- | --- |
| 保留 dsh-pocket，只加一个"高级"入口 | 用户明确要求不再依赖它；两套面板正是混乱根源 |
| 三种方式同时跑、让用户自己选地址 | 三个隧道进程 + 三张码，反而更乱；且 quick 隧道每次地址都变 |
| 把 cloudflared 二进制打进插件包 | 体积 + 各平台（mac/Win/Linux）分发问题，先用外部依赖 |
| 用 Cloudflare named 隧道做首发 | 要域名 + API token，门槛高于"仅局域网用"的主场景 |

## 代价与风险

**代价**
- 一期约 350 行（UI 单选 + cloudflared 管理 + 状态合并）
- 需要用户机器上装 `cloudflared`（面板给出安装引导）

**风险**
| 风险 | 缓解 |
| --- | --- |
| `cloudflared` 未安装 / 版本不兼容 | 探测失败时给明确安装命令，不静默失败 |
| quick 隧道地址每次重启都变 | 面板明确「重启后会变」；二维码实时生成 |
| 隧道进程残留 | 切换/退出统一 `SIGTERM`；启动前先杀同名旧进程 |
| EasyTier 语义与另两者不同（虚拟网络 vs 公网 URL） | 二期内单独处理文案，不与另两者混为一谈 |
| 切换时正在被手机使用 | 状态区显示「切换会断开当前连接」 |

## 未决问题（Unresolved Questions）

1. **EasyTier 的接入方式**：CLI 名称、配置、是否需要公共中继、手机端是否必须同装？
2. **Cloudflare named 隧道**要不要在一期一起做（固定域名，重启不变）？
3. 三种方式的**订阅/费用**是否需要提示（Cloudflare 免费额度、EasyTier 自建 vs 公共节点）？
4. 用户机器上的 `dsh-pocket` 如果还装着，两个面板同时出现会不会继续造成混淆？
   （可能需要在我们面板里加一句「如已装 dsh-pocket，可忽略其二维码」）

## 测试计划（先红后绿）

| 用例 | target | 断言 |
| --- | --- | --- |
| 默认模式 | 面板状态 | 首次打开 `mode === 'tailscale'` |
| 切换到 Cloudflare | 手工 | cloudflared 启动、30 秒内拿到 `trycloudflare.com` |
| 切回 Tailscale | 手工 | cloudflared 进程被终止，状态回到 Tailscale 地址 |
| cloudflared 缺失 | 手工（改 PATH 模拟） | 显示安装引导，不崩、不卡在 starting |
| 互斥 | 手工 | 任意时刻只有一个隧道进程存活 |
| 二维码内容 | 单测 | 三种模式下 QR 内容与 `address` 一致 |
| 回归 | `npm test` | 既有 165 条里不新增失败 |

## 预估工时

| 期 | 单元 | 小计 |
| --- | --- | --- |
| 一期 | 单选 UI + 状态模型 + cloudflared 管理 + 测试 | **350 分钟** |
| 二期 | EasyTier 调研（60）+ 实现（250）+ 测试 | **310 分钟** |
| 三期 | 清理依赖文案 + 回归 | **60 分钟** |
| 联调 | 三种方式真机扫码验证 | **200 分钟** |
| **合计** | | **920 分钟** |

> 一期先做，因为「仅局域网用 Cloudflare」是**收益最高、门槛最低**的路径。
> 二期 EasyTier 有未决问题，需要先调研再动手。
