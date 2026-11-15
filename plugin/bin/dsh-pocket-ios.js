#!/usr/bin/env node
/**
 * dsh-pocket-ios CLI
 *
 * 给「DSH 装在无 GUI 的服务器上」的场景用：那里没有「设置 → 手机访问（iOS）」
 * 页面可以看二维码，只能在终端里出码。
 *
 * 为什么不自己起隧道：插件已经在 DSH 进程内管着隧道/虚拟网络，CLI 只要问它
 * 要当前连接方式对应的配对地址即可（pair.create 返回的地址已经按模式算好了）。
 *
 * 认证走已有的两端点，不需要插件额外开接口：
 *   1. POST /dsh-pocket-ios/login      body: token=<访问密码>  → 换 cookie
 *   2. POST /dsh-pocket-ios/pair.create 带 cookie              → 拿配对 URL
 */

import { readFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'

const DEFAULT_PORT = Number(process.env.DSH_POCKET_IOS_PROXY_PORT ?? 3091)
const CHANNEL = '/dsh-pocket-ios'

/** 解析命令行参数。 */
const COMMANDS = ['pair', 'status', 'mode', 'doctor']

function parseArgs(argv) {
  const opts = { port: DEFAULT_PORT, host: '127.0.0.1', format: 'terminal', command: 'pair' }
  // 第一个非选项参数就是子命令
  const first = argv.find((a) => !a.startsWith('-'))
  if (first && COMMANDS.includes(first)) opts.command = first
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--port' || a === '-p') opts.port = Number(argv[++i])
    else if (a === '--host') opts.host = String(argv[++i])
    else if (a === '--png') { opts.format = 'png'; opts.pngPath = argv[++i] }
    else if (a === '--json') opts.format = 'json'
    else if (a === '--url') opts.format = 'url'
    else if (a === '--help' || a === '-h') opts.help = true
    else if (COMMANDS.includes(a)) { /* 子命令已在上面识别 */ }
    else if (!a.startsWith('-') && opts.command === 'mode' && !opts.modeArg) { opts.modeArg = a }
    else if (!a.startsWith('-')) { if (a !== 'pair') opts.unknown = a; }
  }
  return opts
}

/**
 * 向插件要一个配对地址。
 *
 * 走 `/dsh-pocket-ios/cli.pair`：该端点免 cookie、但插件内部会校验来源必须是
 * 127.0.0.1/::1，所以只有本机（也就是这台服务器上的终端）能调。
 * 不能用 `pair.create`——它要过 DSH 的 browser-auth（Host 白名单），
 * CLI 的 Host 不在里面，必然 401。
 */
async function pairUrl({ host, port }) {
  const base = `http://${host}:${port}`
  const res = await fetch(`${base}${CHANNEL}/cli.pair`, { method: 'POST' })
  const text = await res.text()
  if (!res.ok) {
    let detail = text.slice(0, 160)
    try { detail = JSON.parse(text)?.error ?? detail } catch { /* 非 JSON */ }
    throw new Error(`取配对地址失败（HTTP ${res.status}）：${detail}`)
  }
  let body
  try { body = JSON.parse(text) } catch { throw new Error('插件返回的不是 JSON') }
  const value = body?.result?.value ?? body?.value
  if (!value?.url) throw new Error('插件没有返回配对地址（当前连接方式可能还没就绪）')
  return value
}

const CHANNEL_PREFIX = CHANNEL

/** 调 /cli.status 拿当前连接方式状态。 */
async function fetchStatus({ host, port }) {
  const base = `http://${host}:${port}`
  const res = await fetch(`${base}${CHANNEL_PREFIX}/cli.status`, { method: 'POST' })
  const text = await res.text()
  if (!res.ok) throw new Error(`取状态失败（HTTP ${res.status}）：${text.slice(0, 120)}`)
  const body = JSON.parse(text)
  return body?.result?.value ?? body?.value
}

/** 调 /cli.mode 切换连接方式。 */
async function switchMode({ host, port, mode }) {
  const base = `http://${host}:${port}`
  const res = await fetch(`${base}${CHANNEL_PREFIX}/cli.mode`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ mode }),
  })
  const text = await res.text()
  if (!res.ok) {
    let detail = text.slice(0, 160)
    try { detail = JSON.parse(text)?.error ?? detail } catch { /* 非 JSON */ }
    throw new Error(`切换失败（HTTP ${res.status}）：${detail}`)
  }
  const body = JSON.parse(text)
  return body?.result?.value ?? body?.value
}

/** 打印状态。 */
function printStatus(v) {
  const stateLabel = { ready: '就绪', starting: '启动中', needs_setup: '未配置', 'needs-setup': '未配置', error: '出错', idle: '空闲' }[v.state] ?? v.state ?? '—'
  console.log('')
  console.log(`  连接方式  ${v.mode ?? '—'}`)
  console.log(`  状态      ${stateLabel}`)
  console.log(`  地址      ${v.address ?? '（还没有地址）'}`)
  if (v.error) console.log(`  错误      ${v.error}`)
  console.log(`  访问密码  ${v.pinSet ? '已设置' : '未设置'}`)
  console.log(`  可选方式  ${(v.modes ?? []).join(' / ')}`)
  console.log('')
}

/** 诊断：状态 + 各方式的依赖是否装好。 */
async function runDoctor(opts) {
  let ok = true
  console.log('')
  console.log('  DSH Pocket iOS · 连接诊断')
  console.log('  ' + '─'.repeat(46))

  let status = null
  try {
    status = await fetchStatus(opts)
    console.log(`  插件端口   127.0.0.1:${opts.port}  可达 ✅`)
  } catch (error) {
    ok = false
    console.log(`  插件端口   127.0.0.1:${opts.port}  不可达 ❌`)
    console.log(`             ${error.message}`)
    console.log('             先确认 DSH 在跑、且装了 dsh-pocket-ios 并重启过。')
  }
  if (status) {
    console.log(`  当前方式   ${status.mode}（${status.state}）`)
    console.log(`  地址       ${status.address ?? '（还没有）'}`)
    if (status.error) console.log(`  错误       ${status.error}`)
  }

  // 依赖探测：在本机执行 which，判断各方式的前置条件
  const { execFile } = await import('node:child_process')
  const { promisify } = await import('node:util')
  const execFileP = promisify(execFile)
  const probe = async (cmd, args = ['--version']) => {
    try { await execFileP(cmd, args, { timeout: 5000 }); return true } catch { return false }
  }
  const hasTailscale = await probe('tailscale', ['version'])
  const hasCloudflared = await probe('cloudflared', ['--version'])
  console.log(`  tailscale  ${hasTailscale ? '已安装 ✅' : '未安装（Tailscale 方式需要）'}`)
  console.log(`  cloudflared ${hasCloudflared ? '已安装 ✅' : '未安装（Cloudflare 方式首次会自动下载）'}`)

  console.log('  ' + '─'.repeat(46))
  console.log(ok ? '  看起来没问题。扫码连不上时先看上面「地址」这一行。' : '  有项目没通过，按上面提示处理。')
  console.log('')
  if (!ok) process.exitCode = 1
}

async function main() {
  const opts = parseArgs(process.argv.slice(2))
  if (opts.help) {
    console.log(`用法: npx dsh-pocket-ios <命令> [选项]

服务器上（没有图形界面）用这些命令管理连接。

命令:
  pair                    生成一次性配对二维码（默认）
  status                  查看当前连接方式、地址、是否就绪
  mode <名称>             切换连接方式：lan | cloudflare | tailscale | easytier
  doctor                  诊断：端口可达性、依赖是否装好

选项:
  -p, --port <端口>       插件代理端口（默认 ${DEFAULT_PORT}）
      --host <主机>       默认 127.0.0.1
      --url               只输出配对地址，不打印二维码
      --png <路径>        生成 PNG 二维码文件（方便传到手机扫）
      --json              输出 JSON（便于脚本消费）
  -h, --help              显示帮助

示例:
  npx dsh-pocket-ios pair                    # 终端里出二维码
  npx dsh-pocket-ios pair --png ~/q.png      # 存成图片
  npx dsh-pocket-ios status                  # 现在连的是哪条路
  npx dsh-pocket-ios mode tailscale          # 切到 Tailscale
  npx dsh-pocket-ios doctor                  # 连不上时先跑这个

配对地址默认 10 分钟有效；过期后重跑 pair 即可。`)
    return
  }
  if (opts.unknown) throw new Error(`未知参数: ${opts.unknown}`)

  if (opts.command === 'status') {
    const v = await fetchStatus({ host: opts.host, port: opts.port })
    if (opts.format === 'json') { console.log(JSON.stringify(v, null, 2)); return }
    printStatus(v)
    return
  }
  if (opts.command === 'doctor') {
    await runDoctor({ host: opts.host, port: opts.port })
    return
  }
  if (opts.command === 'mode') {
    const mode = (opts.modeArg || '').trim()
    if (!mode) {
      const v = await fetchStatus({ host: opts.host, port: opts.port })
      throw new Error(`用法：npx dsh-pocket-ios mode <${(v.modes ?? []).join('|')}>`)
    }
    const v = await switchMode({ host: opts.host, port: opts.port, mode })
    console.log(`\n  已切换到 ${v.mode}（${v.state}）${v.address ? '\n  地址 ' + v.address : ''}\n`)
    return
  }

  const { url, expiresIn } = await pairUrl({ host: opts.host, port: opts.port })

  if (opts.format === 'json') {
    console.log(JSON.stringify({ url, expiresIn }, null, 2))
    return
  }
  if (opts.format === 'url') {
    console.log(url)
    return
  }

  const QRCode = (await import('qrcode')).default

  // --png：生成图片文件。服务器场景常需要这个——终端里的 ASCII 二维码
  // 没法直接发给手机，生成为 PNG 后可以 scp / 微信 / iCloud 传过去扫。
  if (opts.format === 'png') {
    const outPath = opts.pngPath || `pair-qr-${Date.now()}.png`
    await QRCode.toFile(outPath, url, { width: 720, margin: 2 })
    console.log('')
    console.log(`  配对地址  ${url}`)
    console.log(`  二维码    ${outPath}`)
    console.log(`  有效期    ${Math.round((expiresIn ?? 600) / 60)} 分钟`)
    console.log('')
    console.log('  把这张图片传到手机，用 DSH Pocket 扫即可')
    console.log('')
    return
  }

  const art = await QRCode.toString(url, { type: 'terminal', small: true, margin: 1 })
  const minutes = Math.round((expiresIn ?? 600) / 60)
  console.log('')
  console.log(`  配对地址  ${url}`)
  console.log(`  有效期    ${minutes} 分钟（过期后重跑本命令）`)
  console.log('')
  console.log(art)
  console.log('  用手机上的 DSH Pocket 扫上面的二维码即可连接')
  console.log('')
}

main().catch((error) => {
  console.error(`\n出错: ${error.message}\n`)
  process.exit(1)
})
