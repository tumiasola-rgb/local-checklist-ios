# 局域网同步协议与安全边界

本文件描述源码实现与验收要求，不是已完成真机联调的证明。当前环境没有 Swift/Xcode、Apple 签名或 iPhone/Mac 联机测试条件。

## 范围

仅支持一对明确配对的设备；双方在同一 Wi-Fi/以太网局域网，并在前台运行。任一端点击同步，可触发双方交换。没有账号、CloudKit、开发者服务器、HTTP 上传、统计 SDK、多设备 mesh、后台保活或云端兜底。Bonjour 仅公布通用服务名及随机设备标识，没有个人设备名、清单内容或配对密钥。

开关默认关闭。未配对时“开启”只开始局域网发现，不授予内容传输许可。设备名称及发现结果不构成身份认证。小组件只写同机 App Group，不开启局域网会话。

## 认证与加密

`LANNetwork.swift` 使用 Apple Network.framework 的 `NWListener/NWBrowser/NWConnection`。TLS 配置固定为 TLS 1.2 与 `TLS_PSK_WITH_AES_128_GCM_SHA256`；会话 ready 后再次校验实际协商的协议与密码套件，才暴露应用层 channel。没有明文回退、STARTTLS、自动接受证书的 verify 回调或短数字密码。

该 PSK 套件提供认证加密，但不提供前向保密。这里采用它是因为 Apple 的旧 NW API 支持系统 TLS-PSK，且可用于 iOS 17+/Mac Catalyst；不自行实现加密算法或证书签发。升级 TLS 协议/身份方案应单独设计并测试，不能只改一个版本字符串。

首次配对：

1. 用户明确创建临时配对码。`SecRandomCopyBytes` 产生 128 位随机秘密，显示为 32 位十六进制，分成 8 组。这是密钥，不是普通六位验证码
2. 用户只在自己的另一台设备输入该密钥并选择发现的端点；TLS-PSK 握手必须成功
3. 双方在加密通道交换独立设备 UUID、32 字节随机 nonce 和协议模式。按规范化 transcript 计算六位 HMAC 会话核对数字。数字本身不是密钥
4. 两端各自核对并确认；未确认、拒绝、超时或退后台时，不传任何用户内容
5. 双方确认后，用 HKDF-SHA256 从初始密钥及双方 transcript 派生 256 位持久配对密钥。两端先将密钥保存到 Keychain，再互相确认已保存，才建立本机配对许可
6. 临时配对连接关闭；业务同步只能在持久密钥建立的新 TLS 会话中进行

临时码两分钟过期，不落盘。UI 不提供系统分享或通用文本选择；显式复制如启用，仅使用本机剪贴板并短时过期。秘密不写日志、snapshot、备份、Bonjour TXT、错误消息或文档样例。静态测试中的固定数据是清楚标记的公开测试 fixture，生产没有默认密钥。

### Keychain 和安装绑定

配对记录使用 app-private、`kSecAttrSynchronizable=false`、`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 的 Keychain 项；不扩大 access group。ThisDeviceOnly 表示不能迁移到另一设备，不应夸大成对所有系统备份机制的绝对保证。

Keychain 可能跨卸载保留。因此服务必须同时匹配：本地安装 ID、本机持久 peer binding、明确启用状态和配对记录。新装空库不会仅凭残留密钥自动恢复旧许可或接收资料。遗留/部分提交的配对状态会明确报错，需用户忘记旧配对再重新确认。

“忘记配对”先关连接并撤销本机许可，再删除 Keychain 项，保留所有本机用户内容。删除失败不能报告成功；遗留密钥在未匹配本地许可时仍不能传数据。

## 受限传输

- 只从 `local.` Bonjour 发现端点，不接受任意公网主机/IP输入
- 限 Wi-Fi/以太网路径，禁止蜂窝、代理优先路径、peer-to-peer与连接迁移；监听端 `acceptLocalOnly`
- TCP 消息使用四字节网络序长度；长度必须为 1…65,536，先验证再分配
- 每条消息绑定新的会话 UUID、方向内单调 sequence 和明确阶段；错会话、重放、乱序、未知/缺少字段都拒绝
- 整个业务包最大 20 MiB；每个 raw chunk 恰为 `min(32768, remaining)`，最多 640 个 chunk。Base64/JSON 后仍在单帧界内
- begin/end 的 transfer、transaction、长度和 SHA-256 必须一致；整个包收完、hash与所有因果记录验证完才进入仓库
- 逐帧 await `contentProcessed` 提供背压；每次连接/整帧读写有 30 秒绝对期限；一次完整交换最多 180 秒，配对最多 120 秒
- 断线、取消、超时、短读、半帧、超限或 hash 错误都会关闭 channel 并完成等待中的 continuation，不提交半包

传输包只包含稳定项目 ID 和因果版本，包括墓碑；不包含整个本机库替换指令、设置、通知权限、Keychain、配对许可、安装绑定或成功状态。

## 双向提交与确认

一端 A 发起时：

1. A 读取/原子补齐日志并发送请求包 P_A
2. B 完整验证 P_A，先补齐自身可能尚未有日志的 v1 本机内容，然后原子合并全部记录
3. B 发送当前合并后的响应包 P_B，携带对 P_A 摘要的持久化确认。发送响应之前 B 的合并必须已经成功提交
4. A 完整验证并原子合并 P_B，随后发送精确 P_B 摘要的 receipt
5. B 验证 receipt，只确认它实际发送的 head 集合。若网络等待期间有新的本地 head，它仍保持 pending
6. B 持久化确认状态并发送 finished；A 收到匹配 finished 后结束

只在对端确实给出相应持久化确认后计入“对方已确认”。没有任何发送完成/套接字 connected 就等同对端落盘的路径。未得到完整确认时，提示在途数据可能已提交，下次按稳定版本幂等核对。两端内容可能都已落盘，但最后消息丢失使一端仍报告未完成；这是保守且正确的结果。

只有该次完整交换结束、本机无 pending 且无待审冲突才更新上次成功时间。该时间只针对当次版本，不承诺对端此刻没有新编辑。

## 冲突、删除与备份

沿用同一个 `SharedRepository`，内容/outbox/因果状态/ACK在 `flock` + staging + fsync + 原子 rename 下提交。损坏、未知版本或不可读主库拒绝同步，绝不自动重置为空。

向量时钟决定先后，墙钟时间不参与胜负。并发业务修改、完成vs编辑、删除vs编辑均保留可审版本。仅 audit 时间不同且业务字段相同，不制造虚假冲突；完整因果头仍保留。正常删除使用墓碑，不凭缺项或时间垃圾回收推断删除。

已知冲突不能普通编辑绕过；明确解决需精确匹配用户当时审阅的 head ID 集合。编辑器和删除确认另带原内容，防旧草稿覆盖未见的新版本。

v1 存储/备份显式迁移至 v2；v2 缺日志、投影与正文不一致或未知字段会拒绝。导出保留完整用户内容、设置和全部并发 head 的 payload，替换设备/操作/向量身份为新的匿名根，去除配对许可与成功状态，且永不含密钥。导入保留当前本机安装绑定，创建新 epoch/独立因果根并暂停交换；明确恢复时只做 union，备份缺少的对端项目不会作为删除发送。旧在途 ACK 不能修改新 epoch。

当前限制：本机文件/备份约 20 MiB；单项目版本封装 8 MiB；最多 64 个并发头、每头 64 个因果来源、100,000 个日志条目。超过上限明确失败，不截断数据。墓碑不自动回收；极长历史或频繁导入可能达到安全上限。

## 已执行与未执行

已执行 `python3 Scripts/verify_sync_fixtures.py`：33 项独立 Python 因果/协议模型与 Swift 源码契约检查；包含 1,000 组随机因果合并定律测试。这不是 Swift 测试运行。

原生 XCTest 源码覆盖 Shared ledger/migration、Keychain crypto helper、frame/packet、双向内存 channel 和提交/确认故障窗口。当前环境未运行 Swift 编译、XCTest、真实 Keychain/TLS、Bonjour权限或 iPhone ↔ Mac Catalyst。配置与实际签名操作见 `IOS_MAC_LAN_SETUP.md`。

必须在 Apple 设备验收：错误 PSK/identity 拒绝、双方确认门禁、后台/取消/超时、分片短读、20 MiB往返、接收中本机编辑、导入中 ACK、卸载残留 Keychain、忘记配对、同项并发/删除冲突、双端重复完成及下次项唯一性。开发源码检查通过不等于可发布版本。

## Apple 官方依据

- [WWDC19：系统 TLS-PSK 与 NWParameters 示例](https://developer.apple.com/videos/play/wwdc2019/713/)
- [TN3213：TLS-PSK 仅旧 NW API/TLS 1.2 的限制](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)
- [PSK AES-128-GCM SHA-256 cipher](https://developer.apple.com/documentation/security/tls_psk_with_aes_128_gcm_sha256)
- [NWConnection](https://developer.apple.com/documentation/network/nwconnection)
- [Mac Catalyst Keychain](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
- [ThisDeviceOnly Keychain accessibility](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)
- [SecRandomCopyBytes](https://developer.apple.com/documentation/security/secrandomcopybytes(_:_:_:))
- [HKDF](https://developer.apple.com/documentation/cryptokit/hkdf)
