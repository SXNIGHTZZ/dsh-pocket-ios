// cloudflared 自动下载
//
// 为什么要有这个：Cloudflare 隧道是"手机零安装"的唯一路径，如果连电脑端都要先
// 装 Homebrew 再 brew install cloudflared，那"扫码即连"这个卖点就没了。
// 所以首次使用时自动下 20MB 二进制，用户什么都不用管。
//
// 国内网络是主要场景，所以下载做了三层优化（都是实测出来的）：
//   1. 多源：官方 GitHub 在国内经常几十 KB/s，准备好国内加速源兜底
//   2. 探针测速：先下 2MB 看速度，够快就单线程（多线程在部分 CDN 反而更慢）
//   3. 慢就 8 段并发：能把 200KB/s 拉到 1.6MB/s 量级
//
// 和 `dsh-pocket` 的实现思路一致，但代码是独立写的。

import { createWriteStream } from 'node:fs'
import { mkdir, rm, stat } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { Readable } from 'node:stream'
import { pipeline } from 'node:stream/promises'

/** 一个文件小于这个大小，几乎肯定是镜像返回的 HTML 错误页而不是二进制。 */
const MIN_VALID_BYTES = 1024 * 1024

/** 小于这个大小不值得分块（分块有固定开销）。 */
const MIN_PARALLEL_BYTES = 8 * 1024 * 1024

/** 探针大小：先单线程下这么多测速，再决定用什么策略。 */
const PROBE_BYTES = 2 * 1024 * 1024

/** 探针速度阈值（bytes/ms）。低于它认为网络慢，转分块（0.3 = 300KB/s）。 */
const SLOW_THRESHOLD = 0.3

/** 分块并发数。8 是实测比较稳的值：再高容易触发 CDN 限速。 */
const SEGMENTS = 8

/** 单次下载整体超时。20MB 在 100KB/s 下约需 200 秒，给足余量。 */
const DOWNLOAD_TIMEOUT_MS = 120_000

/** 国内可达的 GitHub 加速前缀（2026-08 实测）。 */
const GITHUB_MIRRORS = [
  '',
  'https://ghproxy.net/',
  'https://gh.ddlc.top/',
  'https://gh-proxy.com/',
]

/** 清华 Homebrew bottle 目录（macOS 走这里，国内 CDN）。 */
const TUNA_BOTTLES = 'https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/'

/**
 * 当前平台对应的 cloudflared 发布资产名。
 *
 * 注意三者不一样（上游的发布布局）：
 *   - macOS：`cloudflared-darwin-<arch>.tgz`（要解压）
 *   - Linux：`cloudflared-linux-<arch>`（裸二进制，没有 .tgz）
 *   - Windows：`cloudflared-windows-<arch>.exe`
 *
 * 曾经有人给 Linux 拼 `.tgz`，而它根本不存在——五个源全 404，
 * 表现是"Linux 上永远装不上、macOS 一切正常"。这里按平台分开。
 *
 * @returns {{ asset: string, isArchive: boolean, exeSuffix: string }}
 */
export function platformAsset(platform = process.platform, arch = process.arch) {
  const archName = ({ x64: 'amd64', arm64: 'arm64', ia32: '386', arm: 'arm' })[arch] ?? arch
  if (platform === 'win32') {
    return { asset: `cloudflared-windows-${archName}.exe`, isArchive: false, exeSuffix: '.exe' }
  }
  if (platform === 'darwin') {
    return { asset: `cloudflared-darwin-${archName}.tgz`, isArchive: true, exeSuffix: '' }
  }
  return { asset: `cloudflared-linux-${archName}`, isArchive: false, exeSuffix: '' }
}

/**
 * 依次给出候选下载地址（先官方，再国内加速）。
 * @param {string} asset 资产名
 * @returns {string[]}
 */
export function mirrorUrls(asset) {
  const official = `https://github.com/cloudflare/cloudflared/releases/latest/download/${asset}`
  return GITHUB_MIRRORS.map((prefix) => (prefix ? `${prefix}${official}` : official))
}

/**
 * macOS 上从清华镜像找一个可用的 Homebrew bottle（比 GitHub 快得多）。
 *
 * bottle 名形如 `cloudflared-2024.8.0.arm64_sonoma.bottle.tar.gz`，
 * 取目录里版本号最大的那个。抓不到就返回 null（调用方回退 GitHub）。
 *
 * @returns {Promise<string|null>}
 */
export async function findTunaBottle({ arch = process.arch, signal } = {}) {
  let res
  try {
    res = await fetch(TUNA_BOTTLES, { signal: signal ?? AbortSignal.timeout(20_000) })
  } catch { return null }
  if (!res.ok) return null

  let html = ''
  try { html = await res.text() } catch { return null }

  // 只认 macOS 的代号，避免把 linux bottle 当成 macOS 的
  const codes = 'monterey|ventura|sonoma|sequoia|tahoe'
  const archPrefix = arch === 'arm64' ? 'arm64_' : ''
  const pattern = new RegExp(`cloudflared-([0-9.]+)\\.${archPrefix}(${codes})\\.bottle\\.tar\\.gz`, 'g')

  let bestName = null
  let bestVersion = ''
  for (const match of html.matchAll(pattern)) {
    if (match[1] > bestVersion) {
      bestVersion = match[1]
      bestName = match[0]
    }
  }
  return bestName ? `${TUNA_BOTTLES}${bestName}` : null
}

/** 把多个分段文件按顺序拼成一个。 */
async function concatFiles(parts, dest) {
  const out = createWriteStream(dest)
  try {
    for (const part of parts) {
      const { createReadStream } = await import('node:fs')
      await new Promise((resolve, reject) => {
        const stream = createReadStream(part)
        stream.on('error', reject)
        stream.on('end', resolve)
        stream.pipe(out, { end: false })
      })
    }
  } finally {
    await new Promise((resolve) => out.end(resolve))
  }
}

/**
 * 自适应下载一个文件到 dest。
 *
 * 策略：
 *   1. HEAD 拿长度；不支持 Range 或文件小 → 单线程
 *   2. 单线程下探针（2MB）测速
 *   3. 够快 → 继续单线程（多线程在部分 CDN 会被限速，反而更慢）
 *   4. 慢 → 丢弃探针，8 段并发重下
 *
 * @param {string} url
 * @param {string} dest
 * @param {{ signal?: AbortSignal }} [options]
 * @returns {Promise<number>} 下载字节数
 */
export async function downloadAdaptive(url, dest, { signal } = {}) {
  const scope = signal ? AbortSignal.any([signal, AbortSignal.timeout(DOWNLOAD_TIMEOUT_MS)])
    : AbortSignal.timeout(DOWNLOAD_TIMEOUT_MS)

  let total = 0
  let acceptsRanges = false
  try {
    const head = await fetch(url, { method: 'HEAD', signal: scope })
    total = Number(head.headers.get('content-length') ?? 0)
    acceptsRanges = String(head.headers.get('accept-ranges') ?? '').toLowerCase() === 'bytes'
  } catch { /* HEAD 失败就按单线程走 */ }

  const simple = () => downloadSingle(url, dest, scope)

  if (!acceptsRanges || total < MIN_PARALLEL_BYTES) return simple()

  // 探针测速
  const probeSize = Math.min(PROBE_BYTES, total)
  const startedAt = Date.now()
  let probeBody = null
  try {
    const res = await fetch(url, { signal: scope, headers: { Range: `bytes=0-${probeSize - 1}` } })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    probeBody = Buffer.from(await res.arrayBuffer())
  } catch {
    // 探针失败（部分服务器的 HEAD/GET 行为不一致）→ 直接分块
    return downloadParallel(url, dest, total, scope)
  }

  const elapsed = Date.now() - startedAt
  const speed = elapsed > 0 ? probeSize / elapsed : Number.POSITIVE_INFINITY

  if (elapsed < 500 || speed >= SLOW_THRESHOLD) {
    // 够快：探针内容就是文件开头，接着把剩余部分下完
    const out = createWriteStream(dest)
    await new Promise((resolve, reject) => {
      out.on('error', reject)
      out.write(probeBody)
      out.end(resolve)
    })
    const restRes = await fetch(url, {
      signal: scope,
      headers: { Range: `bytes=${probeSize}-${total - 1}` },
    })
    if (!restRes.ok) throw new Error(`HTTP ${restRes.status}`)
    await pipeline(Readable.fromWeb(restRes.body), createWriteStream(dest, { flags: 'a' }))
    return total
  }

  // 慢：丢弃探针，全量分块
  await rm(dest, { force: true }).catch(() => {})
  return downloadParallel(url, dest, total, scope)
}

/** 单线程整段下载。 */
async function downloadSingle(url, dest, signal) {
  const res = await fetch(url, { signal })
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  await pipeline(Readable.fromWeb(res.body), createWriteStream(dest))
  const { size } = await stat(dest)
  return size
}

/** 分块并发下载后拼接。 */
async function downloadParallel(url, dest, total, signal) {
  const chunk = Math.ceil(total / SEGMENTS)
  const parts = []
  for (let i = 0; i < SEGMENTS; i++) {
    const start = i * chunk
    const end = i === SEGMENTS - 1 ? total - 1 : Math.min(start + chunk - 1, total - 1)
    if (start > end) break
    parts.push({ start, end, file: `${dest}.part${i}` })
  }
  try {
    await Promise.all(parts.map(async (part) => {
      const res = await fetch(url, {
        signal,
        headers: { Range: `bytes=${part.start}-${part.end}` },
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      await pipeline(Readable.fromWeb(res.body), createWriteStream(part.file))
    }))
    await concatFiles(parts.map((p) => p.file), dest)
  } finally {
    await Promise.all(parts.map((p) => rm(p.file, { force: true }).catch(() => {})))
  }
  const { size } = await stat(dest)
  return size
}

/**
 * 解压 .tgz 并把里面的 cloudflared 二进制挪到 targetPath。
 *
 * 两种包结构都要能处理：
 *   - GitHub 的 darwin tgz：解压后是顶层 `cloudflared` 文件
 *   - 清华的 Homebrew bottle：解压成 `cloudflared/<版本>/bin/cloudflared`
 *
 * **解压到独立临时目录**，不直接在 bin/ 里解。以前直接在 bin/ 解，
 * bottle 解出来的 `cloudflared/` 目录会占住目标名，rename 时 EISDIR；
 * 而且在 bin/ 里清理容易把刚生成的目标文件一起删掉（两个坑都踩过，2026-11-15）。
 */
async function extractTgz(archivePath, targetPath) {
  const { execFile } = await import('node:child_process')
  const { mkdtemp, rename, rm: rmAsync } = await import('node:fs/promises')
  const { tmpdir } = await import('node:os')

  const workDir = await mkdtemp(join(tmpdir(), 'cloudflared-extract-'))
  try {
    await new Promise((resolve, reject) => {
      execFile('tar', ['-xzf', archivePath, '-C', workDir], (error) =>
        error ? reject(error) : resolve())
    })

    // 递归找名叫 cloudflared 的**普通文件**（bottle 里藏在 <版本>/bin/ 下）
    const found = await new Promise((resolve, reject) => {
      execFile('find', [workDir, '-name', 'cloudflared', '-type', 'f'], (err, stdout) => {
        if (err) return reject(err)
        resolve(String(stdout).trim().split('\n').filter(Boolean)[0] ?? null)
      })
    })
    if (!found) throw new Error('解压后没找到 cloudflared 可执行文件')

    // 先挪到 targetPath 旁边的临时名，再原子 rename —— 避免目标已存在时失败
    const staged = `${targetPath}.new`
    await rmAsync(staged, { force: true }).catch(() => {})
    await rename(found, staged)
    await rename(staged, targetPath)
  } finally {
    // 只删临时目录，绝不碰 bin/ 里的东西
    await rmAsync(workDir, { recursive: true, force: true }).catch(() => {})
  }
}

/**
 * 确保 cloudflared 可用：已存在就用现成的，否则多源下载。
 *
 * @param {string} targetPath 期望的二进制绝对路径
 * @param {{ signal?: AbortSignal, onPhase?: (phase: string, detail?: string) => void }} [options]
 * @returns {Promise<string>} 可执行文件路径
 */
export async function ensureCloudflared(targetPath, { signal, onPhase = () => {} } = {}) {
  // 已有可执行文件 → 直接返回（升级交给用户，避免每次启动都查版本）
  try {
    const info = await stat(targetPath)
    if (info.size > MIN_VALID_BYTES) return targetPath
  } catch { /* 没装过 */ }

  await mkdir(dirname(targetPath), { recursive: true })
  const { asset, isArchive, exeSuffix } = platformAsset()
  const tmp = join(dirname(targetPath), `cloudflared.download${exeSuffix}`)

  // 候选源：macOS 先试清华 bottle（国内快），再试 GitHub 及其加速
  const sources = []
  if (process.platform === 'darwin' && isArchive) {
    onPhase('locating', '查询清华镜像…')
    const bottle = await findTunaBottle({ signal }).catch(() => null)
    if (bottle) sources.push({ url: bottle, host: 'mirrors.tuna.tsinghua.edu.cn', archive: true })
  }
  for (const url of mirrorUrls(asset)) {
    sources.push({ url, host: new URL(url).host, archive: isArchive })
  }

  let lastError = null
  for (let i = 0; i < sources.length; i++) {
    const source = sources[i]
    onPhase('downloading', `源 ${i + 1}/${sources.length}：${source.host}`)
    try {
      await rm(tmp, { force: true }).catch(() => {})
      const bytes = await downloadAdaptive(source.url, tmp, { signal })
      if (bytes < MIN_VALID_BYTES) {
        throw new Error(`文件过小（${bytes} 字节），疑似镜像错误页`)
      }
      if (source.archive) {
        onPhase('extracting', '解压…')
        await extractTgz(tmp, targetPath)
      } else {
        const { rename, chmod } = await import('node:fs/promises')
        await rename(tmp, targetPath)
        await chmod(targetPath, 0o755)
      }
      await rm(tmp, { force: true }).catch(() => {})
      onPhase('ready')
      return targetPath
    } catch (error) {
      lastError = error
      await rm(tmp, { force: true }).catch(() => {})
      onPhase('retrying', `${source.host} 失败：${error?.message ?? error}`)
    }
  }

  throw new Error(
    `cloudflared 下载失败，所有源都不通（最后错误：${lastError?.message ?? lastError}）。`
    + '可以手动安装后重试：macOS 执行 brew install cloudflared，'
    + `或把可执行文件放到 ${targetPath}`,
  )
}
