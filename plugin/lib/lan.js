// 局域网直连模式的内网地址选择
//
// 为什么单独一个模块：`os.networkInterfaces()` 的枚举顺序完全不可靠。
// Windows 上 Radmin VPN / Tailscale / vEthernet 这些虚拟网卡常排在 WLAN 前面，
// 直接取「第一个非回环地址」会生成手机根本打不开的二维码。
//
// 实测踩过的坑（2026-11-15 用户反馈「同一 WiFi 扫码显示密码错误」的其中一类）：
// 手机连的是真 Wi-Fi，二维码里却是 Docker/VPN 网段的地址，扫码后连不上。

import { networkInterfaces } from 'node:os'

/** RFC1918 私网地址：这类最可能是手机能到达的那个。 */
const PRIVATE_IPV4 = /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/

/** 物理网卡名（macOS en0/en1、Windows WLAN/以太网、Linux wlan/eth）。 */
const PHYSICAL = /^(en\d|wlan\d*|wl\w+|eth\d+|WLAN|以太网|本地连接)/i

/** 明显是虚拟网卡的（VPN、容器、虚拟机、热点共享）。 */
const VIRTUAL = /(tailscale|utun|tun\d|tap\d|wg\d|zerotier|radmin|docker|veth|br-|vmnet|vboxnet|hyper-v|vEthernet|WSL|ppp\d)/i

/** 移动热点 / ICS 共享虚拟网卡的保留段，最后的兜底也不选它。 */
const ICS_SUBNET = '192.168.137.'

/**
 * 从 networkInterfaces() 里挑出手机最可能连上的那个 IPv4。
 *
 * 打分规则：
 *   +100  RFC1918 私网地址
 *   +20   名字像物理网卡
 *   -50   名字像 VPN/虚拟网卡
 *
 * 同分时保持枚举顺序，但把 ICS 保留段排到最后。
 *
 * @param {ReturnType<typeof networkInterfaces>} [interfaces]
 * @returns {string|null}
 */
export function selectLanIPv4(interfaces = networkInterfaces()) {
  const candidates = []
  let order = 0

  for (const [name, addresses] of Object.entries(interfaces ?? {})) {
    for (const address of addresses ?? []) {
      // Node 18+ 的 family 是字符串 'IPv4'；老版本是数字 4，两种都认
      const isIPv4 = address.family === 'IPv4' || address.family === 4
      if (!isIPv4 || address.internal) continue

      const ip = address.address
      if (!ip || ip.startsWith('127.') || ip.startsWith('169.254.')) continue

      let score = 0
      if (PRIVATE_IPV4.test(ip)) score += 100
      if (PHYSICAL.test(name)) score += 20
      else if (VIRTUAL.test(name)) score -= 50

      candidates.push({ ip, score, order: order++ })
    }
  }

  candidates.sort((a, b) => {
    if (b.score !== a.score) return b.score - a.score
    // 同分：非 ICS 段优先
    const aIcs = a.ip.startsWith(ICS_SUBNET)
    const bIcs = b.ip.startsWith(ICS_SUBNET)
    if (aIcs !== bIcs) return aIcs ? 1 : -1
    return a.order - b.order
  })

  return candidates[0]?.ip ?? null
}

/**
 * 组装局域网入口 URL。
 *
 * @param {string} ip 内网地址
 * @param {number} port dsh web 端口
 * @param {string} [pairToken] 可选配对 token；给了就带上，扫码即免密
 * @returns {string}
 */
export function lanEntryUrl(ip, port, pairToken) {
  const base = `http://${ip}:${port}`
  return pairToken ? `${base}/?pair=${encodeURIComponent(pairToken)}` : base
}
