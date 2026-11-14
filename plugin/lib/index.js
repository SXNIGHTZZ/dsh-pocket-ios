/**
 * dsh-pocket-ios 宿主入口。
 * 1) 检测本机 Tailscale（DNSName + tailscale serve 的 HTTPS 地址）；
 * 2) 读取 dsh-pocket 的访问密码，生成带 `?pin=` 的二维码（App 扫码即连）；
 * 3) 通过 webServer 暴露 `/dsh-pocket-ios/tailscale.status` 给设置页卡片。
 */
import { appendFile, mkdir, readFile, writeFile } from 'node:fs/promises'
import { randomInt } from 'node:crypto'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { execFile } from 'node:child_process'
import { createServer, request as httpRequest } from 'node:http'
import { promisify } from 'node:util'
import QRCode from 'qrcode'
import { CloudflareTunnel, findCloudflared } from './cloudflare.js'
import { selectLanIPv4, lanEntryUrl } from './lan.js'
import { findEasytier, readWireGuardPortal, normalizeWireGuardConfig, clientAddressFrom, coreCommand, randomNetwork } from './easytier.js'

const execFileP = promisify(execFile)

export const name = 'dsh-pocket-ios'
export const inject = ['connection', 'webServer']

const CHANNEL = '/dsh-pocket-ios'
/**
 * EasyTier WireGuard 门户端口。
 * **不能落在 11010–11013**：EasyTier 默认已在那几个端口上监听
 * tcp/udp/wg/quic/ws/wss/faketcp，实测复用会 "Address already in use"。
 */
const EASYTIER_PORTAL_PORT = 11500
const TAILSCALE_BIN = '/Applications/Tailscale.app/Contents/MacOS/Tailscale'
const BODY_MAX = 64 * 1024
/** 稳定本地入口端口：Tailscale Serve 指向它；默认 3081（与 dsh-pocket 代理端口一致）。 */
const PROXY_PORT = Number(process.env.DSH_POCKET_IOS_PROXY_PORT ?? 3091)

const LOG_DIR = join(homedir(), '.dsh', 'dsh-pocket-ios')

// 一次性配对 token（60 秒有效、用后作废），用于扫码免密码连接。
const pairTokens = new Map()

/**
 * 长期设备凭证。
 *
 * 为什么需要：DSH 的 dsh-auth cookie 是 **session 级**的，DSH 一重启就失效，
 * 用户就得重新扫码。设备凭证存在电脑上（不含密码），App 存一份在 Keychain，
 * cookie 失效时用它换新的——除非用户主动撤销设备，否则不必再扫。
 *
 * 存储：~/.dsh/dsh-pocket-ios/devices.json
 *   { "<token>": { name, createdAt, lastUsedAt } }
 * token 是 32 字节随机串，只在本机文件与用户 Keychain 里，不上传任何地方。
 */
const DEVICE_FILE = join(LOG_DIR, 'devices.json')
let devicesCache = null

async function readDevices() {
  if (devicesCache) return devicesCache
  try {
    devicesCache = JSON.parse(await readFile(DEVICE_FILE, 'utf8'))
    if (!devicesCache || typeof devicesCache !== 'object') devicesCache = {}
  } catch {
    devicesCache = {}
  }
  return devicesCache
}

async function saveDevices(map) {
  devicesCache = map
  await mkdir(LOG_DIR, { recursive: true })
  await writeFile(DEVICE_FILE, JSON.stringify(map, null, 2), { mode: 0o600 })
}

function newDeviceToken() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
  return Array.from({ length: 43 }, () => chars[Math.floor(Math.random() * chars.length)]).join('')
}

/** 从请求里取设备凭证：优先 header，其次 cookie。 */
function deviceTokenFrom(req, urlObject) {
  const header = String(req.headers['x-dsh-pocket-device'] ?? '').trim()
  if (header) return header
  const cookie = String(req.headers.cookie ?? '')
  const match = cookie.match(/(?:^|;\s*)dsh-pocket-device=([^;]+)/)
  if (match) return decodeURIComponent(match[1])
  return String(urlObject?.searchParams?.get('device') ?? '').trim()
}
async function logLine(line) {
  try {
    await mkdir(LOG_DIR, { recursive: true })
    await appendFile(join(LOG_DIR, 'tailscale.log'), `${new Date().toISOString()} ${line}\n`)
  } catch { /* 日志失败不影响主流程 */ }
}

async function tailscale(args) {
  try {
    const { stdout } = await execFileP(TAILSCALE_BIN, args, { timeout: 8000, maxBuffer: 1 << 20 })
    return stdout
  } catch (error) {
    await logLine(`exec ${args.join(' ')} failed: ${error?.code ?? ''} ${error?.message ?? error}`)
    throw error
  }
}

const PIN_FILE = join(LOG_DIR, 'pin')

/** 读取（或首次生成）本插件自己的访问密码，不依赖 dsh-pocket。 */
const PIN_PATTERN = /^[A-Za-z0-9]{8,64}$/

/** 写入访问密码（自定义或随机刷新）；返回写入后的状态。 */
async function setPin(nextPin) {
  await mkdir(LOG_DIR, { recursive: true })
  await writeFile(PIN_FILE, nextPin, { mode: 0o600 })
}

async function readPin() {
  try {
    const existing = (await readFile(PIN_FILE, 'utf8')).trim()
    if (/^[A-Za-z0-9]{8,64}$/.test(existing)) return existing
  } catch { /* 首次运行：下面生成 */ }
  const pin = String(randomInt(10_000_000, 100_000_000))
  try {
    await mkdir(LOG_DIR, { recursive: true })
    await writeFile(PIN_FILE, pin, { mode: 0o600 })
  } catch { /* 写失败仍返回内存值 */ }
  return pin
}

/** 读取配置文件里的 Tailscale 地址（DSH 宿主进程往往访问不到 Tailscale GUI 的 IPC，
 *  CLI 探测会报 "The Tailscale GUI failed to start"，因此配置文件是首选的可靠来源）。
 * 文件：~/.dsh/dsh-pocket-ios/tailscale.json，内容 {"url":"https://<机器>.<tailnet>.ts.net"}
 */
async function readConfiguredUrl() {
  try {
    const raw = await readFile(join(LOG_DIR, 'tailscale.json'), 'utf8')
    const parsed = JSON.parse(raw)
    const url = typeof parsed?.url === 'string' ? parsed.url.trim().replace(/\/$/, '') : ''
    if (/^https:\/\//.test(url)) return url
  } catch { /* 没有配置文件时回退到 CLI */ }
  return null
}

/** 供 RPC 与单测使用：返回 Tailscale 连接信息与带访问密码的二维码。 */
/** 三种连接方式。默认 Tailscale。 */
// 顺序即门槛从低到高：Cloudflare（手机零安装）→ Tailscale（需账号）→ EasyTier（需海外 App + 付费）
const MODES = ['lan', 'cloudflare', 'tailscale', 'easytier']
const MODE_LABELS = {
  cloudflare: 'Cloudflare',
  lan: '局域网',
  tailscale: 'Tailscale',
  easytier: 'EasyTier',
}

/** 当前选中的模式（进程内）。持久化见 readMode/saveMode。 */
let currentMode = 'lan'
/** Cloudflare quick 隧道（懒创建；同一时刻只跑一个）。 */
let cloudflareTunnel = null
/** dsh web 的监听端口，apply() 里赋值；modeStatus 用它起隧道。 */
let dshWebPortRef = null

/**
 * EasyTier 的网络名/密钥：首次生成后持久化，保证电脑和手机用同一套。
 * 换掉它们等于换了网络，手机那边的配置就失效了。
 */
async function readOrCreateEasyTierNetwork() {
  const file = join(LOG_DIR, 'easytier-network.json')
  try {
    const raw = await readFile(file, 'utf8')
    const parsed = JSON.parse(raw)
    if (parsed?.networkName && parsed?.networkSecret) return parsed
  } catch { /* 没存过 */ }
  const created = randomNetwork()
  try {
    await mkdir(LOG_DIR, { recursive: true })
    await writeFile(file, JSON.stringify(created), 'utf8')
  } catch { /* 存不了不影响本次 */ }
  return created
}

function modeFile() {
  return join(LOG_DIR, 'mode.json')
}

async function readMode() {
  try {
    const raw = await readFile(modeFile(), 'utf8')
    const value = JSON.parse(raw)?.mode
    if (MODES.includes(value)) return value
  } catch { /* 没存过 */ }
  // 默认 Cloudflare：手机端零安装，是唯一"扫码即连、什么都不用装"的方式
  return 'lan'
}

async function saveMode(mode) {
  try {
    await mkdir(LOG_DIR, { recursive: true })
    await writeFile(modeFile(), JSON.stringify({ mode }), 'utf8')
  } catch { /* 存不了不影响本次使用 */ }
}

/** Cloudflare 隧道实例（端口取自 dsh web 的监听端口）。 */
function cloudflareFor(port) {
  if (!cloudflareTunnel || cloudflareTunnel.port !== port) {
    cloudflareTunnel = new CloudflareTunnel({ port, log: (line) => void logLine(line) })
  }
  return cloudflareTunnel
}

/**
 * 当前连接方式的统一状态视图（面板和 pair.create 共用）。
 *
 * 三种方式对外的形状一致：address / qr / state / error，面板只需要渲染一套 UI。
 * - tailscale: 固定域名（需先装 Tailscale 并登录）
 * - cloudflare: quick 隧道（每次启动地址都会变，所以实时生成）
 * - easytier: 暂未实现，返回 not-supported，面板据此显示「即将支持」
 *
 * @returns {Promise<{mode: string, label: string, address: string|null, qr: string|null,
 *   state: string, error: string|null, modes: {id: string, label: string}[]}>}
 */
async function modeStatus() {
  currentMode = await readMode()
  const modes = MODES.map((id) => ({ id, label: MODE_LABELS[id] }))
  // 访问密码与连接方式无关，所有分支都要带上。
  // 之前只在 tailscaleStatus 里返回，切到 modeStatus 后漏了 → 面板显示「—」（用户反馈）。
  const pin = await readPin()
  const base = {
    mode: currentMode,
    label: MODE_LABELS[currentMode],
    modes,
    pin,
    pinSet: Boolean(pin),
  }

  if (currentMode === 'cloudflare') {
    const port = dshWebPortRef
    if (!port) {
      return { ...base, address: null, qr: null, state: 'error', error: '拿不到 dsh web 端口' }
    }
    const tunnel = cloudflareFor(port)
    const snap = tunnel.status()

    // 已就绪 → 直接给地址
    if (snap.state === 'ready' && snap.url) {
      const qr = await QRCode.toDataURL(snap.url, { margin: 1, width: 360 })
      return { ...base, address: snap.url, qr, state: 'ready', error: null, phase: null }
    }

    // 启动中 → 不阻塞这次 RPC，前端轮询就能看到进度。
    // **不能在 status 里 await tunnel.start()**：首次要下载 24MB + 等隧道注册，
    // 会把 RPC 拖到超时，前端只看到 "invalid server-response failure"（2026-11-15 实测）。
    if (snap.state !== 'starting') {
      void tunnel.start().catch((error) => {
        void logLine(`cloudflare start failed: ${error?.message ?? error}`)
      })
    }
    const downloading = snap.phase === 'locating' || snap.phase === 'downloading'
      || snap.phase === 'extracting' || snap.phase === 'retrying'
    return {
      ...base,
      address: null,
      qr: null,
      state: 'starting',
      error: null,
      phase: snap.phase ?? null,
      detail: downloading
        ? `首次使用，正在准备 cloudflared（约 24MB）：${snap.phaseDetail ?? ''}`
        : '正在启动 Cloudflare 隧道…',
    }
  }

  if (currentMode === 'lan') {
    // 局域网直连：不经过任何隧道。同一 Wi-Fi 下这是最快最稳的方式。
    const ip = selectLanIPv4()
    const port = dshWebPortRef
    // 诊断：lan 分支返回 error 时最常见的两个原因就是这两个为 null
    void logLine(`lan status: ip=${ip ?? 'null'} dshPort=${port ?? 'null'} proxyPort=${PROXY_PORT}`)
    if (!ip || !port) {
      return {
        ...base,
        address: null,
        qr: null,
        state: 'error',
        error: ip
          ? '拿不到 dsh web 端口'
          : '没有找到局域网地址：请确认电脑已连上 Wi-Fi 或有线网络',
      }
    }
    // 必须用代理端口：DSH 自己只监听 127.0.0.1:${port}，手机连不上。
    // 代理（PROXY_PORT）已经在 0.0.0.0 上监听并转发到 DSH。
    const address = lanEntryUrl(ip, PROXY_PORT)
    const qr = await QRCode.toDataURL(address, { margin: 1, width: 360 })
    return { ...base, address, qr, state: 'ready', error: null }
  }

  if (currentMode === 'easytier') {
    // EasyTier 是 P2P 组网，不是"给我一个公网 URL"。
    // 电脑跑 easytier-core 建虚拟网卡（需要 root，插件代不了），
    // 手机端在 iOS 上根本跑不了 EasyTier —— 官方给的路子是 WireGuard 门户：
    // 电脑导出 wg 配置，手机用 WireGuard App 导入。
    const { cli } = await findEasytier()
    if (!cli) {
      return {
        ...base,
        address: null,
        qr: null,
        state: 'error',
        error: '没找到 easytier-cli。先安装 EasyTier（brew install easytier 或它的官方脚本），再回来刷新。',
      }
    }

    const wg = await readWireGuardPortal(cli)
    if (!wg) {
      // 还没建好门户：给出该执行的命令 + 随机网络名/密钥
      const net = await readOrCreateEasyTierNetwork()
      const cmd = coreCommand({
        networkName: net.networkName,
        networkSecret: net.networkSecret,
        portalPort: EASYTIER_PORTAL_PORT,
      })
      return {
        ...base,
        address: null,
        qr: null,
        state: 'needs-setup',
        error: '还没建 WireGuard 门户。在电脑终端执行下面的命令（需要 sudo），完成后点刷新。',
        command: cmd,
        hint: '手机端请安装 WireGuard（不是 EasyTier）：导入配置后即可访问这台电脑。',
      }
    }

    // 有配置：把 Endpoint 换成本机可达地址（easytier 常给 0.0.0.0）
    const lanIp = selectLanIPv4()
    const host = lanIp || ''
    const config = normalizeWireGuardConfig(wg, host, EASYTIER_PORTAL_PORT)
    const qr = await QRCode.toDataURL(config, { margin: 1, width: 360 })

    // **手机要连的是虚拟网络里的 DSH 入口，不是局域网 IP**。
    // WireGuard 只负责让手机进 10.14.14.0/24；DSH 本身在 127.0.0.1，
    // 靠代理的 0.0.0.0:3091 在虚拟网络上暴露出来。
    // 所以 App 里该填 http://10.14.14.1:3091。
    const virtualHost = clientAddressFrom(wg).replace(/\.\d+$/, '.1')
    return {
      ...base,
      address: `http://${virtualHost}:${PROXY_PORT}`,
      qr,
      state: 'ready',
      error: null,
      config,
      hint: `用手机上的 WireGuard 类客户端导入这份配置并启用，然后在 App 里连接 http://${virtualHost}:${PROXY_PORT}`,
    }
  }

  // tailscale（默认）
  const ts = await tailscaleStatus()
  return {
    ...base,
    address: ts.httpsUrl ?? null,
    qr: ts.qr ?? null,
    state: ts.httpsUrl ? 'ready' : 'error',
    error: ts.httpsUrl ? null : 'Tailscale 未就绪：请确认已安装并登录 Tailscale',
  }
}

export async function tailscaleStatus() {
  let dnsName = null
  let httpsUrl = null
  let serveRaw = null
  let source = null

  const configuredUrl = await readConfiguredUrl()
  if (configuredUrl) {
    httpsUrl = configuredUrl
    source = 'config'
    try {
      const json = JSON.parse(await tailscale(['status', '--json']))
      dnsName = json?.Self?.DNSName ? String(json.Self.DNSName).replace(/\.$/, '') : null
    } catch { /* 只用于展示；配置了 URL 就够用 */ }
    if (!dnsName) dnsName = new URL(configuredUrl).hostname
  }

  if (!httpsUrl) {
    try {
      const json = JSON.parse(await tailscale(['status', '--json']))
      dnsName = json?.Self?.DNSName ? String(json.Self.DNSName).replace(/\.$/, '') : null
    } catch { /* Tailscale 未安装/未登录 */ }
    try {
      const out = await tailscale(['serve', 'status'])
      serveRaw = out
      const match = out.match(/https:\/\/[^\s)]+/)
      if (match) {
        httpsUrl = match[0].replace(/\/$/, '')
        source = 'cli'
      } else {
        await logLine(`serve status 无 https 匹配: ${JSON.stringify(out.slice(0, 200))}`)
      }
    } catch (error) {
      await logLine(`serve status 异常: ${error?.message ?? error}`)
    }
  }

  const pin = await readPin()
  // 产品安全：二维码只包含连接地址，绝不把访问密码写进二维码/图片。
  const qrUrl = httpsUrl
  const qr = qrUrl ? await QRCode.toDataURL(qrUrl, { margin: 1, width: 360 }) : null
  return { available: Boolean(dnsName) || Boolean(httpsUrl), dnsName, httpsUrl, pin, pinSet: Boolean(pin), qrUrl, qr, serveRaw, source }
}

function endpointFromPath(pathname) {
  if (typeof pathname !== 'string' || !pathname.startsWith(`${CHANNEL}/`)) return undefined
  const endpoint = pathname.slice(CHANNEL.length + 1)
  if (!endpoint || endpoint.split('/').some((seg) => seg === '' || seg === '.' || seg === '..')) return undefined
  return endpoint
}

async function readRawBody(req) {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    size += chunk.length
    if (size > BODY_MAX) throw new Error('body too large')
    chunks.push(chunk)
  }
  return Buffer.concat(chunks).toString('utf8')
}

async function readBody(req) {
  return JSON.parse(await readRawBody(req))
}

function send(res, status, payload) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' })
  res.end(JSON.stringify(payload))
}


/**
 * 稳定本地入口：HTTP/WS 代理到当前 DSH web 端口（端口每次重启可能变化）。
 * 外部 Tailscale HTTPS 只需固定指向本端口，不依赖 dsh-pocket。
 */
function attachStableProxy(ctx, handler) {
  const dshPort = ctx.webServer?.port
  dshWebPortRef = dshPort ?? null
  if (!dshPort) {
    ctx?.logger?.warn?.('dsh-pocket-ios: 拿不到 DSH web 端口，稳定入口未启动')
    return () => {}
  }
  // DSH 的 browser-auth/可信 Host 校验只认 loopback：Tailscale 进来的公网 Host 必须改写，
  // 否则 token 换完 cookie 后继续访问仍会 403（dsh-pocket 的代理同样做这件事）。
  const forwardHeaders = (headers) => {
    const copy = { ...headers }
    copy.host = `127.0.0.1:${dshPort}`
    if (typeof copy.origin === 'string') copy.origin = `http://127.0.0.1:${dshPort}`
    if (typeof copy.referer === 'string') {
      try {
        const referer = new URL(copy.referer)
        copy.referer = `http://127.0.0.1:${dshPort}${referer.pathname}${referer.search}`
      } catch { /* 非法 Referer 直接丢弃 */ }
    }
    delete copy['x-forwarded-for']
    delete copy['x-forwarded-host']
    delete copy['x-forwarded-proto']
    return copy
  }
  const server = createServer((req, res) => {
    try {
      if ((req.url ?? '').startsWith(`${CHANNEL}/`)) {
        handler(req, res)
        return
      }
      const proxyReq = httpRequest({
        host: '127.0.0.1', port: dshPort, method: req.method,
        path: req.url, headers: forwardHeaders(req.headers),
      }, (proxyRes) => {
        res.writeHead(proxyRes.statusCode ?? 502, proxyRes.headers)
        proxyRes.pipe(res)
      })
      proxyReq.on('error', () => {
        try { res.writeHead(502, { 'content-type': 'text/plain' }); res.end('bad gateway') } catch { /* 已结束 */ }
      })
      req.pipe(proxyReq)
    } catch {
      try { res.writeHead(502); res.end() } catch { /* 已结束 */ }
    }
  })
  server.on('upgrade', (req, socket, head) => {
    const proxyReq = httpRequest({
      host: '127.0.0.1', port: dshPort, method: req.method,
      path: req.url, headers: forwardHeaders(req.headers),
    })
    proxyReq.on('upgrade', (proxyRes, proxySocket, proxyHead) => {
      const lines = [`HTTP/1.1 101 Switching Protocols`]
      for (const [key, value] of Object.entries(proxyRes.headers)) {
        if (value !== undefined) lines.push(`${key}: ${Array.isArray(value) ? value.join(', ') : value}`)
      }
      socket.write(lines.join('\r\n') + '\r\n\r\n')
      if (proxyHead?.length) socket.write(proxyHead)
      if (head?.length) proxySocket.write(head)
      proxySocket.pipe(socket)
      socket.pipe(proxySocket)
    })
    proxyReq.on('error', () => socket.destroy())
    proxyReq.end()
  })
  server.on('error', (error) => ctx?.logger?.warn?.(`dsh-pocket-ios: 稳定入口端口 ${PROXY_PORT} 不可用（${error?.message ?? error}）`))
  // 绑 0.0.0.0 而不是只绑回环：局域网模式下手机要能直连这个端口。
  // 安全性由 DSH 自身的登录态保证（非 /dsh-pocket-ios/ 前缀的请求会原样转发给 DSH，
  // 未认证时 DSH 返回 401）——这和 dsh-pocket 的做法一致。
  server.listen(PROXY_PORT, '0.0.0.0', () => {
    ctx?.logger?.info?.(`dsh-pocket-ios: 稳定入口 http://0.0.0.0:${PROXY_PORT} → DSH 127.0.0.1:${dshPort}`)
  })
  return () => { try { server.close() } catch { /* 已关闭 */ } }
}

/**
 * 挂载 RPC 路由。auth 用 connection.requestRejection（必须绑定 this，否则丢失 trustedHosts）。
 * @param ctx - cordis 插件上下文。
 */
export function apply(ctx) {
  const webServer = ctx?.webServer
  const connection = ctx?.connection
  if (!webServer || typeof webServer.register !== 'function') {
    ctx?.logger?.warn?.('dsh-pocket-ios: webServer 不可用，Tailscale 卡片 RPC 未挂载')
    return
  }
  const route = {
    kind: 'prefix',
    path: CHANNEL,
    handler: async (req, res) => {
      try {
        const rawPath = new URL(req.url ?? '/', 'http://127.0.0.1').pathname
        // 免浏览器会话的白名单：这三个端点自带凭证校验
        //   login  = PIN
        //   pair   = 一次性配对 token
        //   refresh= 长期设备凭证（DSH 重启后 cookie 失效时用它换新票）
        const isLogin = rawPath === `${CHANNEL}/login`
          || rawPath === `${CHANNEL}/pair`
          || rawPath === `${CHANNEL}/refresh`
        if (!isLogin && typeof connection?.requestRejection === 'function') {
          const rejection = connection.requestRejection(req)
          if (rejection !== undefined) {
            send(res, rejection, { ok: false })
            return
          }
        }
        const urlObject = new URL(req.url ?? '/', 'http://127.0.0.1')
        const endpoint = endpointFromPath(urlObject.pathname)
        if (endpoint === undefined) {
          send(res, 404, { ok: false })
          return
        }
/**
 * 推断原始请求该用 http 还是 https。
 *
 * 关键：**局域网 / 私有网段一律 http**。它们没有 TLS 证书，拼成 https 会直接连不上。
 *
 * 旧实现只把 loopback 当 http，其他全当 https，于是局域网配对成功后 302 到
 * `https://192.168.x.x:3091/` —— 手机连不上，表现为「局域网模式进不去」。
 * Tailscale 那条本来就是 https，所以从日志看不出来（2026-11-15 定位）。
 *
 * @param {import('node:http').IncomingMessage} req
 * @param {string} host 请求的 Host 头
 * @returns {'http'|'https'}
 */
function guessProto(req, host) {
  const forwarded = String(req.headers['x-forwarded-proto'] ?? '').split(',')[0].trim()
  if (forwarded === 'http' || forwarded === 'https') return forwarded
  const bare = String(host).replace(/:\d+$/, '')
  if (/^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.)/.test(bare)) return 'http'
  if (/^(localhost|\[::1\]|.*\.local)$/i.test(bare)) return 'http'
  return 'https'
}

        // 登录端点：不需要已有浏览器会话，用本插件自己的 PIN 换 DSH 的认证 cookie。
        if (endpoint === 'pair') {
          if (req.method !== 'POST' && req.method !== 'GET') { send(res, 405, { ok: false }); return }
          let token = urlObject.searchParams.get('token') ?? urlObject.searchParams.get('pair') ?? ''
          if (req.method === 'POST') {
            const raw = await readRawBody(req)
            const contentType = String(req.headers['content-type'] ?? '')
            if (contentType.includes('application/json')) {
              try { token = JSON.parse(raw)?.token ?? JSON.parse(raw)?.pair ?? token } catch { /* ignore */ }
            } else {
              token = new URLSearchParams(raw).get('token') ?? new URLSearchParams(raw).get('pair') ?? token
            }
          }
          const record = pairTokens.get(String(token))
          if (!record || record.expiresAt < Date.now()) {
            pairTokens.delete(String(token))
            await logLine('pair rejected (expired/unknown)')
            send(res, 401, { ok: false })
            return
          }
          // 不在这里删 token：同一张码可能被点开两次（浏览器预取、用户刷新、
          // 或在两台设备上先后打开）。过期由 expiresAt 控制，不必靠「用掉即删」。
          // 删掉的后果是「第二次打开就说过期」，用户完全无法理解。
          const host = String(req.headers.host ?? '')
          if (!host || typeof connection?.authenticatedUrl !== 'function') { send(res, 503, { ok: false }); return }
          const proto = guessProto(req, host)
          const target = connection.authenticatedUrl(`${proto}://${host}/`)
          // 顺带签发长期设备凭证：cookie 是 session 级的，DSH 重启后失效，
          // App 靠这份凭证换新 cookie，不必重新扫码。
          let deviceCookie = []
          try {
            const devices = await readDevices()
            // 复用同名设备，避免每次配对都堆一条。
            const deviceName = String(req.headers['user-agent'] ?? 'iOS').slice(0, 80)
            let existing = Object.keys(devices).find((key) => devices[key]?.name === deviceName)
            if (!existing) {
              existing = newDeviceToken()
              devices[existing] = { name: deviceName, createdAt: Date.now(), lastUsedAt: Date.now() }
              await saveDevices(devices)
            } else {
              devices[existing].lastUsedAt = Date.now()
              await saveDevices(devices)
            }
            deviceCookie = [`dsh-pocket-device=${encodeURIComponent(existing)}; Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax`]
          } catch (error) {
            await logLine(`device token issue failed: ${error?.message ?? error}`)
          }
          await logLine('pair login ok')
          const headers = { location: target, 'cache-control': 'no-store' }
          if (deviceCookie.length) headers['set-cookie'] = deviceCookie
          res.writeHead(302, headers)
          res.end()
          return
        }
        if (endpoint === 'login') {
          if (req.method !== 'POST' && req.method !== 'GET') { send(res, 405, { ok: false }); return }
          let pinAttempt = urlObject.searchParams.get('token') ?? ''
          if (req.method === 'POST') {
            const raw = await readRawBody(req)
            const contentType = String(req.headers['content-type'] ?? '')
            if (contentType.includes('application/json')) {
              try {
                const body = JSON.parse(raw)
                pinAttempt = body?.token ?? body?.pin ?? pinAttempt
              } catch { /* 非法 JSON 按未提供处理 */ }
            } else {
              pinAttempt = new URLSearchParams(raw).get('token') ?? pinAttempt
            }
          }
          const expected = await readPin()
          const attempt = String(pinAttempt ?? '')
          if (attempt !== expected) {
            await logLine(`login 401 host=${String(req.headers.host ?? '')} attemptLen=${attempt.length}`)
            send(res, 401, { ok: false })
            return
          }
          // 重定向必须回到“客户端正在使用的地址”（localhost / 局域网 / Tailscale 都可），
          // 不能固定用配置里的 Tailscale 地址，否则局域网登录会被带到不可达的域名。
          const host = String(req.headers.host ?? '')
          if (!host || typeof connection?.authenticatedUrl !== 'function') {
            send(res, 503, { ok: false })
            return
          }
          const proto = guessProto(req, host)
          const target = connection.authenticatedUrl(`${proto}://${host}/`)
          res.writeHead(302, { location: target, 'cache-control': 'no-store' })
          res.end()
          return
        }
        if (req.method !== 'POST') {
          send(res, 404, { ok: false })
          return
        }
        // body 解析容错：refresh 这类端点不需要 JSON body，
        // 之前直接 readBody 会在进入分支前抛「Unexpected end of JSON input」，
        // App 只看到 HTTP 200 + ok:false，却因为没有新 cookie 而误判「换票成功」。
        let body = {}
        try {
          body = await readBody(req)
        } catch {
          body = {}
        }
        const rpcId = typeof body?.rpcId === 'string' ? body.rpcId : ''
        // 用长期设备凭证换新的 dsh-auth cookie。
        // DSH 重启后原 cookie 失效，App 调这里拿新的，不必重新扫码。
        if (endpoint === 'refresh') {
          if (req.method !== 'POST' && req.method !== 'GET') { send(res, 405, { ok: false }); return }
          const deviceToken = deviceTokenFrom(req, urlObject)
          const devices = await readDevices()
          const record = deviceToken ? devices[deviceToken] : undefined
          if (!record) {
            await logLine('refresh rejected (unknown device)')
            send(res, 401, { ok: false })
            return
          }
          const host = String(req.headers.host ?? '')
          if (!host || typeof connection?.authenticatedUrl !== 'function') { send(res, 503, { ok: false }); return }
          const proto = guessProto(req, host)
          const target = connection.authenticatedUrl(`${proto}://${host}/`)
          record.lastUsedAt = Date.now()
          await saveDevices(devices)
          await logLine('refresh ok')
          res.writeHead(302, { location: target, 'cache-control': 'no-store' })
          res.end()
          return
        }
        // 撤销设备（用户在电脑端「已连接设备」里点删除）。
        if (endpoint === 'device.revoke') {
          const args = body?.payload?.args ?? body?.payload ?? body?.args ?? body ?? {}
          const target = String(args.device ?? args.token ?? '')
          const devices = await readDevices()
          if (target && devices[target]) {
            delete devices[target]
            await saveDevices(devices)
            await logLine('device revoked')
          }
          send(res, 200, { type: 'server-response', rpcId, result: { ok: true, value: { ok: true } } })
          return
        }
        // 列出已配对设备（供设置页展示与撤销）。
        if (endpoint === 'device.list') {
          const devices = await readDevices()
          const value = Object.entries(devices).map(([token, info]) => ({
            token: `${token.slice(0, 6)}…`,
            full: token,
            name: info?.name ?? '',
            createdAt: info?.createdAt ?? 0,
            lastUsedAt: info?.lastUsedAt ?? 0
          }))
          send(res, 200, { type: 'server-response', rpcId, result: { ok: true, value: { devices: value } } })
          return
        }
        // 切换连接方式：停掉旧隧道、启动新隧道，返回新状态。
        if (endpoint === 'mode.set') {
          const args = body?.payload?.args ?? body?.payload ?? body?.args ?? body ?? {}
          const next = String(args.mode ?? '')
          if (!MODES.includes(next)) {
            send(res, 200, { type: 'server-response', rpcId, result: { ok: false, error: { code: 'bad-request', message: `unknown mode ${next}` } } })
            return
          }
          // 互斥：切走之前先把上一种停掉，避免两个隧道进程同时跑
          if (currentMode === 'cloudflare' && next !== 'cloudflare' && cloudflareTunnel) {
            await cloudflareTunnel.stop()
          }
          currentMode = next
          await saveMode(next)
          await logLine(`mode -> ${next}`)
          // 立刻回一个轻量状态：切到 cloudflare 时隧道要下载/注册，不能阻塞在这里
          const value = { mode: next, label: MODE_LABELS[next], modes: MODES.map((id) => ({ id, label: MODE_LABELS[id] })), address: null, qr: null, state: 'starting', error: null, phase: null }
          send(res, 200, { type: 'server-response', rpcId, result: { ok: true, value } })
          return
        }
        if (endpoint === 'mode.status') {
          const value = await modeStatus()
          send(res, 200, { type: 'server-response', rpcId, result: { ok: true, value } })
          return
        }
        if (endpoint === 'pair.create') {
          const pairToken = Array.from({ length: 32 }, () => {
            const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
            return chars[Math.floor(Math.random() * chars.length)]
          }).join('')
          // 60 秒太短：从「看到二维码」到「手机上点开链接」要经过拿手机、开相机、
          // 扫、等隧道冷启动，实测很容易超时（用户反馈「显示配对已过期」）。
          // 放宽到 5 分钟，仍是一次连接的时间尺度，不会长期留后门。
          pairTokens.set(pairToken, { expiresAt: Date.now() + 300_000 })
          // 按当前连接方式取地址：Cloudflare 用 quick 隧道，Tailscale 用固定地址，
          // 都没有时回退到请求 Host（局域网直连）。
          const status = await modeStatus()
          let base = status.address
          if (!base) {
            // 回退到**局域网可达**的地址，绝不能用 req.headers.host。
            // 面板是用户在浏览器里用 http://127.0.0.1:<port> 打开的，那个 host 拼出来的
            // 二维码在手机上指向手机自己 → 扫了必失败（2026-11-15 实测：三种模式全废）。
            // 局域网没地址时最后才用 host 兜底（至少本机测试能用）。
            const lanIp = selectLanIPv4()
            if (lanIp) {
              base = `http://${lanIp}:${PROXY_PORT}`
            } else {
              const host = String(req.headers.host ?? '')
              const forwardedProto = String(req.headers['x-forwarded-proto'] ?? '').split(',')[0].trim()
              const isLoopback = /^(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/i.test(host)
              base = `${forwardedProto || (isLoopback ? 'http' : 'https')}://${host}`
            }
          }
          // **必须走插件自己的 /pair 端点**，不是根路径。
          // 之前生成的是 `${base}/?pair=`，代理会把它当普通请求转发给 DSH，
          // DSH 不认识 ?pair 参数 → 返回 401 → App 显示「无法到达电脑」。
          // 配对逻辑（校验 token、换 cookie）在 `${CHANNEL}/pair` 里（2026-11-15 定位）。
          // **App 的契约：根路径 + `?pair=`**，路径由 App 自己拼。
          // 见 ConnectionModel+Connect.swift：
          //   1. 从 URL 取 `?pair=` 的值
          //   2. POST 到 `url.appending(path: "dsh-pocket-ios/pair")`，body 用 `token=`
          //   3. 检查是否拿到 `dsh-auth*` cookie
          //
          // 所以这里必须给 `${base}/?pair=`：
          //   - 写成 `${base}${CHANNEL}/pair?...` → App 会 append 成双路径
          //   - 参数写成 `?token=` → App 会走 DSH launchToken 分支（那个每次重启都变，
          //     必然「sign in link 过期」）
          const pairURL = `${base}/?pair=${encodeURIComponent(pairToken)}`
          const qr = await QRCode.toDataURL(pairURL, { margin: 1, width: 360 })
          // 把生成的 URL 记下来（token 只留前 6 位），排查「扫出来的地址不对」时一眼可见
          await logLine(`pair token created: ${pairURL.replace(/pair=([^&]{6})[^&]*/, 'pair=$1…')}`)
          send(res, 200, { type: 'server-response', rpcId, result: { ok: true, value: { url: pairURL, qr, expiresIn: 300 } } })
          return
        }
        if (endpoint === 'pin.refresh') {
          const nextPin = String(randomInt(10_000_000, 100_000_000))
          await setPin(nextPin)
          await logLine('pin refreshed')
          const value = await tailscaleStatus()
          send(res, 200, { type: 'server-response', rpcId, result: { ok: true, value } })
          return
        }
        if (endpoint === 'pin.set') {
          const args = body?.payload?.args ?? body?.payload ?? body?.args ?? body ?? {}
          const requested = String(args.pin ?? '')
          if (!PIN_PATTERN.test(requested)) {
            send(res, 200, { type: 'server-response', rpcId, result: { ok: false, error: { code: 'bad-request', message: '密码需为 8-64 位英文字母或数字' } } })
            return
          }
          await setPin(requested)
          await logLine('pin set by user')
          const value = await tailscaleStatus()
          send(res, 200, { type: 'server-response', rpcId, result: { ok: true, value } })
          return
        }
        if (endpoint !== 'tailscale.status') {
          send(res, 200, { type: 'server-response', rpcId, result: { ok: false, error: { code: 'bad-request', message: `unknown endpoint ${endpoint}` } } })
          return
        }
        // 面板只认这一个端点：返回统一形状（含 mode/modes/address/qr/state）。
        // 兼容旧字段：httpsUrl/pin 仍在 tailscaleStatus 里，需要的话单独取。
        const value = await modeStatus()
        send(res, 200, { type: 'server-response', rpcId, result: { ok: true, value } })
      } catch (error) {
        send(res, 200, { type: 'server-response', rpcId: '', result: { ok: false, error: { code: 'bad-request', message: String(error?.message ?? error) } } })
      }
    },
  }
  try {
    webServer.register(route)
    ctx?.logger?.info?.('dsh-pocket-ios: Tailscale RPC 已挂载 /dsh-pocket-ios/tailscale.status')
  } catch (error) {
    ctx?.logger?.warn?.(`dsh-pocket-ios: 挂载 RPC 失败：${String(error?.message ?? error)}`)
  }
  return attachStableProxy(ctx, route.handler)
}
