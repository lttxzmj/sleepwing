---
name: perch-pet
description: 为 Perch macOS 应用创建、修复、校验并打包完整的动画桌宠。当用户需要 Perch 宠物、自定义桌面伙伴、动画 .perchpet 素材包，或想把角色图/角色创意变成可导入 Perch 的资产时使用。在 Codex 中如有 $hatch-pet 请复用。
---

# Perch Pet（中文版；与 SKILL.md 语义一致，如有出入以英文版为准）

创建一个用户可导入 Perch 的完整动画宠物包。生成过程保持在用户当前的 Agent 内完成。Perch 负责结构复验、预览、安装与运行时行为；制作方 Agent 仍然负责视觉动效 QA。

## 不可协商的 Perch Motion v2 契约

即使其他工具、记忆中的格式或生成的答案与之不符，也以下面这份紧凑契约为准：

```text
PERCH_CONTRACT=v2 atlas=1536x2288 grid=8x11 cell=192x208 alpha=required
rows=idle,drag-right,drag-left,wave,success,failed,waiting,working,review,look-0-to-157.5,look-180-to-337.5
```

- 绝不接受或产出 `2048x2816`、正方形网格、9 行终稿图集或复制粘贴的静止帧。
- 规划视觉工作前先阅读 [references/PET_PACKAGE_SPEC.md](references/PET_PACKAGE_SPEC.md)。
- 生成前运行 `scripts/package_perch_pet.py --print-contract`，并与上面这行对照。
- 任何不一致都要停下。确定性打包器是结构上的最终权威。

## 工作流程

1. 询问或推断角色的简短名字、物种/形态、配色、材质和性格。
2. 有参考图就使用参考图。**参考图相似度不可协商**：产出角色必须仍是同一个可辨认的个体——相同的物种、比例、毛色或羽色、花纹、耳朵与尾巴形状。只允许为适配精灵风格做绘制简化；绝不重新设计、改色或替换成其他角色。画动作行之前先对照参考图确认主形象，QA 签收前再用 contact sheet 对照参考图复查。
3. 阅读包规范并打印确定性契约。
4. 将宿主归类为一种生产模式：
   - `codex-hatch`：Codex 有 `$hatch-pet`；用它完成全部生产。
   - `host-image`：宿主能生成/编辑图像、能检查原尺寸 contact sheet 和动效预览、能运行打包器。
   - `existing-atlas`：宿主不能生成动画，但用户提供了完整的候选 8×11 图集；只做校验和打包。
   - `blocked`：宿主只有文本工具、只有一张静态图，或无法目视检查动效；停止并说明缺失的能力或缺失的完整图集。
5. 视觉工作开始前声明 `PRODUCTION_MODE=<mode>`。绝不暗示「发现了 Skill」就等于具备图像能力。
6. 在专用的临时目录或用户认可的工作目录内进行。不要查看无关的仓库、提示词、对话或源码。
7. 检查原尺寸 contact sheet 和动效预览。打包前修复不合格的行。
8. 写视觉 QA 报告，然后带 `--require-visual-qa` 运行打包器。
9. 返回 `.perchpet` 文件夹的绝对路径，并告知用户在 Perch → 设置 → 角色 → Pet Studio 导入。

## Codex 生产路径

当 `$hatch-pet` 可用时：

1. 携带用户的角色简报与参考图显式调用它。当提供了参考图（例如 Perch 由照片生成的透明参考图）时，必须把其绝对路径通过 `--reference` 传给 hatch-pet 的 `prepare_pet_run.py`，让 base 任务将其作为图像输入（`requires_grounded_generation`）；在该场景下绝不允许不带 `--reference` 准备运行，任何动作行开始前先确认选定的 base 产出与参考图是同一可辨认个体，如果无法以该图为输入进行生成，停止并如实报告，而不是交付一个不同的角色。
2. 由它负责图像生成、确定性图集拼装、方向 QA、修复与 v2 校验。
3. 不要修改已安装的 `hatch-pet` Skill，也不要把它的私有工作文件复制进 Perch。
4. 确认它的最终图集精确为 `1536x2288`；拒绝任何其他记忆中的或报告出的尺寸。
5. 用它打包好的宠物目录和通过的 `qa/run-summary.json` 作为 Perch 打包器输入：

```bash
python3 "<this-skill-dir>/scripts/package_perch_pet.py" \
  --source "$HOME/.codex/pets/<pet-id>" \
  --visual-qa-report "<hatch-run-dir>/qa/run-summary.json" \
  --require-visual-qa \
  --output "$HOME/Desktop/<pet-id>.perchpet"
```

hatch-pet 的运行摘要和最终图集校验都通过之前不要打包。

## 其他 Agent 生产路径

遵循同一套打包与视觉契约，不要假装宿主拥有 Codex 专属工具。

- 具备图像生成加视觉检查能力的宿主，可以使用自己的图像模型或经批准的图像工具。
- 不具备图像生成能力的宿主，可以校验用户提供的完整图集，但不能把一张静态图变成成品宠物。
- 无法检查 contact sheet 与动效预览的宿主，必须在声称视觉 QA 通过之前停止。

非 Codex 的完整生产宿主仍然必须：

- 生成彼此不同、符合各状态语义的动画族
- 保持角色身份、比例、基线、材质与配色一致
- 保持透明输出与安全的格子边界
- 校验全部四个基准注视方向与完整的顺时针注视环
- 目视检查动效预览，而不是接受一张结构合格但视觉损坏的图集

打包前写一份紧凑的 JSON 视觉 QA 报告：

```json
{
  "ok": true,
  "reviewer": "host-agent-or-user",
  "contactSheetReviewed": true,
  "motionPreviewsReviewed": true,
  "directionsReviewed": true
}
```

除非确实检查过对应产物，否则不要把这些字段设为 `true`。

## 打包规则

- 产出以 `.perchpet` 结尾的文件夹，而不是一张静态头像。
- 包含 `pet.json` 和与清单同名的 PNG 或 WebP 精灵图。
- 可选地在 `pet.json` 中包含 `personality` 字符串：一两句第一人称的角色语气描述。Perch 会把它用作宠物的对话人设，让导入的角色用自己的方式说话。
- `preview.webp` 保持可选。
- 让打包器生成 `qa-summary.json`；它记录结构检查与有界的视觉 QA 证据，不含绝对路径。
- 不要直接写入 Perch 的 Application Support 目录。由用户审阅并导入包。
- 如实报告失败，并保留工作目录以便修复。
