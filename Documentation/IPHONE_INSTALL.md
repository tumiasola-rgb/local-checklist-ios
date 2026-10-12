# iPhone 自用版安装

本次目标是安装到自己的 iPhone 并验证主 App。小组件、Mac 和双机同步不作为安装验收条件。原有功能源码保留。

## 开发与交付顺序

先完成本地构建、测试和界面验证，再确定接收人、签名账号及安装方式。给老板发送文件、上传 TestFlight 或在其手机安装，均在交付内容明确后由用户确认；当前未执行这些操作。

手机设备编号（UDID）不是 App 的产品需求，也不决定功能。当前工程没有指定真机 UDID 或固定签名描述文件，开发者 Team 尚未配置。`com.example.LocalChecklist.iphone` 是待替换的 App 标识；`LocalChecklist iPhone` 是本机模拟器名称，两者都不是老板手机的编号。

| 安装方式 | 是否需要目标手机编号 | 前提与限制 |
| --- | --- | --- |
| Xcode 连接手机安装 | Xcode 在配对和签名时识别设备 | Apple 账号、实际手机连接和开发者模式；免费 Personal Team 通常每 7 天需重新签名 |
| Ad Hoc 安装包 | 需要，且设备须包含在签名描述文件中 | 付费开发者会员及设备注册；不是任意 iPhone 通用安装包 |
| TestFlight | 不需要手工收集 UDID | 付费开发者会员、上传和 Apple 测试分发流程；外部测试可能需要审核，每个构建有测试期限 |
| App Store | 不需要 | 付费开发者会员、商店资料和审核，属于后续正式发布工作 |

当前建议先完成本地验证，再用本人手机试装；若最终希望老板远程方便安装，另行确认 TestFlight 路径。没有付费会员时，不能承诺发送一个 IPA 就能让任意 iPhone 直接安装。具体账号能力和期限以 Apple 实际结果为准。

## 选择工程入口

打开 `LocalChecklist.xcodeproj`，选择 **LocalChecklist-iPhone** scheme。

- 最低 iOS 17，支持 iPhone/iPad；实际手机系统与 Xcode 的兼容性仍需核实。
- 这个入口只构建一个 App，不嵌入桌面小组件，不要求 App Groups 权限。
- 应用标识为 `$(BASE_BUNDLE_IDENTIFIER).iphone`，与原完整版区分。
- 数据明确保存在应用沙盒的 `Library/Application Support/LocalChecklist`，不是共享容器失败后的静默替代。
- 原 `LocalChecklist` / `LocalChecklist-Mac` scheme 的目标、共享容器和组件依赖保持原样。
- 两种产品的数据目录不同，切换需要先导出备份、再在另一产品内明确导入；不能指望自动看见同一份数据。

## 本地验证

如果终端只选中了 Command Line Tools，可为当前命令设置 `DEVELOPER_DIR`，无需修改系统默认设置。脚本也会在此情况下查找 Applications 中的 Xcode。

```sh
python3 Scripts/verify_static.py
python3 Scripts/verify_sync_fixtures.py
bash Scripts/verify_iphone.sh simulator
bash Scripts/verify_iphone.sh test SIMULATOR_ID
bash Scripts/verify_iphone.sh device
```

测试参数应使用本机已有模拟器的 ID。没有模拟器运行时时，先在 Xcode → Settings → Components 安装匹配的 iOS 组件。即使真机无签名构建，资产目录编译也可能要求该运行时。

`device` 只验证 Release 构建，关闭代码签名。它的产物不能直接安装，不能当作已签名 IPA 交付。

## 安装到自己的 iPhone

1. 在 Xcode → Settings → Accounts 登录自己的 Apple 账号。密码只在 Apple 登录界面输入。
2. 用数据线连接 iPhone，解锁并信任电脑；按系统提示开启开发者模式。
3. 在 **LocalChecklist-iPhone** target 的 Signing & Capabilities 中选择自己的 Team，保持自动签名。
4. 在 `Config/Signing.xcconfig` 将 `BASE_BUNDLE_IDENTIFIER` 改为自己的唯一标识。首次安装后，尽量保持账号和标识一致，避免变成另一款 App。
5. 选择实际连接的 iPhone，执行 Run。免费 Personal Team 的签名有效期有限，通常需要每 7 天重新签名；以 Xcode 和 Apple 账号实际结果为准。
6. 首次启动后用可丢弃数据完成下面的验收，再录入重要资料。

没有账号签名和设备配对，源码、无签名 `.app` 或压缩后的 IPA 都不能替代这一步。不需要先上架 App Store。

## 真机验收

- 首次打开能进入主页，没有存储错误；五个栏目能切换。
- 新增、编辑、完成和删除待办；关闭 App 再打开，数据保持一致。
- 新建和编辑笔记、搜索、纪念日、日期与重复设置。
- 实际通知授权与送达；拒绝权限时显示明确状态。
- 图片识字、语音权限及离线能力、系统分享。
- 导出备份后确认文件存在；用测试数据验证导入和恢复。
- 覆盖安装更新后已有数据保留。卸载前必须将备份存到 App 目录之外。

签名安装、真实通知、照片/麦克风权限和双机同步不能用类型检查或桌面逻辑测试替代。实际通过项另见本次验证记录。
