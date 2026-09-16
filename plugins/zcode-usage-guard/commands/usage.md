---
description: 查询智谱 GLM Coding Plan 的 5 小时/每周/每月额度与用量
allowed-tools: Bash, Read
---

# GLM Coding Plan 用量查询

使用 Skill 工具调用 `zcode-usage-guard:zcode-usage` 技能执行一次用量查询(如技能不可用,按技能文档直接运行其 scripts/zcode-usage.mjs 脚本)。

## 汇报要求

把输出整理成简洁的中文表格,必须包含:

1. **5 小时 Prompt 池**:已用百分比、重置时间(倒计时)
2. **每周额度**:已用百分比、重置时间
3. **MCP 工具调用(每月)**:已用/总量、剩余次数、重置时间、各工具明细
4. **当日模型用量**:调用次数、token 消耗、高峰期(工作日 14–18 时)/非高峰期拆分、按模型汇总(如有)

## 关键约束

- **只执行一次查询**,无论成功失败,立即返回结果,不要重试
- 不要改写或猜测数字,一切以脚本输出为准
- 失败时原样展示错误信息,并提示:可在悬浮窗点「🔑 配置 API Key」手动填写(存 `~/.zcode/zcode-usage-manual.json`);或检查 `~/.zcode/v2/config.json` 中的 API Key;或去智谱开放平台「个人编程套餐 > 用量统计」查看
