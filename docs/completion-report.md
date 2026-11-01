# 仓库功能与交付检查 — 2026-11-01

结论：本轮把能在本机独立完成的核心功能、数据可靠性和交付工具补齐了。代码与本地测试层面的闭环已有证据；在线 Muse/USDA、真实 iPhone 计数准确率、HealthKit 实际写入和签名安装仍需外部验收，因此不能把项目称为“已经完成全部真实环境验收”。本轮没有启动模拟器，也没有做 UI debug。

范围来自原 Claude 会话“学校项目代码分析与重构”、当前仓库和用户继续完善后端/功能并 commit/push 的授权。后续愿望清单不等于 MVP 缺陷：Watch、云同步、App Attest、3D/SAM、学习型动作识别仍按 `rebuild-brief.md` §12 管理。

## 功能状态

| 模块 | 当前能力 | 验证边界 |
| --- | --- | --- |
| 用户资料与目标 | 引导、资料编辑、体重记录、单位切换、目标与热量/宏量营养规划；活动目标存储 | Domain、仓库测试和 iOS 编译通过；真实交互按用户要求未验收 |
| 动作引擎 | 深蹲、俯卧撑的侧面计数；姿态门控、平滑、分段、部分次数、评分、节奏和速度损失；其余目录动作可手动记录 | 生成数据回归通过；真人准确率、遮挡、光照和相机性能未确认 |
| 训练执行 | 开始/恢复草稿、添加动作、手动/相机记录、编辑/删除组、结束/丢弃训练；计划目标与实际完成量分开 | 实际 reducer、SQLite 仓库和功能测试通过 |
| 中断恢复 | 每个已处理有效次数更新稳定组 ID；结束/重试更新同一行并保留已有 rep ID；无结束时间的组标为中断 | 文件数据库重新打开、重复最终保存测试通过；未提交的最后一个在途写入仍可能被强制终止 |
| 历史与进度 | Today/Train 可进入历史、加载更多、按动作筛选、查看已保存组和次数数据、删除训练；动作进度只使用该动作的组 | 功能测试确认筛选、统计和删除；趋势读取最近最多 1,000 组，历史会话分页加载 |
| 休息 | 计划休息秒数参与倒计时；无计划默认 90 秒；使用持久化组结束时间计算绝对截止时间 | 跨时间推进/重建计算测试通过；不依赖后台 timer 持续运行 |
| 录制与评估 | 独立保留 opt-in 骨架 JSONL、零次数录制、Files 导出副本；真实计数由人标注；切换镜头保守标为 unknown/mixed-camera | recorder 和导入测试通过；不能拿 replay/混合镜头/未标注片段冒充真人准确率证据 |
| 饮食 | 手动录入、已有食物搜索/照片流程、编辑/删除/复用、日汇总；g/ml 持久化；保存修正后的营养基准 | 实际 MealDraft 与 SQLite 测试通过；在线搜索/照片识别需要已配置代理和密钥 |
| Health | 业务写入与同步意图同事务；部分权限按类型写入；版本比较防止旧结果覆盖；失败退避；关闭导出时仍重试删除 | 本地真实仓库 + fake Health writer/service 测试通过；未以真实 Health app 内容作为成功证据 |
| Muse 教练 | 组点评、会话总结、带本地读工具的聊天、确认后写入的计划/饮食/目标提议；结构校验、缓存和离线点评路径 | 客户端协议、流式响应、工具、重试/错误等测试通过；真实 Meta 响应质量和延迟尚待密钥验收 |
| 代理 | 无运行时第三方依赖的 Worker；安装令牌、模型/输入限制、SSE、USDA 规范化、kill switch；SQLite Durable Object 原子全局与 token 额度 | 146 测试、真实本地 Worker、TypeScript 检查、dry-run bundle 通过；未部署线上服务 |
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

## 数据与架构

- 仍是 clean-room 原生实现；本轮未读取旧项目 `.env`，未向 app/仓库写入真实服务密钥。
- `Domain` 与 `MotionCore` 保持只 import Foundation、彼此不依赖；app 负责运动数据映射。
- 新增内部 `AppLogic` 模块，承载 app 实际使用的饮食编辑、数字解析、计划应用、休息和历史逻辑。没有新增第三方 app 依赖。
- 数据库依次应用 `v1`、`v2-nutrition-quantity`、`v3-workout-prescriptions`。不修改旧 v1 SQL，不靠清库升级。
- 老版本没有保存液体单位的行仍按旧 grams 语义迁移；缺失的历史单位无法可靠推断，不能声称已经恢复。
- 对相机引擎的恢复是保存已提交次数，再开始新一组时重新校准，不是从崩溃处恢复相机帧处理。

## 验证证据

本地初次完整检查通过 1,177 项 Swift 测试；随后补齐全局限额错误的客户端映射，并重新跑相关 CoachKit 测试。最终 `tools/check.sh` 的复核正在收集结果，本文件将在检查完成后更新。

已独立完成的检查：

- `swift test --package-path Packages/MovementKit`：1,177 项通过，7 个测试模块。
- `python3 -m unittest discover -s tools/tests -v`：8 项通过。
- `npm test --prefix proxy`：146 项通过。
- `tsc -p proxy/tsconfig.json`：通过（本机已有 TypeScript 5.9.2）。
- `npm audit --prefix proxy --audit-level=moderate`：0 vulnerabilities。
- `npm run build --prefix proxy`：Wrangler 4.156.0 dry-run 成功，不代表已发布。
- 本地真实 `wrangler dev --local`：health 200；同网络 12 个并发安装请求恰好 5 个 201、7 个 429；测试服务随后停止。
- Debug/Release 通用 Simulator SDK 编译和 Release 通用 iOS 设备 SDK 未签名编译：通过。没有启动模拟器或实际安装到手机。
- `tools/accuracy.sh`：生成回归 17/17 精确，打包 replay 2/2 精确；真人片段仍为 0。
- 原生与代理 GitHub Actions 已启动；结果在 `completion-status.md` 记录，不能用本地通过替代云端运行结果。

## 仍需的外部输入与验收

| 项目 | 为什么现在不能确认 | 接续步骤 |
| --- | --- | --- |
| 在线 Muse/USDA | 仓库默认配置仍无公开代理地址，KV namespace 是部署占位值；没有把真实密钥放进本地源码。未检查云账户中是否已有其他部署 | 按 `proxy/README.md` 登录 Cloudflare、填 namespace、设置 `MODEL_API_KEY`/`USDA_API_KEY`、部署；把 Worker HTTPS URL 传给 `COACH_PROXY_URL`，跑 `tools/muse-smoke.sh` |
| 签名安装和 HealthKit | 未选择用户开发团队并连接一台签名可用的真实 iPhone；未执行真实 Health 授权/读写验收 | 按 `docs/device-checklist.md` 配置团队、capability、安装；验收部分授权、编辑、删除及重启补偿 |
| 真人计数和性能 | 没有真人标注片段或真实相机延迟数据。生成数据成绩不能说明真人精度 | 录制不同人员、环境、前后镜头和 idle/partial；人工标注后导入，重新生成 accuracy；测真实设备帧延迟和温度/耗电 |
| UI/交互验收 | 用户明确本轮暂不做 UI debug | 后续在真实设备检查布局、横竖屏、VoiceOver、键盘、照片/相机权限、所有入口与整段 demo |
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

代码提交已按批次推送到 `origin/main`；报告和生成记录另作文档提交。完整历史见 `docs/build-log.md`。
