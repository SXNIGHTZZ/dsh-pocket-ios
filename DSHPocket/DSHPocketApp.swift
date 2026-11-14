// 应用入口

import SwiftUI
import Security
import Textual
import DSHKit
import VisionKit
import AVFoundation
import Observation
import PhotosUI
import UIKit
import Photos
import os
import AudioToolbox
import ImageIO
import UserNotifications


@main
struct DSHPocketApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @State private var model = ConnectionModel()

    init() {
        // 记录启动瞬间的内存，用来判断「空载高」是框架开销还是我们自己的问题。
        // 写到文件而不是 os.Logger：真机上只有文件能用 devicectl 直接拷出来。
        DiagFileLog.reset()
        DiagFileLog.log("boot-t0 footprint=\(Int(Diagnostics.memoryFootprintMB()))MB")
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, sessionStore: model.sessionStore)
                .preferredColorScheme(.light)
        }
    }
}
