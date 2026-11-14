import test from 'node:test'
import assert from 'node:assert/strict'

import { extractQuickTunnelUrl, findCloudflared, CloudflareTunnel, managedBinaryPath } from '../lib/cloudflare.js'

test('extractQuickTunnelUrl：从 cloudflared 的 stderr 里抓到地址', () => {
  const text = [
    '2026-11-15T05:20:00Z INF Thank you for trying Cloudflare Tunnel.',
    '2026-11-15T05:20:02Z INF +---------------------------------------------------------------+',
    '2026-11-15T05:20:02Z INF |  https://brave-tiger-lamp-1234.trycloudflare.com               |',
    '2026-11-15T05:20:02Z INF +---------------------------------------------------------------+',
  ].join('\n')
  assert.equal(extractQuickTunnelUrl(text), 'https://brave-tiger-lamp-1234.trycloudflare.com')
})

test('extractQuickTunnelUrl：去掉末尾斜杠', () => {
  assert.equal(
    extractQuickTunnelUrl('https://x-y-z.trycloudflare.com/'),
    'https://x-y-z.trycloudflare.com',
  )
})

test('extractQuickTunnelUrl：没有地址时返回 null', () => {
  assert.equal(extractQuickTunnelUrl('still starting...'), null)
  assert.equal(extractQuickTunnelUrl(''), null)
  // 只认 trycloudflare.com，不认别的域名
  assert.equal(extractQuickTunnelUrl('https://example.com'), null)
})

test('findCloudflared：本机没装时返回 null，不抛错', async () => {
  // 不能保证 CI 上没装，这里只断言「不抛错且类型正确」
  const found = await findCloudflared()
  assert.ok(found === null || typeof found === 'string')
})

test('CloudflareTunnel：stop() 幂等，未启动时调用不报错', async () => {
  const tunnel = new CloudflareTunnel({ port: 1 })
  await tunnel.stop()
  await tunnel.stop()
  assert.equal(tunnel.status().state, 'idle')
  assert.equal(tunnel.status().url, null)
})

test('CloudflareTunnel：初始状态是 idle，且不会自己启动', async () => {
  // 注意：start() 现在会**自动下载** cloudflared（约 20MB），所以测试里不能调它。
  // 这里只验证「构造出来是干净的 idle」和「stop 幂等」。
  const tunnel = new CloudflareTunnel({ port: 1 })
  assert.equal(tunnel.status().state, 'idle')
  assert.equal(tunnel.status().url, null)
  await tunnel.stop()
  assert.equal(tunnel.status().state, 'idle')
})

test('managedBinaryPath：落在 ~/.dsh/dsh-pocket-ios/bin 下', () => {
  const p = managedBinaryPath()
  assert.ok(p.includes('.dsh'))
  assert.ok(p.includes('dsh-pocket-ios'))
  assert.match(p, /cloudflared(\.exe)?$/)
})
