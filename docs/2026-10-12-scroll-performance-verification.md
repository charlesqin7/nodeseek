# 首次滚动性能修复与验证

基线：`cd7c12e0346de70bfa90003ccc0435c0a691aa14`。
用户环境：iPhone 18 Pro、iOS 27.0.1、TestFlight；首次滑动卡顿，加载后反复滑动正常。
TestFlight 构建号及对应源码提交尚未核对。

## 实现

- 富文本视图复用相同内容、宽度的测量结果；内容、主题、宽度和附件布局变化时失效。Texture 节点仍使用自身布局缓存，普通文字不再额外执行 boundingRect 兜底测量。
- 两处富文本诊断改为延迟求值；关闭时不拼接附件诊断字符串。
- 附件更新按正文/评论 ID 合并，只使相关行布局失效，复用节点和图片。行刷新提交时重新解析 ID，拒绝旧渲染代次的回调。
- 回复下一页先准备富文本再插入。准备期间禁止再次触发批量加载；刷新取消旧任务，字号、签名或宽度变化重新准备。
- Kingfisher 保留位图处理及磁盘/内存缓存。新增数据 provider 合并头像下载和 SVG 准备；SVG 仍在主线程安全渲染，但拖动、减速时不启动，停止后优先处理可见头像并逐个让出主线程。缓存键包含 URL、尺寸、倍率。
- 头像退出显示范围取消未完成订阅，最后一个订阅取消后取消网络/排队渲染；已成功显示的头像返回时直接保留。HTML challenge 仍同步 Cookie 后重试一次。
- 单元格在后台构造时使用屏幕主题快照，加载 view 时仅在实际主题不匹配时重新配置。

## 本机验证的边界

Windows 环境无 Xcode、iOS SDK、模拟器或连接的 iPhone，因此没有执行 iOS 编译、XCTest/Swift Testing 或 Instruments。
Swift 语法解析与 Git 补丁检查不能验证类型、第三方库链接、Actor 隔离或运行时行为。
不能据此宣称已消除真机掉帧；需完成以下验证后再发布 TestFlight。

## Mac 编译与回归

先用 `xcodebuild -showdestinations -project nodeseek.xcodeproj -scheme nodeseek` 找到本机有效模拟器。
项目 Makefile 默认的 iPhone 16 / iOS 18.0 若不存在，传入 `SIMULATOR_ID`。

```sh
make xcode-build-tests
make xcode-test-class TEST=ScrollRenderingPerformanceTests SIMULATOR_ID=<本机模拟器ID>
make xcode-test-class TEST=AvatarDataPipelineTests SIMULATOR_ID=<本机模拟器ID>
make xcode-test-class TEST=PostDetailViewControllerTests SIMULATOR_ID=<本机模拟器ID>
make xcode-test-class TEST=PostTextureListViewTests SIMULATOR_ID=<本机模拟器ID>
make xcode-test-class TEST=PostSummaryCellNodeTests SIMULATOR_ID=<本机模拟器ID>
make xcode-test-class TEST=AppTextSizeRenderingTests SIMULATOR_ID=<本机模拟器ID>
make xcode-test-class TEST=SVGKitPerformanceTests SIMULATOR_ID=<本机模拟器ID>
```

新增测试覆盖重复测量、宽度/内容/主题失效，SVG 滚动延迟/可见优先/取消，下载合并/处理缓存、Cookie 重试、已显示头像复用，稳定评论 ID 定位及过期分页丢弃。已有分页测试已改为等待异步插入完成。

## 真机对照

1. 核对 TestFlight 构建与基线源码，使用相同 Release/Profile 配置、账号、字号、签名设置、网络及电源状态；记录低电量模式和设备温度。
2. 基线和修改版各跑三轮：清图片缓存后的列表连续滑动；缓存加载后的反复滑动；长回复/图片/动图帖子；连续加载三页回复。每轮使用相同内容及滑动路线。
3. Instruments 同时记录 Animation Hitches、Time Profiler 与 Points of Interest。标记为 `AvatarSVGRasterize`、`RichTextViewLayout`、`RichTextNodeMeasure`、`AttachmentRowsLayout`、`DetailRowsReload`、`CommentPagePrepare`。
4. 比较每轮 hitch time ratio、最慢主线程片段、首屏时间和内存峰值。目标是冷加载卡顿明显减少，热缓存不退化；不以模拟器 FPS 代替真机数据。
5. 拖动和惯性减速期间不应开始新的 `AvatarSVGRasterize`；停止后可见头像应补齐。检查快速返回、连续切页、离线、图片失败及 Cookie challenge。
6. 检查主题切换、最大字号、旋转、长引用、固定引用图、动图、长图、链接、点赞、回复与从非首页进入后分页。图片补齐及变矮时应无裁切、重叠或明显位置跳动。

| 场景 | 基线三轮 | 修改版三轮 | 结论 |
| --- | --- | --- | --- |
| 冷缓存帖子列表 | 待测 | 待测 | 待测 |
| 热缓存反复滚动 | 待测 | 待测 | 待测 |
| 富文本/图片回复 | 待测 | 待测 | 待测 |
| 回复分页追加 | 待测 | 待测 | 待测 |

## 发布与回退

通过上述编译、回归和真机对照后再发布测试版本。观察复杂 SVG 停止滚动后的补齐延迟、图片高度变化、连续分页与内存峰值。此修改无数据迁移；需要回退时整体撤销本次补丁，旧头像缓存仍保留但不会命中新缓存键。
