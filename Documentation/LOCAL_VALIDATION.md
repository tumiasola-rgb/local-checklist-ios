# 本机验证记录

日期：2026-10-10（Asia/Shanghai）。本次验收对象为 `LocalChecklist-iPhone` 主 App，不包含小组件、Mac 或双机同步验收。

## 环境与工作区

- macOS 14.5，Xcode 16.2（16C5032a），iOS SDK 18.2。
- 使用命令级 `DEVELOPER_DIR` 选择现有 Xcode，没有更改系统默认开发工具路径。
- 当前目录没有 Git 仓库。原始 ZIP 保持不变，作为变更对比基线；没有提交、推送或上传。
- 构建和临时验证文件保存在 `.build-check/`，不属于源码交付。

## 已验证

- 原始代码的 Swift 检查发现两处阻断：`Darwin.flock` 名称解析冲突、`setAttributes` 参数名错误。修复后主 App 和原扩展的类型检查通过。
- 独立 App 的 Swift 模块编译、151 个原生测试方法（含新增独立存储测试）的源码类型检查通过；这不是执行测试。
- 新增独立 iPhone App 和对应测试 target，使用不同 bundle ID、无扩展依赖和空 entitlements；原有 target 定义保持原样。
- 结构检查 757 项通过；独立 Python 模型/源码契约测试 33 项通过。
- 使用隔离的临时 Swift Package 在 macOS 执行已有测试：103 项 XCTest 通过、0 失败。涵盖日期、文件仓库、备份恢复、同步账本及协议等逻辑；排除依赖 iOS 界面的 AppLogic、QuickCaptureParser、TaskSchedule 测试文件。这不是 iOS 真机或双机网络验证。
- `verify_iphone.sh` 已通过 Bash 语法检查。
- iOS 18.3.1 Simulator runtime 已从 Apple 下载并安装成功。
- `bash Scripts/verify_iphone.sh simulator`：完整模拟器 Debug 构建通过，退出码 0，`BUILD SUCCEEDED`。
- `bash Scripts/verify_iphone.sh device`：完整真机 Release 构建通过，退出码 0，`BUILD SUCCEEDED`。
- 真机产物检查：arm64 可执行文件，最低 iOS 17，iPhone/iPad 设备族，不包含 `.appex`，未签名。路径为 `.build-check/iphone-device/Build/Products/Release-iphoneos/LocalChecklist-iPhone.app`。
- 14:10 重试模拟器启动成功，系统数据迁移完成；随后执行完整 `bash Scripts/verify_iphone.sh test SIMULATOR_ID`，退出码 0，`TEST SUCCEEDED`。151 项 XCTest 实际执行，0 失败、0 unexpected，运行约 13.7 秒。日志：`.build-check/iphone-tests-current.log`；结果包：`.build-check/iphone/Logs/Test/Test-LocalChecklist-iPhone-2026.10.10_14-10-24-+0800.xcresult`。
- 扫描 App、Shared、Config 和 Xcode 工程，未发现常见格式的固定真机 UDID 或固定 provisioning profile 设置。当前 Team 配置为空，App 标识仍为待配置的示例值。设备查询为 0 台，代码签名有效身份为 0 个；未连接或安装到老板手机。

## 待完成

- App 页面渲染、中文布局和手工交互：尽管模拟器启动和 XCTest 已成功，界面操作工具两次读取 Simulator 仍超时，未取得可验证截图或执行页面操作。因此 XCTest 成功不代表界面验收通过。
- 真实手机连接、开发者账号签名、安装启动及覆盖更新。
- 真机通知、图片识别、语音授权与实际离线能力、分享、备份文件交互。

没有签名证书且未连接手机时，不能产出可直接装到该手机的已签名安装包。无签名构建不能标记为安装完成。

## 历史环境问题与交付边界

早先模拟器首次启动曾长期停在 BackBoard / Data Migration，并取消过测试。该取消结果不作为测试结论；上方 14:10 的完整重跑已替代它。未清空模拟器数据。

本轮新增修改仅为安装路径说明和验证记录。原始 ZIP 未改，没有 Git 提交或对外上传。先完成本地可验证工作，再由用户确认接收人和安装方式；未给老板发消息、发文件或安装。真实签名和设备验收需要 Apple 账号及目标手机配合，不能仅靠本地构建预先完成。
