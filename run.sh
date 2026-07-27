#!/usr/bin/env bash
# 法考笔记批量驱动 —— 按专题分组,逐专题调用 CLI 生成深入版
#
# 用法:
#   ./run.sh 国际法              # 跑该目录全部专题
#   ./run.sh 国际法 03 04 05     # 只跑指定专题
#   DRYRUN=1 ./run.sh 国际法     # 只打印计划,不调用模型(强烈建议先跑这个)
#
# 环境变量:
#   CONC=1      并发专题数(默认 1)。⚠️ 首批务必 1,回填错字表后再放开
#   CLI="..."   调用命令,prompt 从 stdin 传入(默认 claude -p)
#   OUTDIR=...  输出目录,覆盖内置映射
#
# 只生成深入版。预习版/冲刺版用 /rollup,不在本脚本范围内。

set -uo pipefail

VAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$VAULT" || exit 1

SRC_NAME="${1:-}"
[[ -z "$SRC_NAME" ]] && { echo "用法: ./run.sh <素材目录> [专题号...]"; exit 1; }
shift
ONLY_TOPICS=("$@")

CONC="${CONC:-1}"
CLI="${CLI:-claude -p}"
DRYRUN="${DRYRUN:-0}"
MIN_CHARS=2000

SRC_DIR="00_素材/$SRC_NAME"
[[ -d "$SRC_DIR" ]] || { echo "✗ 素材目录不存在: $SRC_DIR"; exit 1; }

# ── 素材目录 → 分科规范 / 输出目录 ───────────────────────────
case "$SRC_NAME" in
  国际法)       SPEC=三国法; OUT_DEFAULT="三国法/国际公法" ;;
  国际私法)     SPEC=三国法; OUT_DEFAULT="三国法/国际私法" ;;
  国际经济法)   SPEC=三国法; OUT_DEFAULT="三国法/国际经济法" ;;
  *_*)          SPEC="${SRC_NAME%%_*}"; OUT_DEFAULT="$SPEC" ;;   # 民法_张 → 民法
  *)            SPEC="$SRC_NAME";       OUT_DEFAULT="$SRC_NAME" ;;
esac
SPEC_FILE="00_规范/${SPEC}.md"
OUT_DIR="${OUTDIR:-$OUT_DEFAULT}"

[[ -f "$SPEC_FILE" ]] || { echo "✗ 分科规范不存在: $SPEC_FILE"; exit 1; }
[[ -f "CLAUDE.md"  ]] || { echo "✗ CLAUDE.md 不存在,请在 vault 根目录运行"; exit 1; }
mkdir -p "$OUT_DIR"

echo "素材: $SRC_DIR"
echo "规范: $SPEC_FILE"
echo "输出: $OUT_DIR/"
echo "并发: $CONC   CLI: $CLI   DRYRUN: $DRYRUN"
echo

# ── 分组:只抽两个数字 ────────────────────────────────────────
# 集号   = 文件名开头连续数字
# 专题号 = "专题" 之后连续数字
declare -A GROUP
while IFS= read -r -d '' f; do
  base="$(basename "$f")"
  ep="$(printf '%s' "$base"   | grep -oP '^\d+'         | head -1)"
  tp="$(printf '%s' "$base"   | grep -oP '(?<=专题)\d+' | head -1)"
  [[ -z "$tp" ]] && { echo "⚠ 无专题号,跳过: $base"; continue; }
  tp="$(printf '%02d' "$((10#$tp))")"
  ep="${ep:-000}"
  GROUP[$tp]+="${ep}|${f}"$'\n'
done < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.txt' -print0 | sort -z)

[[ ${#GROUP[@]} -eq 0 ]] && { echo "✗ 未找到任何可分组的 txt"; exit 1; }

# ── 单专题处理 ───────────────────────────────────────────────
run_topic() {
  local tp="$1" entries="$2"
  local files=() total=0 too_small=""

  # 组内按集号升序
  while IFS='|' read -r ep path; do
    [[ -z "$path" ]] && continue
    local n; n="$(wc -m < "$path" | tr -d ' ')"
    (( n < MIN_CHARS )) && too_small+="  - $(basename "$path") (${n} 字)"$'\n'
    total=$(( total + n ))
    files+=("$path")
  done < <(printf '%s' "$entries" | sort -t'|' -k1,1n)

  # 幂等:输出已存在则跳过
  if compgen -G "$OUT_DIR/专题${tp}*.md" > /dev/null; then
    echo "⊘ 专题$tp 已存在,跳过"
    return 0
  fi

  # 输入校验:残缺素材宁可不跑
  if [[ -n "$too_small" ]]; then
    echo "✗ 专题$tp 跳过 —— 存在字数 < ${MIN_CHARS} 的文件(疑似清洗时被清空):"
    printf '%s' "$too_small"
    return 0
  fi

  echo "▶ 专题$tp  ${#files[@]} 个文件  ${total} 字"
  printf '    %s\n' "${files[@]/#/}" | sed "s|$SRC_DIR/||"

  local prompt
  prompt="$(cat <<EOF
请先读取下列文件,并在开始前声明你读到了哪几个:

1. CLAUDE.md            —— 特别是开头的「五条铁律」
2. ${SPEC_FILE}          —— 分科规范,与 CLAUDE.md 冲突时以此为准
3. 00_样本/反例/反例_典型幻觉形态.md —— 七种幻觉形态,产出前后各自查一遍

⚠️ 读不到 ${SPEC_FILE} 就中止并报告,不要用通用规则代跑。

任务:处理三国法/本科专题 ${tp},产出深入版,写入 ${OUT_DIR}/ 目录。

本专题素材(已按集号升序,请全部读入后合并产出**一个**笔记文件):
$(printf '%s\n' "${files[@]}")

输入总字数:${total}

要求:
- 不要再自行分组,上面就是本专题的完整文件列表
- 完成后按 CLAUDE.md「处理完的自检」输出四张表的**实际结果**
  (触发词覆盖表需实际计数;高风险项溯源表需附 8–20 字字幕原文片段)
- 只处理这一个专题,不要继续下一个
- 不要修改 CLAUDE.md 和 ${SPEC_FILE}
EOF
)"

  if [[ "$DRYRUN" == "1" ]]; then
    echo "    [DRYRUN] 未调用模型"
    return 0
  fi

  local log="$OUT_DIR/.log_专题${tp}.txt"
  if printf '%s' "$prompt" | $CLI > "$log" 2>&1; then
    echo "✓ 专题$tp 完成   日志: $log"
  else
    echo "✗ 专题$tp 失败(退出码 $?),见 $log"
  fi
}

# ── 主循环 ───────────────────────────────────────────────────
topics=($(printf '%s\n' "${!GROUP[@]}" | sort))
if [[ ${#ONLY_TOPICS[@]} -gt 0 ]]; then
  filtered=()
  for t in "${ONLY_TOPICS[@]}"; do
    t="$(printf '%02d' "$((10#$t))")"
    [[ -n "${GROUP[$t]:-}" ]] && filtered+=("$t") || echo "⚠ 专题$t 无素材,忽略"
  done
  topics=("${filtered[@]}")
fi

echo "计划处理 ${#topics[@]} 个专题: ${topics[*]}"
echo

running=0
for tp in "${topics[@]}"; do
  if [[ "$CONC" -le 1 ]]; then
    run_topic "$tp" "${GROUP[$tp]}"
  else
    run_topic "$tp" "${GROUP[$tp]}" &
    running=$(( running + 1 ))
    (( running >= CONC )) && { wait -n 2>/dev/null || wait; running=$(( running - 1 )); }
  fi
done
wait

echo
echo "全部结束。接下来:"
echo "  1. 逐个验收深入版(重点看溯源表和被舍弃的考点)"
echo "  2. /backfill $SRC_NAME   回填错字表"
echo "  3. 全科跑完后 /rollup $SRC_NAME   生成预习版和冲刺版"
