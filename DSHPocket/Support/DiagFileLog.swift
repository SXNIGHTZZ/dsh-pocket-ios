// DiagFileLog

import Foundation

/// 写文件的诊断日志。
///
/// 为什么不用 `os.Logger`：unified log 在真机上要靠 `log stream --device` 才读得到，
/// 而 `devicectl device console` 只显示 stdout——排查时等于没打。
/// 这个实现把行追加到沙盒 Documents 下的固定文件，`devicectl device copy` 能直接拷出来。
enum DiagFileLog {
    private static let queue = DispatchQueue(label: "com.ruska.dsh-pocket-ios.diaglog", qos: .utility)
    private static var url: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("diag.log")
    }
    /// 单文件上限。超过后**只丢最旧的部分**，保留最后 256 KB。
    private static let maxBytes = 512 * 1024
    /// 截断后保留的尾部大小。取一半：既能压到上限内，又不至于刚清完立刻再满。
    private static let keepBytes = maxBytes / 2

    static func reset() {
        queue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func log(_ message: String) {
        let line = "\(Self.stamp()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            let manager = FileManager.default
            if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > maxBytes {
                // 曾经是直接删文件——那会把**最近的**记录一起丢掉，而排查时最需要最新的。
                // 现在保留尾部 keepBytes：丢最旧的，留最新的。
                Self.trimToTail()
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// 只保留文件最后 keepBytes，并且**从整行开始**（不能留半行，否则时间戳会缺一半）。
    private static func trimToTail() {
        guard let data = try? Data(contentsOf: url), data.count > keepBytes else { return }
        let from = data.count - keepBytes
        let newline: UInt8 = 0x0A
        var start = from
        while start < data.count, data[start] != newline { start += 1 }
        if start < data.count { start += 1 }     // 跳过那个换行，从下一行开头写
        guard start < data.count else { return }
        try? data.subdata(in: start..<data.count).write(to: url, options: .atomic)
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
