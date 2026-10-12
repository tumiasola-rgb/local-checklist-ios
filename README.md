# 本地清单 · iPhone App 与 TestFlight 测试分发

这个仓库用于保存“本地清单”iPhone App 的源码，并接入 Apple 官方的 **Xcode Cloud 云端构建**和 **TestFlight 测试分发**。

目标是让指定测试者在异地 iPhone 上方便安装、测试和接收更新，无需提供手机 UDID，也无需连接开发者的 Mac。本阶段不公开上架 App Store。

## 三个平台分别做什么

| 平台 | 用途 |
| --- | --- |
| GitHub 仓库 | 保存源码、记录修改，为 Xcode Cloud 提供构建来源；当前仓库公开可见 |
| Xcode Cloud | 在苹果服务器上编译、测试、签名，并把构建上传至 App Store Connect |
| TestFlight | 通过苹果官方 App 向受邀测试者提供安装和更新 |

GitHub 仓库和源码 ZIP 不能直接安装到 iPhone。测试者最终使用的是 TestFlight 中处理完成、获得测试资格的 App 构建。

## App 做什么

“本地清单”用于管理日历、待办、笔记、搜索和纪念日，包含日期与时间段、提醒、重复设置、图片与语音快速录入、单条图片分享及备份导入导出。

本次交付只构建独立 iPhone 主 App。原始工程中的小组件、Mac 及局域网同步相关代码保留，但不作为本次交付和云端构建的目标。

## 当前进度（2026 年 10 月 12 日）

- 原有 iOS 构建通过，151 项 iOS 自动化测试通过。
- 之前已生成并核验 Ad Hoc 签名安装包；该结果不代表 TestFlight 上传已完成。
- 云端工程副本已配置公司自动签名，共享构建方案和结构检查通过。
- Xcode Cloud 接入、首次云端构建、App Store Connect 上传处理和外部 Beta 审核尚未完成。
- iPhone 真机安装、启动、数据保存、权限和提醒仍需实测，暂不投入重要资料。

## 如何构建

- 工程：`LocalChecklist.xcodeproj`
- Scheme：`LocalChecklist-iPhone`
- 公司 Team：`YX469H39GT`
- App 标识：`com.yx469h39gt.localchecklist.iphone`
- 最低支持系统：iOS 17.0
- 云端工具：选用 Apple 当前支持的稳定 Xcode 26 或以上版本
- 签名方式：公司账号下的自动签名

云端归档选择 iOS、Release 和 `LocalChecklist-iPhone`。为支持外部测试，Deployment Preparation 选择 **TestFlight and App Store**；这个选项不会自动公开上架 App Store。首次构建手动触发，暂不自动邀请测试者。

详细接入说明见 [Xcode Cloud 配置](Documentation/XCODE_CLOUD.txt)。不需要重建现有功能或升级本地 Mac 才能使用云端构建。

## 测试者如何安装

1. 开发者完成云端构建和上传，并处理必要的测试资料与外部 Beta 审核。
2. 本人先验证主要功能和数据保存，通过后再邀请其他测试者。
3. 测试者在 iPhone 安装苹果官方 TestFlight，打开邀请并安装“本地清单”。
4. 后续可通过 TestFlight 更新；每个测试构建最长有效 90 天，需要维护方持续提供新版本。

TestFlight 是测试分发渠道，不是永久有效的安装包。不要通过卸载 App 来更新；有重要数据时先导出备份，覆盖更新后的数据保留也需要验证。

## 费用与仓库边界

GitHub Free 支持私有仓库。Apple Developer Program 会员包含每月 25 小时 Xcode Cloud 计算额度，由公司团队共享；它统计构建和自动测试等任务的累计耗时，不统计测试者日常使用 App 的时间。未用完的额度不结转。

本项目优先使用会员内含额度，不启用付费构建档位或 GitHub Actions。额度不足时先暂停并确认后续安排，不把免费额度视为无限。

仓库仅保存工程、资源、测试与必要文档，不保存签名私钥、证书导出文件、设备 UDID、登录凭据、安装包或构建缓存。Xcode Cloud 只应获准访问本仓库。

## 验收与历史记录

验收包括：启动、待办与笔记编辑、搜索、纪念日、关闭重开后数据保存、提醒、图片/语音权限、备份及更新保留数据。

[本机验证记录](Documentation/LOCAL_VALIDATION.md)和其他原始交付文档用于查阅历史结果；其中的早期状态不代表本次云端构建或真机验收已经完成。后续以真实构建和验收结果更新本页。
