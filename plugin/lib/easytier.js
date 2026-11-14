// EasyTier 通道
//
// 为什么和 Cloudflare 差这么多：
//
// Cloudflare 是「给我一个公网 URL」，手机什么都不用装。
// EasyTier 是 **P2P 组网**——电脑加入一个虚拟网络拿到 10.x.x.x 地址，手机也得进同一个网络。
//
// 而 EasyTier 在 iOS 上**不能本地跑**（官方只支持 Win/macOS/Linux/FreeBSD/Android）。
// 官方给 iOS 的路子是 **WireGuard 门户**：
//   1. 电脑跑 `easytier-core --vpn-portal wg://0.0.0.0:11011 ...`
//   2. `easytier-cli vpn-portal` 导出一份 WireGuard 客户端配置
//   3. 手机用 WireGuard App 扫码/导入这份配置
//
// 所以本模块的职责是：**帮用户把第 2、3 步准备好**（生成配置 + 二维码），
// 第 1 步需要 root 建虚拟网卡，插件没有 sudo，只能给命令让用户自己跑。

import { execFile } from 'node:child_process'
import { access, constants, readFile } from 'node:fs/promises'
import { delimiter, join } from 'node:path'
import { homedir } from 'node:os'
import { promisify } from 'node:util'

const execFileP = promisify(execFile)

/** 常见安装位置（Homebrew / 官方脚本 / 手动解压）。 */
const FALLBACK_DIRS = [
  '/opt/homebrew/bin',
  '/usr/local/bin',
  '/usr/bin',
  join(homedir(), '.local', 'bin'),
  join(homedir(), 'easytier'),
]

/** 探测单个可执行文件。 */
async function findBin(name) {
  for (const dir of String(process.env.PATH ?? '').split(delimiter)) {
    if (!dir) continue
    const candidate = join(dir, name)
    try {
      await access(candidate, constants.X_OK)
      return candidate
    } catch { /* 继续找 */ }
  }
  for (const dir of FALLBACK_DIRS) {
    const candidate = join(dir, name)
    try {
      await access(candidate, constants.X_OK)
      return candidate
    } catch { /* 继续找 */ }
  }
  return null
}

/**
 * 探测 EasyTier 的两个可执行文件。
 * @returns {Promise<{core: string|null, cli: string|null}>}
 */
export async function findEasytier() {
  const [core, cli] = await Promise.all([findBin('easytier-core'), findBin('easytier-cli')])
  return { core, cli }
}

/**
 * 从 `easytier-cli vpn-portal` 的输出里提取 WireGuard 配置。
 *
 * 输出形如：
 *   [Interface]
 *   Address = 10.144.144.3/32
 *   PrivateKey = ...
 *   ...
 *   [Peer]
 *   PublicKey = ...
 *   Endpoint = 1.2.3.4:11011
 *   ...
 *
 * 前面可能夹着日志行，所以按 `[Interface]` 起点截取。
 *
 * @param {string} text
 * @returns {string|null}
 */
export function extractWireGuardConfig(text) {
  const raw = String(text ?? '')
  const start = raw.indexOf('[Interface]')
  if (start < 0) return null
  const body = raw.slice(start).trim()
  // 必须同时有 [Interface] 和 [Peer]，否则不是一份能用的配置
  if (!body.includes('[Peer]')) return null
  return body
}

/**
 * 把 WireGuard 配置里缺失的 Endpoint 补上。
 *
 * `easytier-cli vpn-portal` 有时给出通配地址（0.0.0.0/::），手机导入后连不上；
 * 官方文档也要求用户自己把这个换成本机公网 IP 或域名。
 *
 * @param {string} config
 * @param {string} host 用户可达的主机（局域网 IP 或公网域名）
 * @param {number} port
 * @returns {string}
 */
export function patchEndpoint(config, host, port) {
  if (!host) return config
  const line = `Endpoint = ${host}:${port}`
  if (/^Endpoint\s*=/m.test(config)) {
    return config.replace(/^Endpoint\s*=.*$/m, line)
  }
  // 没有 Endpoint 行：补到 [Peer] 段末尾
  return config.replace(/(\[Peer\][\s\S]*?)(\n?$)/, (m, peer, tail) => `${peer.trimEnd()}\n${line}${tail}`)
}

/**
 * 生成电脑端该执行的命令（用户要自己在终端 sudo 跑）。
 *
 * 插件不能代跑：`easytier-core` 建虚拟网卡必须 root。
 *
 * @param {{ networkName: string, networkSecret: string, portalPort: number, peers?: string }} opts
 * @returns {string}
 */
export function coreCommand({ networkName, networkSecret, portalPort, peers = '' }) {
  const parts = [
    'sudo easytier-core',
    '-d',
    `--network-name ${networkName}`,
    `--network-secret ${networkSecret}`,
    `--vpn-portal wg://0.0.0.0:${portalPort}`,
    '--vpn-portal-private-key "$(wg genkey)"',
  ]
  // 手机作为一台 WireGuard 客户端注册进虚拟网络
  parts.push('--vpn-portal-client phone=10.144.144.3')
  if (peers) parts.push(`-p ${peers}`)
  return parts.join(' ')
}

/**
 * 生成一份随机的网络名/密钥（避免和别人撞名导致组网失败）。
 * @returns {{ networkName: string, networkSecret: string }}
 */
export function randomNetwork() {
  const rand = (len) => {
    const chars = 'abcdefghijkmnpqrstuvwxyz23456789'
    let out = ''
    for (let i = 0; i < len; i++) out += chars[Math.floor(Math.random() * chars.length)]
    return out
  }
  return { networkName: `dsh-${rand(8)}`, networkSecret: rand(16) }
}

/**
 * 调 `easytier-cli vpn-portal` 拿当前配置。
 *
 * @param {string} cliPath
 * @returns {Promise<string|null>} 配置文本；没有/失败返回 null
 */
export async function readWireGuardPortal(cliPath) {
  if (!cliPath) return null
  try {
    const { stdout } = await execFileP(cliPath, ['vpn-portal'], { timeout: 10_000 })
    return extractWireGuardConfig(stdout)
  } catch {
    return null
  }
}

/** 读配置文件的兜底（用户在 GUI 里导出过的话）。 */
export async function readConfigFile(path) {
  try {
    return await readFile(path, 'utf8')
  } catch {
    return null
  }
}
