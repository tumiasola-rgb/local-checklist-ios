# 本次源码交付状态

冻结检查时间（UTC）：2026-10-06T05:59:40+00:00

- 原生目标：iPhone/iPad + Mac Catalyst独立Mac App，附两个Widget
- 最低版本：iOS17 / macOS14；真实目标系统仍待验证
- Swift源码：47份；XCTest测试方法：150个，均为已编写但未运行
- 已实际运行：566项项目/资源/配置结构检查；33项独立Python因果/协议模型与源码契约检查
- 已检查：九张用户参考图仅用于设计，源包不包含它们；媒体只有11份自制AppIcon尺寸
- 已移除：云同步实现、云容器和云权限配置；仅保留设备本地存储与显式配对的局域网交换
- 未运行：Swift解析/类型检查、Xcode Build/Archive、XCTest、模拟器、iPhone/Mac真机、真实Keychain/TLS/Bonjour握手、真实两端传输、系统权限/通知、原生UI视觉验收
- 安装状态：没有已签名IPA或Mac二进制，没有在用户设备安装。签名/App Group账号能力仍需确认

结构/模型检查不能证明App已能在设备上运行。后续先在Xcode编译并运行测试，再用可丢弃数据完成两个设备的配对、断网重试、冲突、重复任务、通知与备份恢复演练。

日志：`static-check-results.txt` 与 `sync-fixture-results.txt`。
安装与验证：项目根目录`README.md`、`IOS_MAC_LAN_SETUP.md`、`LAN_PROTOCOL.md`、`VERIFICATION.md`。
