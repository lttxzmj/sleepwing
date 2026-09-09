# Sleepwing 工程标准（强制）

> 一切进入 `Sources/`、`Tests/`、`Scripts/` 的变更都必须满足本文。
> 机器可查的条目由 `Scripts/quality-gate.sh` 在本地、CI、发版编排器三处强制；
> 不可机器化的条目是评审红线，违背即打回重写。本文与 `AGENTS.md`（产品边界）、
> `docs/ops/CLAIMS_LEDGER.md`（宣传边界）共同构成三道闸。

## 一、架构边界（机器强制）

1. **策略归 PerchCore，界面归 Perch**：一切可判定的决策逻辑（状态机、门、
   校验、清洗、调度策略）必须落在 `PerchCore` 为纯函数/纯结构，UI 层只做
   呈现与接线。
2. PerchCore **禁止** `import AppKit` / `import SwiftUI` / `import Cocoa`。
3. PerchCore **禁止** `print(`——核心层没有标准输出这种副作用；诊断走调用方。

## 二、安全与健壮（机器强制）

4. 全库**禁止** `try!` 与 `as!`。错误路径必须显式处理或显式失败关闭
   （fail-closed），不允许"不可能失败"的断言式写法。
5. 一切解析外部输入的代码（hook 载荷、配置文件、许可文件、URL 路由）必须
   fail-closed：尺寸有界、字段校验、异常返回 nil/throw，禁止部分成功。
6. Shell 脚本必须 `set -eu`（或 `set -u` 并对每个可失败步骤显式处理），
   对外网络调用必须带超时，可重试步骤显式重试，不可重试步骤失败即停。

## 三、测试纪律（机器 + 评审强制）

7. **PerchCore 的行为变更必须与确定性测试同 commit**——没有测试的核心
   变更不存在。
8. **Bug 修复必须附带复现该失败模式的回归测试**（先证明它抓得住旧 bug）。
9. 集成/适配器变更必须附 fixture（真实载荷形状），涉及隐私字段的必须
   证明敏感内容被丢弃。
10. `swift test` 全绿是一切提交的前置；发版构建 `-warnings-as-errors`，
    **新警告 = 构建失败**。

## 四、卫生（机器强制）

11. **禁止落地 TODO / FIXME / XXX**——未完成的想法进 `docs/ops/backlog.md`
    或 issue，不进代码。
12. 中英本地化必须同 commit 更新；引用的 key 必须存在（既有测试
    `localizationCataloguesStayInSync` / `viewsOnlyReferenceDefinedLocalizationKeys` 强制）。

## 五、评审红线（不可机器化，违背即打回）

13. **注释只写代码写不出的约束与"为什么不能是别的写法"**；禁止叙述式注释
    （"下一行做 X"）、来源标记、对评审者说话的注释。
14. 隐私白名单是硬边界：载荷新增任何字段都必须先过 sanitizer 测试证明
    其内容有界且不含提示词/代码/路径/错误正文。
15. 用户可见变更必须同 commit 写入 CHANGELOG `[Unreleased]`（周五自动
    发版依赖它）。
16. 提交信息：祈使句、说清结果而非过程；一个提交一个意图。
17. 版本纪律：patch 可自动发；minor/major 与任何有风险取舍的变更是人的
    决定，自动化永不越权。

## 执行点

| 环节 | 强制方式 |
|---|---|
| 本地开发 | 动过 `Sources/` 后提交前必须 `sh Scripts/quality-gate.sh` 全绿 |
| CI（公开仓库） | workflow 内跑 quality-gate + 全量测试 + warnings-as-errors 构建 |
| 发版 | `release.sh` 在构建前先跑 quality-gate，不绿不发 |
| 定时代理 | 一切写代码的代理提示词必须包含"提交前 quality-gate 全绿"；本文由 LESSONS 引用 |

例外流程：确需豁免某条机器规则时，必须在本文追加书面例外（范围+理由+
到期条件）并同 commit——没有书面例外就没有例外。
