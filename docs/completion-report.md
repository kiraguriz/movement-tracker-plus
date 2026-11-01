# 仓库功能与交付检查 — 2026-11-01

结论：核心功能、数据可靠性和交付工具已补齐；后续按用户授权完成了 Cloudflare 部署、Worker 密钥配置，以及真实 Muse/USDA 连通性和模拟器主要流程验证。真实 iPhone 的签名、安装和启动现已通过，真实计数准确率和 HealthKit 实际写入仍待验收，不能称为“已经完成全部真实环境验收”。后端阶段未启动模拟器，后续 UI debug 已由用户授权并通过 subagent 执行。

范围来自原 Claude 会话“学校项目代码分析与重构”、当前仓库和用户继续完善后端/功能并 commit/push 的授权。后续愿望清单不等于 MVP 缺陷：Watch、云同步、App Attest、3D/SAM、学习型动作识别仍按 `rebuild-brief.md` §12 管理。

## 功能状态

| 模块 | 当前能力 | 验证边界 |
| --- | --- | --- |
| 用户资料与目标 | 引导、资料编辑、体重记录、单位切换、目标与热量/宏量营养规划；活动目标存储 | Domain、仓库测试和 iOS 编译通过；模拟器英/中文引导、单位与隐私流程通过 |
| 动作引擎 | 深蹲、俯卧撑的侧面计数；姿态门控、平滑、分段、部分次数、评分、节奏和速度损失；其余目录动作可手动记录 | 生成数据回归通过；真人准确率、遮挡、光照和相机性能未确认 |
| 训练执行 | 开始/恢复草稿、添加动作、手动/相机记录、编辑/删除组、结束/丢弃训练；计划目标与实际完成量分开 | reducer、SQLite 和功能测试通过；模拟器手动训练及 replay→review→summary→save 流程通过 |
| 中断恢复 | 每个已处理有效次数更新稳定组 ID；结束/重试更新同一行并保留已有 rep ID；无结束时间的组标为中断 | 文件数据库重新打开、重复最终保存测试通过；未提交的最后一个在途写入仍可能被强制终止 |
| 历史与进度 | Today/Train 可进入历史、加载更多、按动作筛选、查看已保存组和次数数据、删除训练；动作进度只使用该动作的组 | 功能测试确认筛选、统计和删除；模拟器历史详情、动作筛选和趋势图已检查；趋势最多读取最近 1,000 组 |
| 休息 | 计划休息秒数参与倒计时；无计划默认 90 秒；使用持久化组结束时间计算绝对截止时间 | 跨时间推进/重建计算测试通过；不依赖后台 timer 持续运行 |
| 录制与评估 | 独立保留 opt-in 骨架 JSONL、零次数录制、Files 导出副本；真实计数由人标注；切换镜头保守标为 unknown/mixed-camera | recorder 和导入测试通过；不能拿 replay/混合镜头/未标注片段冒充真人准确率证据 |
| 饮食 | 手动录入、食物搜索/照片流程、编辑/删除/复用、日汇总；g/ml 持久化；保存修正后的营养基准 | MealDraft、SQLite 及模拟器手动增删改、最近记录复用、液体单位流程通过；真实 Muse 照片→USDA→确认保存通过，图片为生成插画，真实餐食识别质量未验收 |
| Health | 业务写入与同步意图同事务；部分权限按类型写入；版本比较防止旧结果覆盖；失败退避；关闭导出时仍重试删除 | 本地真实仓库 + fake Health writer/service 测试通过；未以真实 Health app 内容作为成功证据 |
| Muse 教练 | 组点评、会话总结、带本地读工具的聊天、确认后写入的计划/饮食/目标提议；结构校验、缓存和离线点评路径 | 协议/流式/工具/重试测试通过；真实普通与流式调用通过，模拟器真实聊天工具、组点评和会话总结通过；输入为合成数据，建议质量仍需持续验收 |
| 代理 | 无运行时第三方依赖的 Worker；安装令牌、模型/输入限制、SSE、USDA 规范化、kill switch；SQLite Durable Object 原子全局与 token 额度 | 146 测试和 dry-run 通过；Cloudflare 已部署并启用，真实 Muse/SSE/USDA 接口通过；见部署记录 |
| 交付 | 原创 1024×1024 无透明通道图标、可重复生成脚本、整仓检查脚本、GitHub Actions、迁移和交接文档 | 图标文件已检查；编译和脚本结果见下方，云端 CI 单独记录 |

## 本轮修复的实质问题

1. 饮食编辑原来没有恢复保存时的营养基准，改数量可能不改营养；液体单位也会丢失。现在保存单位和基准，编辑及最近记录复用都保留用户修正，未知营养仍是未知；数字输入拒绝只识别前缀的字符串。
2. Health 任务原来在业务保存之后靠内存事件入队，存在中断漏同步窗口。现在 SQLite 同时提交业务数据和 outbox，内存事件只负责唤醒；删除意图在关开关后仍可恢复；扫描会轮转，不被大量旧失败记录永久挡住。
3. 实时组原来只在 End set 后保存。现在每个有效次数 checkpoint，同组结束与重试幂等；退出实时页面也保留已开启录制的片段。新组使用上次选择的镜头；混合镜头片段不会伪装成单一镜头。
4. 确认教练计划原来只保留动作名，组数、次数、休息和备注丢失。现在迁移并保存 prescription，训练页显示目标并预填次数；目标不计入已完成训练量。
5. 仓库原来有历史查询却没有对应使用入口。现在可从 Today/Train 查看训练历史、次数明细与动作进度，删除训练也产生可靠的 Health 清理意图。
6. 默认 Release 代理地址原来是代码里的 nil。现在通过公开的 `COACH_PROXY_URL` 构建设置配置，拒绝非 HTTPS、URL 中的凭据和 query token；API key 仍只放 Worker secrets。
7. 原代理 KV 计数跨实例只能尽力而为。现在部署配置强制使用一个 SQLite Durable Object，原子检查 token/feature 与全局额度；退款幂等，退款不返还硬尝试额度，缺少服务绑定时先拒绝再调用上游。请求数量限制不等于精确美元账单上限。
8. Debug 曾允许 schema 变动后自动清库。现在 Debug/Release 都保留数据，按追加迁移升级。Wrangler 更新到已批准工具的兼容 4.x 版本，当前 npm audit 无已知问题。
9. 云端无 Vision compute device 的实际错误暴露了评估工具的数据质量问题：视频里所有 Vision 调用失败也可能形成 0 次的“正确 idle”。现在空 fixture、无测量视频、任何带 Vision 错误的视频都明确失败，不进入次数准确率或延迟统计；新增 4 项确定性回归测试，用可注入估计器区分有效的无人帧和测量失败。
10. UI debug 复现了空白动作被计入已完成训练的问题。现在总结、教练输入、已完成历史数量及动作筛选只包含有记录组的动作；空白草稿/计划条目仍保存供编辑，历史详情不再显示空段。
11. 修正英文离线总结和历史中的单复数。模拟器用“空 Bench + 一组 Squat”验证总结为 `1 exercise, 1 set, 10 reps`；本地回归覆盖计数、筛选、保留原数据和教练输入。
12. 部署后普通 UI 测试也可能意外使用真实服务。共享测试启动器现默认使用进程内 stub，显式代理 URL 和无教练模式保留；手动饮食测试适配了有代理时的 Add 菜单，避免网络消耗与界面假设影响回归。
13. 全量 UI 回归暴露了自动化输入问题：自动聚焦后的光标可能位于旧值开头，原 helper 输入 `81` 实测变为 `8180`，App 正确禁用了 Save；XCTest 的键盘范围还不包含预测词栏，导致点击候选区而非饮食字段。测试 helper 改为全选替换、验证实际值，并在预测词栏上方的表单可见区滚动。没有放宽 App 的体重或饮食验证。
14. 完整顺序回归确认了一个产品导航问题：从 Body 返回 About you 后，残留键盘覆盖 Continue，普通表单拖动未能解除。现在由 Onboarding 父视图持有 SwiftUI 焦点，在导航路径变化时统一清除；避免子视图移除后才清焦点。原顺序复现 2/2、受影响资料/引导/体重回归 13/13 通过，三种 App 编译通过。

## 数据与架构

- 仍是 clean-room 原生实现；本轮未读取旧项目 `.env`，未向 app/仓库写入真实服务密钥。
- `Domain` 与 `MotionCore` 保持只 import Foundation、彼此不依赖；app 负责运动数据映射。
- 新增内部 `AppLogic` 模块，承载 app 实际使用的饮食编辑、数字解析、计划应用、休息和历史逻辑。没有新增第三方 app 依赖。
- 数据库依次应用 `v1`、`v2-nutrition-quantity`、`v3-workout-prescriptions`。不修改旧 v1 SQL，不靠清库升级。
- 老版本没有保存液体单位的行仍按旧 grams 语义迁移；缺失的历史单位无法可靠推断，不能声称已经恢复。
- 对相机引擎的恢复是保存已提交次数，再开始新一组时重新校准，不是从崩溃处恢复相机帧处理。

## 验证证据

后续部署与 UI 验证见 [cloudflare-deployment.md](cloudflare-deployment.md) 和 [ui-debug-report.md](ui-debug-report.md)。
线上代理已启用。后续代码 `569bb57` 的 `tools/check.sh` 已完整通过：**1,184 项 Swift**（7 个模块，本机实际 Vision 项全部启用）、146 项代理、8 项导入工具测试、代理 dry-run，以及 Debug/Release Simulator SDK 与未签名 Release iPhone SDK 三种编译。部署配置在 `dea0d6c`，两项代码提交均已推送到 `origin/main`。

后续 [GitHub Validate 41338272179](https://github.com/kiraguriz/movement-tracker-plus/actions/runs/41338272179) 在 `569bb57` **成功**：native/proxy 两个 job 完成。直接核对 native job 原始日志，7 个模块共声明 1,184 项测试，8 项明确因 VM 缺少 Vision compute device 跳过，三种编译通过；本机同一完整检查启用了这 8 项。当前设备清单只有两台启动中的模拟器连接，没有可用的已连接实体设备；项目尚未选择签名团队。

后续 [GitHub Validate 41342464322](https://github.com/kiraguriz/movement-tracker-plus/actions/runs/41342464322) 在 `23395a2` 也已成功。最终 [GitHub Validate 41347266853](https://github.com/kiraguriz/movement-tracker-plus/actions/runs/41347266853) 在 Onboarding 修复 `ae9d29d` **成功**，native/proxy 两个 job 完成；直接核对最终原始日志，7 模块/1,184 声明测试、8 个明确硬件 skip、三种编译均与上面的边界一致。UI 运行结果是独立证据，未冒称为云端 UI 测试。

UI 截图测试已单独实际执行 **25/25**：浅色/大字体/横屏 19 项、深色 6 项，共生成 124 张截图并抽查关键页面。整套 UI 基线的 25 个截图 skip 因缺少目录配置，已由上述专门批次补足；功能用例的原始失败与后续修复/复测另在 UI 报告逐项保留。真实 Muse 组点评和照片饮食的合成数据截图已保存在 `docs/ui-evidence/`，不依赖临时截图路径。

完整功能批次在 `23395a2` 为 **56/57**，唯一失败促成了 `ae9d29d` 的 Onboarding 产品修复。修复后原顺序 2/2、受影响全组 13/13 通过；这些用例已重新验证，其余未受影响的通过证据保留复用。没有宣称重新整套跑出 57/57。结合 25 项截图，最终通过记录覆盖原矩阵的 **82 个不同用例**，[逐项结果](ui-evidence/results.json) 保留原始失败及后续复测。该修复另重新通过 Debug/Release Simulator SDK 和未签名 iPhone SDK 三种编译，核心包和代理代码未变，复用既有通过证据。

回归曾发现一个旧引用测试不再适用于过滤空动作后的输入；已改为验证“引用被省略的空动作必须拒绝并 corrective retry”，4 项引用测试通过。另一次并发运行中，实际 Vision `noPersonGivesNil` 报 `failed to processImage`；本地检查脚本与 CI 对齐使用 `--no-parallel` 后，完整 187 项 PoseCapture 测试及整套检查通过，没有把该错误改成跳过。下面保留前一轮 1,181 项基线及其独立 CI 记录。

前一轮后端基线的 `MOVEMENT_DERIVED_DATA=/tmp/mt-recording-build tools/check.sh` 已整套通过，包含评估质量修复：1,181 项 Swift 测试、8 项导入工具测试、146 项代理测试、代理 dry-run bundle，以及 Debug/Release Simulator SDK 和 Release iPhone 设备 SDK 三次编译。当时的能力探测调整另通过本机 187 项 PoseCapture 测试和完整云端复核。该阶段未运行 Simulator，编译结果与真实设备验收分开记录。

已独立完成的检查：

- `swift test --package-path Packages/MovementKit`：1,181 项通过，7 个测试模块，本机没有跳过 Vision 集成项。
- `python3 -m unittest discover -s tools/tests -v`：8 项通过。
- `npm test --prefix proxy`：146 项通过。
- `tsc -p proxy/tsconfig.json`：通过（本机已有 TypeScript 5.9.2）。
- `npm audit --prefix proxy --audit-level=moderate`：0 vulnerabilities。
- `npm run build --prefix proxy`：Wrangler 4.156.0 dry-run 成功，不代表已发布。
- 本地真实 `wrangler dev --local`：health 200；同网络 12 个并发安装请求恰好 5 个 201、7 个 429；测试服务随后停止。
- Debug/Release 通用 Simulator SDK 编译和 Release 通用 iOS 设备 SDK 未签名编译：通过。该后端基线阶段未启动模拟器或安装到手机；后续模拟器运行见上方 UI 证据。
- `tools/accuracy.sh`：生成回归 17/17 精确，打包 replay 2/2 精确；真人片段仍为 0。
- 原生与代理 GitHub Actions 的结果在 `completion-status.md` 记录，不能用本地通过替代云端运行结果。首次并行原生运行卡在 framework 测试，停止后改串行获得了明确错误：GitHub VM 无 `VNComputeStageMain` 设备。8 个需要真实 body-pose compute device 的集成测试以一次实际 revision-2 请求做条件探测：仅该明确的无设备错误才跳过，其他错误仍失败；其余测试、fake estimator 的失败处理和三种编译必须通过。本机有硬件时全部启用，没有把 app 的 Vision 模型换成其他 revision。Metal 设备存在本身不足以证明 Vision 可运行。
- 最终 [GitHub Validate 41300391099](https://github.com/kiraguriz/movement-tracker-plus/actions/runs/41300391099) **成功**：native/proxy 两个 job 均完成；七个测试模块的 1,181 项中，8 项硬件集成项明确跳过，其余启用项通过；代理、导入测试和三种 app 构建通过。使用 job 原始日志核对了全部七个模块，不能只根据被截断的聚合日志推断覆盖。

## 线上与设备验收

| 项目 | 当前证据与边界 | 接续步骤 |
| --- | --- | --- |
| 在线 Muse/USDA | 已完成 Cloudflare 登录、KV/DO 部署及两把 Worker secret 配置；真实普通/流式 Muse、USDA 和一轮真实 Coach UI 调用通过 | 后续密钥轮换与运行步骤见 `docs/cloudflare-deployment.md`；不再是当前阻塞项 |
| 签名安装和 HealthKit | iPhone 17 Pro Max（iOS 27.2）的签名、安装和启动通过；签名和 profile 均含 HealthKit entitlement；真实 Health 授权和写入待验收 | 见 [实机证据](physical-device-acceptance.md)；继续验收部分授权、编辑、删除及重启补偿 |
| 真人计数和性能 | 没有真人标注片段或真实相机延迟数据。生成数据成绩不能说明真人精度 | 录制不同人员、环境、前后镜头和 idle/partial；人工标注后导入，重新生成 accuracy；测真实设备帧延迟和温度/耗电 |
| UI/交互验收 | 模拟器验证覆盖 82 个不同用例的通过记录；修复空动作统计、英文单复数、Onboarding 残留键盘，以及测试输入/预期问题，完整运行与复测分开记录 | 仍需真实设备布局、完整 VoiceOver/Dynamic Type、真实照片/相机权限及用户环境错误变体验收；范围见 UI 报告 |
| 对外提交 | 本轮没有录制真人演示，也没有代用户提交参赛材料或发布应用 | 用已有 demo/checklist 完成真实演示后由用户决定提交 |

语音笔记、教练生成动作 spec 等在原 brief 中是 stretch，现有 transport 不是已交付 app 功能；Watch、iCloud 和后续机器学习也没有冒称完成。它们与上表的 MVP 外部验收分开管理。

## 提交记录

- `1635d0e`：录制独立保存、导出和导入验证。
- `93d979e`：Health 部分权限及初始队列处理。
- `2482144`：饮食单位、营养基准与可测试编辑逻辑。
- `3aa42d3`：同事务 Health outbox、并发版本校验和恢复服务。
- `164db88`：训练 checkpoint、prescription、历史与进度、公开代理配置。
- `4b1a0d2`：Durable Object 用量控制、交付脚本、图标与 CI。
- `4df9c0c`：客户端全局限额处理。
- `e580503`：拆分云端编译/测试、串行执行与超时诊断。
- `940e69e`：评估失败片段不计入准确率；Vision 硬件集成条件与确定性错误回归。
- `65f24d2`：以实际 Vision 请求探测运行条件，不依赖虚拟机的 Metal 设备声明。
- `dea0d6c`：配置已部署的 Cloudflare KV 与公开 App 代理 URL，记录真实接口联调。
- `569bb57`：完成训练只统计已记录动作、修正文案单复数、UI 测试默认 stub，以及串行本地框架检查。
- `5761da3`：修正大字体 Form 懒加载及照片质量/体积不可直接换算的 UI 测试预期；targeted retest 通过，云端 native/proxy CI 成功。
- `23395a2`：测试输入改为全选替换并验证实际值；避让键盘预测词栏，保留安全的焦点失败诊断；原机 5 项输入回归通过。
- `ae9d29d`：修复 Onboarding 换步骤后的残留键盘；原顺序与受影响回归通过，三种 App 编译通过。

代码提交已按批次推送到 `origin/main`；报告和生成记录另作文档提交。完整历史见 `docs/build-log.md`。
