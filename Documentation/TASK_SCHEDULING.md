# 日期、提醒与重复

## 实现范围

- 日期 / 时间段切换，独立开始和结束选择器，全天开关，开始和结束时刻分别保存
- 两层值草稿：退出或取消不写任务；“清除”只清当前草稿，右上角确认后才交回任务编辑器，任务编辑器的“保存”才落盘
- 提醒锚点为开始日期时间；全天默认当天 09:00，可自行修改；可选开始时、提前 5/10/15/30 分钟、1 小时、1/2/7 天
- 每天、每周、每月、每年，每 1–99 个周期，可设最后一次开始日期（含当天）
- 每周可选星期，按周一划分周期；周一至周五只是星期选择，不识别法定节假日或调休
- 完成后才生成下一次，不预先堆积未完成项。计划日期为递推基准；完成很晚时，下一项仍可能已过期，不会自动跳过漏做的次数
- 每月 31 日跳过没有 31 日的月份；每年 2 月 29 日跳到下一有效闰年。按所选间隔依次检查候选周期，不改成月末
- 跨日任务保持原来的民用日期跨度；开始和结束分钟保留。截止日限制下一次的开始日，结束日可晚于截止日
- 撤销完成不会删除已经生成的下一次；删除已生成的下一次后，再次完成前一项不会自动复活它
- 这是一套明确限定的常用规则，不声称覆盖其他清单产品的全部重复/农历/节假日规则

## 时间与隐私

TaskScheduleOptions 保存时区 ID，任务在手机和 Mac 上遵循同一个已保存时区。日期用 DayStamp，全天按民用日期计算。全天开关不丢弃隐藏的开始/结束分钟；显示组件必须依据 scheduleIsAllDay 判断是否显示时刻。

夏令时缺失时刻取当天接下来的可表示时间（例如 02:30 缺失时取 03:00），重复时刻取第一次；整天不存在的时区日期不排期。提醒的整天提前量用 Calendar.day，而非 86,400 秒，因此跨 23/25 小时日仍尽量保留钟面时间。

只有用户显式设置并保存有效提醒时主 App 才请求通知权限。普通启动、同步、导入、小组件完成和自动重建不弹权限。拒绝不丢规则，UI明确说明本机不会通知。系统授权是每台设备的状态，不写入备份或同步数据。

通知标题和正文是固定概述；userInfo 只有 taskID，不包含用户的标题、正文、标签或私密全文。点击通知后由主 App 用 ID 查本地任务。

## 本地通知容量与生命周期

使用 UNUserNotificationCenter，按提醒时间排序，只安排最近 60 个未来当前实例，不限制任意 30 天期限。其他功能已占的 pending 请求会从这个保守预算中扣除。超出部分会在后续打开/刷新 App 时补排；不会无限展开重复项。只有这个功能的 local-checklist.reminder.v1. 前缀可被取消，不调用 removeAllPendingNotificationRequests。

Apple 的已弃用 UILocalNotification 文档明确提到系统保留最近 64 条；当前 UNUserNotificationCenter 文档没有承诺一个适用于所有平台版本的固定容量。本实现采用 60 的保守产品预算，留出余量，并读取实际 pending ID 验证接受情况；这不是系统保证送达 60 条的承诺。

App 前台恢复、编辑、完成、删除、导入、收到同步变化后重建。Widget completion 使用同一个 Shared completion 事务，持久化后在已有授权下重建，不请求权限。旧提醒替换失败时取消该 ID 的旧 trigger，避免旧时间误响。已完成/删除/清除提醒的任务会撤销 pending 与相应 delivered。

同进程仅一个异步重建 worker，合并到最新快照；传入 readLatestTasks 后，每个异步阶段之后重新检查权威存储，以修复 App/Widget 的大多数交错。系统通知中心没有跨进程排期事务：进程恰在 add 后被系统杀死、或远端修改尚未同步到本机，仍可能短时残留旧提醒，下一次前台/成功同步会修复。系统未给后台执行及时性保证，不声称云端变更能立即修改关着的另一台设备通知。

手机和 Mac 独立授权、独立排期，可能各自提醒；不承诺跨设备只响一次。专注模式、通知摘要、静音、系统限制与设备离线/关机等可影响展示时刻，成功加入 pending 不等于已送达。

## 确定性重复与同步

nextOccurrence(after:) 的身份仅由固定命名空间与当前实例 ID 以 SHA-256 派生，使用自定义 UUIDv8 位；它不是 UUIDv5 的实现。日期/频率/墙钟时间不参与 ID，因此同一实例被两个设备离线完成、甚至并发改了计划，也只能指向同一个后继身份。内容相同的后继完全一致（新项未完成，createdAt/updatedAt 用 parent.createdAt）；内容不同由同步层按同 ID 保留冲突，供用户选择。

SharedRepository 的完成事务必须同时完成父项并插入后继，而且必须检查当前任务集合与同步日志/墓碑，避免重放造成重复或复活。本界面不直接写重复实例。

## 验证范围

Tests/TaskScheduleTests.swift 提供 XCTest 源码，覆盖两层值草稿/清除、全天保留时刻、倒序区间、DST、整天跳过、短月/闰年、指定星期/间隔/截止、范围继承、稳定后继 ID、Codable 往返、容量/去重、拒绝权限、同 ID 重排、完成/删除清除、挂起 add 期间新状态胜出、存储读取失败、替换失败不留旧提醒。

当前编写环境是 Linux，无 Swift/Xcode。测试尚未编译执行，SwiftUI 布局/系统权限/通知送达/Mac Catalyst/App 与 Widget 跨进程竞争必须在 Xcode 和真机验证。Python 结构检查不是 Swift 编译或 UI 验证。

## Apple 官方资料（2026-10-06 核实）

- https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications
- https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app
- https://developer.apple.com/documentation/usernotifications/unnotificationrequest/identifier
- https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/getnotificationsettings(completionhandler:)
- https://developer.apple.com/documentation/uikit/uilocalnotification
- https://developer.apple.com/documentation/foundation/calendar/nextdate(after:matching:matchingpolicy:repeatedtimepolicy:direction:)
