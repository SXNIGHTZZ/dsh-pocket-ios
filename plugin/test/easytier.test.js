import test from 'node:test'
import assert from 'node:assert/strict'

import {
  extractWireGuardConfig,
  patchEndpoint,
  coreCommand,
  randomNetwork,
  findEasytier,
} from '../lib/easytier.js'

const SAMPLE = `2026-11-15 INF some log line
[Interface]
Address = 10.144.144.3/32
PrivateKey = abc123=
DNS = 10.144.144.1

[Peer]
PublicKey = xyz789=
AllowedIPs = 10.144.144.0/24, 192.168.1.0/24
Endpoint = 0.0.0.0:11011
PersistentKeepalive = 25`

test('extractWireGuardConfig：从带日志的输出里截出配置', () => {
  const out = extractWireGuardConfig(SAMPLE)
  assert.ok(out)
  assert.ok(out.startsWith('[Interface]'))
  assert.ok(out.includes('[Peer]'))
  // 前缀的日志行不能混进来
  assert.ok(!out.includes('INF some log line'))
})

test('extractWireGuardConfig：缺 [Peer] 视为无效', () => {
  assert.equal(extractWireGuardConfig('[Interface]\nAddress = 1.2.3.4/32'), null)
})

test('extractWireGuardConfig：完全没配置时返回 null', () => {
  assert.equal(extractWireGuardConfig('no config here'), null)
  assert.equal(extractWireGuardConfig(''), null)
})

test('patchEndpoint：把通配 Endpoint 换成实际主机', () => {
  const out = patchEndpoint(SAMPLE, '192.168.1.18', 11011)
  assert.match(out, /Endpoint = 192\.168\.1\.18:11011/)
  assert.ok(!out.includes('0.0.0.0'))
})

test('patchEndpoint：没有 Endpoint 行时补进 [Peer] 段', () => {
  const noEndpoint = `[Interface]
Address = 10.0.0.2/32

[Peer]
PublicKey = k=
AllowedIPs = 10.0.0.0/24`
  const out = patchEndpoint(noEndpoint, 'example.com', 11011)
  assert.match(out, /Endpoint = example\.com:11011/)
  // 必须在 [Peer] 之后
  assert.ok(out.indexOf('Endpoint') > out.indexOf('[Peer]'))
})

test('patchEndpoint：没给 host 时原样返回', () => {
  assert.equal(patchEndpoint(SAMPLE, '', 11011), SAMPLE)
})

test('coreCommand：包含所有必需参数', () => {
  const cmd = coreCommand({
    networkName: 'dsh-abc',
    networkSecret: 'sec123',
    portalPort: 11011,
    peers: 'tcp://public.easytier.cn:11010',
  })
  assert.ok(cmd.startsWith('sudo easytier-core'))
  assert.ok(cmd.includes('--network-name dsh-abc'))
  assert.ok(cmd.includes('--network-secret sec123'))
  assert.ok(cmd.includes('--vpn-portal wg://0.0.0.0:11011'))
  assert.ok(cmd.includes('--vpn-portal-client phone='))
  assert.ok(cmd.includes('-p tcp://public.easytier.cn:11010'))
})

test('randomNetwork：网络名带前缀且长度稳定', () => {
  const a = randomNetwork()
  const b = randomNetwork()
  assert.match(a.networkName, /^dsh-[a-z0-9]{8}$/)
  assert.match(a.networkSecret, /^[a-z0-9]{16}$/)
  // 两次不能一样（撞名会导致组网失败）
  assert.notEqual(a.networkName, b.networkName)
})

test('findEasytier：没装时返回 null，不抛错', async () => {
  const found = await findEasytier()
  assert.ok(found.core === null || typeof found.core === 'string')
  assert.ok(found.cli === null || typeof found.cli === 'string')
})
