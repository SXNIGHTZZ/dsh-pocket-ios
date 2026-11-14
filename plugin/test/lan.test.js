import test from 'node:test'
import assert from 'node:assert/strict'

import { selectLanIPv4, lanEntryUrl } from '../lib/lan.js'

/** 造一个 networkInterfaces() 形状的对象。 */
function iface(entries) {
  const out = {}
  for (const [name, ip] of Object.entries(entries)) {
    out[name] = [{ address: ip, family: 'IPv4', internal: false }]
  }
  return out
}

test('selectLanIPv4：优先选物理网卡的私网地址', () => {
  const ip = selectLanIPv4(iface({
    en0: '192.168.1.23',
    utun3: '100.101.102.103',
  }))
  assert.equal(ip, '192.168.1.23')
})

test('selectLanIPv4：虚拟网卡即使排在前面也不选', () => {
  // Windows 上这类顺序很常见，旧实现直接取第一个就错了
  const ip = selectLanIPv4(iface({
    'vEthernet (WSL)': '172.28.0.1',
    docker0: '172.17.0.1',
    WLAN: '192.168.0.15',
  }))
  assert.equal(ip, '192.168.0.15')
})

test('selectLanIPv4：Tailscale 的 100.x 不优先于真实 Wi-Fi', () => {
  const ip = selectLanIPv4(iface({
    tailscale0: '100.64.1.2',
    en0: '10.0.0.8',
  }))
  assert.equal(ip, '10.0.0.8')
})

test('selectLanIPv4：ICS 保留段排最后', () => {
  const ip = selectLanIPv4(iface({
    'Local Area Connection* 10': '192.168.137.1',
    en0: '192.168.1.5',
  }))
  assert.equal(ip, '192.168.1.5')
})

test('selectLanIPv4：只有回环 / 链路本地时返回 null', () => {
  assert.equal(selectLanIPv4({
    lo0: [{ address: '127.0.0.1', family: 'IPv4', internal: true }],
    en0: [{ address: '169.254.3.4', family: 'IPv4', internal: false }],
  }), null)
})

test('selectLanIPv4：兼容 family 为数字 4 的老格式', () => {
  const ip = selectLanIPv4({
    en0: [{ address: '192.168.2.9', family: 4, internal: false }],
  })
  assert.equal(ip, '192.168.2.9')
})

test('lanEntryUrl：带 token 时不出现双斜杠，token 会被转义', () => {
  const url = lanEntryUrl('192.168.1.7', 3081, 'a+b/c')
  assert.equal(url, 'http://192.168.1.7:3081/?pair=a%2Bb%2Fc')
})

test('lanEntryUrl：不传 token 时是裸地址', () => {
  assert.equal(lanEntryUrl('10.0.0.2', 3081), 'http://10.0.0.2:3081')
})
