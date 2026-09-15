---
name: quota-guard
description: 无人值守续跑协议。当用户要求长时间/通宵/无人值守运行任务,或额度快用完想自动续跑,或 Stop hook 注入了额度收尾协议时使用。定义交接文件格式、布置重置后自动续跑的定时任务、以及唤醒后的恢复流程。
---

# quota-guard:无人值守续跑协议

目标:额度耗尽时优雅收尾,重置后 5 分钟内自动恢复任务,实现长期无人值守。

## 关键事实

- 额度快照:`~/.zcode/scripts/usage-state.json`(由悬浮窗每 10 分钟、会话启动 hook 实时刷新)。
  字段:`pools[]{key,label,usedPct,resetAt}`,`resetAt` 是 epoch 毫秒。
- 绑定约束:**5 小时池(prompt5h)和每周额度(weekly)要一起看**,布置续跑的触发时间 = 超阈值池中
  **最晚的 resetAt**,否则可能白等(5 小时池重置了但每周额度仍是 0)。
- Stop hook 最多放行 3 次续跑请求,**第一轮必须完成全部收尾动作**。

## 收尾流程(收到 Stop hook 的 reason,或用户要求布置续跑时)

1. **写交接文件** `~/.zcode/quota-handoff.md`,必须自包含(新会话看不到当前上下文):

   ```markdown
   # 无人值守交接 <日期时间>
   ## 任务目标
   <一段话说清要做成什么,验收标准>
   ## 已完成
   - <进度清单,含关键文件路径/分支/commit>
   ## 下一步(按序)
   1. <具体到可直接执行的步骤>
   ## 恢复指引
   - 工作目录:<绝对路径>
   - 相关会话:sess_xxx(可用 ReadSessionContext 找回细节)
   - 注意事项:<约定、坑、不要动的东西>
   ```

2. **布置续跑定时任务**:用 CronCreate,参数要求:
   - 时间 = 绑定池 `resetAt` 换算成的**本地绝对时间 + 5 分钟**(recurring=false、maxRuns=1;
     换算出的时间若已过去,说明快照过期,先重新查询)
   - prompt 必须包含(自包含,不引用本轮对话):
     ```
     读取 ~/.zcode/quota-handoff.md,按其中"恢复指引"继续执行任务。
     开始前先运行 node ~/.zcode/scripts/zcode-usage.mjs 复查额度:
     若仍超阈值,重新布置本任务(新的重置时间 + 5 分钟)后正常结束;低于阈值才继续干活。
     ```
3. **写标记文件**:向 `~/.zcode/scripts/resume-armed.flag` 写入
   `{"armedForResetAt": <绑定池 resetAt>}`。Stop 检查据此放行;重置周期翻篇后自动失效。
4. 正常结束回复,不再发起新的大型工作。

## 唤醒流程(续跑任务触发的新会话)

1. 先运行 `node ~/.zcode/scripts/zcode-usage.mjs` 复查额度,确认低于阈值;仍超阈值 →
   重新按"收尾流程"布置下一轮,不要空转消耗。
2. 读 `~/.zcode/quota-handoff.md`,必要时用 ReadSessionContext 按交接文件里的会话 id 找回细节。
3. 按"下一步"继续执行;任务完成或用户接管后,删除交接文件与 `resume-armed.flag`。

## 用户主动询问时

- "还剩多少额度/什么时候重置":直接运行 `node ~/.zcode/scripts/zcode-usage.mjs` 汇报,不要读快照文件猜数字。
- "帮我把这个任务跑到明天早上":评估额度是否够;不够时主动提出按本协议布置续跑,征得同意后执行。
