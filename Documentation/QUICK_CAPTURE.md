# 离线快速新建模块

## 范围与数据流

`App/QuickCapture.swift` 包含纯 Foundation 规则解析器、Vision OCR、严格本机 Speech 转写，以及 SwiftUI 输入/逐条预览页。目标 iOS 17+。没有云模型、账户、网络请求、分析 SDK、照片上传、录音文件、日历写入或通知创建。图片/语音里的任何语句仅作为待保存文本。

流程：用户选择一张图片或主动开始录音 → 设备端识别 → 完整文字可编辑 → 按换行生成候选 → 每条可选择待办/备忘、改标题/正文、设日期和时间 → 用户点击保存 → 父应用落地本地存储。

- OCR：PhotosPicker 单项或文件选择器单项，不申请全相册权限。以 Data 读取 JPEG/PNG/HEIC 等 ImageIO 支持的格式，EXIF 方向在缩略处理时应用。输入大于 30 MB 明确拒绝；图片最长边缩至 4096 像素，文案提示细小文字可能识别不准。识别文字不截断。
- Vision：`.accurate`，查询 `supportedRecognitionLanguages()` 后选择 `zh-Hans`、`zh-Hant`、`en-US`，中文不启用语言纠错。
- Speech：普通话 `zh-CN` 或美式英语 `en-US`。校验返回的 locale、`supportsOnDeviceRecognition` 与 `isAvailable`，每个 request 固定 `requiresOnDeviceRecognition = true`。不支持就退回手动输入，绝不切到服务端。
- 录音最长 55 秒，停止时立即释放麦克风，最多等待 3 秒完成尾部转写。来电/输入路由断开/媒体服务重置/进入后台时停止，不自动恢复。取消录音会撤销该次新增转写；取消整个表单不会创建记录。
- 只保存文字，原图和原始音频不保留。所有识别结果必须先预览，不会从异步识别回调直接创建记录。
- 系统照片或文件选择器可能取回仅在 iCloud/云文件提供商的原文件；离线应选已下载到手机的文件。应用没有上传输入或云端识别流程。不能声称任何系统选择器在任何情况下都不联网。

## 父应用接口

`QuickCaptureView(onConfirm: ([QuickCaptureDraft]) -> Bool)` 回传选中的草稿，不自行关闭 sheet。父应用负责原子保存、错误显示和成功关闭；成功返回 true，模块保持保存按钮锁定直到关闭；失败返回 false，保留草稿供修正重试。父应用应使用 draft.id 做幂等创建以双重防止重复提交。

草稿字段：

- `id`：这次候选的 UUID
- `kind`：`.task` / `.note`
- `title`、`body`：用户可改，初始标题至多 64 字，正文完整
- `originalText`：该候选未编辑的输入行
- `sourceText`：该次图片/语音/输入的完整原文，用于保留和核对；若编辑过输入，再预览时仍保存原始识别全文
- `dueDate: Date?`、`hasTime: Bool`：具体日期以及是否包含用户需要的时间
- `dateNeedsReview`、`dateReviewNote`：有歧义时必须确认日期，或确认不设置日期，才能保存
- `isSelected`：默认选中，可逐条排除

任务模型按用户当前时区从 `dueDate` 提取 `DayStamp`。只有 `hasTime == true` 才提取 `hour * 60 + minute`；纯日期不应默认为某个提醒时刻。若备忘模型无日期字段，应将用户确认的日期/时间写入备忘正文。保留 `originalText/sourceText`，或明确标注附在正文中，避免编辑后丢失原始识别证据。

`QuickCapture.swift` 必须只加入主 App target，不加入 Widget extension；`Tests/QuickCaptureParserTests.swift` 加入 `LocalChecklistTests`。

## 权限及隐私配置

主 App Info.plist 必须含：

- `NSMicrophoneUsageDescription`：用于你主动开始的离线语音输入；识别后只保留文字，不保存录音
- `NSSpeechRecognitionUsageDescription`：用于在支持的设备上离线将语音转成文字；不支持时使用手动输入

这两个权限仅由“开始离线录音”按钮流程请求。拒绝或受系统限制时显示说明，不强制跳设置、不崩溃、不继续录音。不要添加 `NSPhotoLibraryUsageDescription` 或全库申请来替代单项照片选择。不要开启后台音频模式。

Apple 的系统语音权限文案可能描述其一般服务能力；应用实际请求仍须严格设为 requiresOnDeviceRecognition，并先守卫支持能力。

## 规则范围与保守处理

支持今天/明天/后天、有效的完整数值年月日、24 小时时间、中文上午/下午/中午/晚上等时段及常见中文数字、半/一刻/三刻。跨月跨年按本地 Gregorian 日历计算。

以下情况标为待确认：没有年份的月日、只说几点未区分上午下午、只有时段、星期/下周/重复安排、多个候选日期/时间、过去的时间、非法年月日/时分、只说时间没说日期、未支持的中英文相对日期、夏令时重复/不存在的时刻。规则并非语义大模型；中文正文中提到日期可能被建议为待办，用户可改回备忘。语音识别支持英文不代表规则解析器支持所有英文日程语法。

无关键词/日期线索的段落保留为备忘。多行按非空行切分，并不猜测“然后”等语音语义边界；用户可在预览前添加换行。正文、候选原文和完整来源不静默截断。标题缩短仅为显示，完整内容仍在正文与原文。

## 生命周期与并发

界面状态在 MainActor。Speech 的回调先复制 String/Bool 等 Sendable 值，再通过 Task 返回 MainActor。音频回调只持有一个锁保护的 `AudioRequestBridge`，串行化 append/endAudio；`@unchecked Sendable` 限于这个封装并有同步保护，未全局忽略并发检查。Vision 对象只在一个 detached task 内创建和使用，跨任务只传 Data/String。

权限回调、识别回调和导入各有会话 token；关闭、取消或进入后台会使旧 token 失效。退出不会因迟到的权限响应重新开始录音。取消 OCR 会撤销 UI 结果并发送 Task cancellation；正在同步执行的一次 Vision 调用可能短暂继续计算，但其结果会丢弃，不会保存。被文件提供商阻塞的读取也不能保证瞬时终止，返回后按 token 丢弃。

## 验证情况

当前构建环境没有 Swift/Xcode/iOS SDK。因此：只做静态检查与 XCTest 用例编写，未编译、未执行 XCTest、未在模拟器或真机验证，不能称为可运行验收通过。

`QuickCaptureParserTests.swift` 覆盖：中文相对日+时刻、完整数字年月日/24h、日期无时刻、上午下午歧义、只有时间、缺年份、星期与重复日期、非法值、多日期/多时刻、大致时段、过去日期、换行与原文、长文本不丢失、图片指令为普通文本、全角数字、年末跨年、DST 重复时段和空文本。

拿到 Mac 后先运行项目 XCTest 与 Debug/Release build，再做以下真机验收：

1. 已下载本地简中/繁中/中英混排图片，在飞行模式成功 OCR；旋转 EXIF 图片、HEIC、空白图、损坏文件、超大文件、仅云端图片有明确结果或失败说明
2. 普通话/英语离线支持设备与不支持设备；没有服务端 fallback。抓包/隐私报告检查无应用网络上传
3. 首次麦克风/语音权限分别允许、拒绝、限制；等待权限时取消关闭，迟到的同意不开始录音
4. 连点开始/停止/取消；停止后麦克风指示消失，最终文字尾部可编辑；达到55秒自动停止有说明
5. 来电、耳机断开、媒体服务重置、锁屏或切后台；录音立即停止且不自动恢复，已识别文字保留
6. 图片加载/OCR中取消、关闭后重新打开、选择相同照片，旧回调不覆盖新内容，不创建条目
7. 预览编辑标题/正文/类型/日期，选中部分候选；任何歧义未核对时不能保存，取消不创建；确认只创建所选条目且没有日期/时间丢失
8. 本地保存失败仍可恢复草稿与重试；快速连续点击保存不能重复创建
9. 重启 App 后完整原文可追溯，原始图片/音频没有落入应用文件、日志或备份

## Apple 官方依据

- [Vision 文本识别](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
- [VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)
- [PhotosPicker 与 iCloud 资源边界](https://developer.apple.com/documentation/photosui/photospicker)
- [Speech 本机支持检查](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)
- [强制不发送音频到网络](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)
- [麦克风权限](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:))
- [结束识别任务](https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/finish())
- [取消识别及释放输入资源](https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/cancel())
- [音频中断](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
