#!/usr/bin/env bash
# 法考笔记批量驱动 —— 按专题分组,逐专题调用 CLI 生成深入版
#
# 用法:
#   ./run.sh 三国法                    # 跑该目录全部专题(三个子学科都跑)
#   SUB=国际私法 ./run.sh 三国法        # 只跑一个子学科
#   ./run.sh 民法李建伟 07             # 只跑指定专题
#   DRYRUN=1 ./run.sh 三国法           # 只打印计划,不调用模型(建议先跑这个)
#
# 环境变量:
#   CONC=1      并发专题数(默认 1)。⚠️ 首批务必 1,回填错字表后再放开
#   CLI="..."   调用命令,prompt 从 stdin 传入(默认 claude -p)
#   SUB=...     只处理指定子学科(仅三国法有意义)
#   OUTDIR=...  强制指定输出目录,覆盖自动推导
#
# 目录映射的单一事实源是 00_流程/目录映射.md,本文件的 resolve_spec() 必须与之一致。
# 只生成深入版。预习版/冲刺版用 /rollup,不在本脚本范围内。

set -uo pipefail

VAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$VAULT" || exit 1

SRC_NAME="${1:-}"
if [[ -z "$SRC_NAME" ]]; then
  echo "用法: ./run.sh <素材目录> [专题号...]"
  echo "可用素材目录见 00_流程/目录映射.md"
  exit 1
fi
shift
# 存成字符串而非数组:bash 3.2 + set -u 下,空数组的 ${#arr[@]} 会报 unbound
ONLY_TOPICS="$*"

CONC="${CONC:-1}"
CLI="${CLI:-claude -p}"
DRYRUN="${DRYRUN:-0}"
SUB_FILTER="${SUB:-}"
MIN_CHARS=2000

# ── 素材目录 → 分科规范 / 输出根 / 老师 ──────────────────────
# ⚠️ 与 00_流程/目录映射.md 保持一致。目录名和规范文件名有两处不一致,
#    不要改成字符串推导。
resolve_spec() {
  case "$1" in
    三国法)     SPEC=三国法;               OUT_BASE=三国法;              TEACHER=杨     ;;
    刑法)       SPEC=刑法;                 OUT_BASE=刑法;                TEACHER=""     ;;
    民法李建伟) SPEC=民法;                 OUT_BASE=民法;                TEACHER=李建伟 ;;
    民法孟献贵) SPEC=民法;                 OUT_BASE=民法;                TEACHER=孟献贵 ;;
    民诉法)     SPEC=民诉;                 OUT_BASE=民诉;                TEACHER=""     ;;
    刑诉向高甲) SPEC=刑诉;                 OUT_BASE=刑诉;                TEACHER=向高甲 ;;
    刑诉左宁)   SPEC=刑诉;                 OUT_BASE=刑诉;                TEACHER=左宁   ;;
    行政法)     SPEC=行政法与行政诉讼法;   OUT_BASE=行政法与行政诉讼法;  TEACHER=""     ;;
    理论法)     SPEC=理论法;               OUT_BASE=理论法;              TEACHER=""     ;;
    商经知)     SPEC=商经知;               OUT_BASE=商经知;              TEACHER=""     ;;
    *)
      echo "✗ 未知素材目录: $1"
      echo "  已登记的目录见 00_流程/目录映射.md;新增目录需同时改该文件与本脚本 resolve_spec()"
      exit 1 ;;
  esac
}

# ── 子学科识别(仅三国法) ─────────────────────────────────────
# ⚠️ 顺序不可颠倒:私法、经济法的名字里也含"国际"二字,必须先匹配长的
detect_sub() {
  case "$1" in
    *国际私法*)          echo 国际私法   ;;
    *国际经济法*)        echo 国际经济法 ;;
    *国际公法*|*国际法*) echo 国际公法   ;;
    *)                   echo ""         ;;
  esac
}

resolve_spec "$SRC_NAME"
SRC_DIR="00_素材/$SRC_NAME"
SPEC_FILE="00_规范/${SPEC}.md"

[[ -d "$SRC_DIR"   ]] || { echo "✗ 素材目录不存在: $SRC_DIR"; exit 1; }
[[ -f "$SPEC_FILE" ]] || { echo "✗ 分科规范不存在: $SPEC_FILE"; exit 1; }
[[ -f "CLAUDE.md"  ]] || { echo "✗ CLAUDE.md 不存在,请在 vault 根目录运行"; exit 1; }

# ── 主线老师:决定产出进正式目录还是 补充/ ────────────────────
MAIN_TEACHER="$(grep -m1 '^主线老师:' "$SPEC_FILE" | sed 's/^主线老师:[[:space:]]*//')"
IS_MAINLINE=1
if [[ -n "$TEACHER" ]]; then
  if [[ "$MAIN_TEACHER" == *"$TEACHER"* ]]; then
    IS_MAINLINE=1
  else
    IS_MAINLINE=0
  fi
fi

compute_out() {   # $1 = 子学科(可为空)
  if [[ -n "${OUTDIR:-}" ]]; then echo "$OUTDIR"; return; fi
  local base="$OUT_BASE"
  [[ -n "$1" ]] && base="$base/$1"
  [[ "$IS_MAINLINE" -eq 0 ]] && base="$base/补充"
  echo "$base"
}

echo "素材: $SRC_DIR"
echo "规范: $SPEC_FILE"
[[ -n "$TEACHER" ]] && echo "老师: $TEACHER   (规范中主线老师: ${MAIN_TEACHER:-未填})"
if [[ "$IS_MAINLINE" -eq 0 ]]; then
  echo "⚠️  该老师非主线(或主线未定),产出将进入 补充/ 子目录"
fi
[[ -n "$SUB_FILTER" ]] && echo "子学科过滤: $SUB_FILTER"
echo "并发: $CONC   CLI: $CLI   DRYRUN: $DRYRUN"
echo

# ── 分组 ─────────────────────────────────────────────────────
# 用临时目录代替关联数组,以兼容 macOS 自带的 bash 3.2
# 每个分组一个文件,文件名 = <子学科>#<专题号>,内容每行 "集号|路径"
# 集号   = 文件名开头连续数字
# 专题号 = "专题" 之后连续数字
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/groups"
NO_TOPIC=""

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  base="$(basename "$f")"
  ep="$(printf '%s' "$base" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')"
  tp="$(printf '%s' "$base" | sed -n 's/.*专题\([0-9][0-9]*\).*/\1/p')"
  if [[ -z "$tp" ]]; then
    NO_TOPIC="${NO_TOPIC}    ${base}"$'\n'
    continue
  fi
  tp="$(printf '%02d' "$((10#$tp))")"
  [[ -z "$ep" ]] && ep="000"

  sub=""
  if [[ "$SRC_NAME" == "三国法" ]]; then
    sub="$(detect_sub "$base")"
    if [[ -z "$sub" ]]; then
      echo "⚠ 无法判断子学科,跳过: $base"
      continue
    fi
    if [[ -n "$SUB_FILTER" && "$sub" != "$SUB_FILTER" ]]; then continue; fi
  fi

  printf '%s|%s\n' "$ep" "$f" >> "$WORK/groups/${sub}#${tp}"
done < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.txt' | sort)

if [[ -n "$NO_TOPIC" ]]; then
  echo "⚠ 以下文件名中找不到「专题N」,已跳过(可能是学科导学一类,需手动处理):"
  printf '%s' "$NO_TOPIC"
  echo
fi

if [[ -z "$(ls -A "$WORK/groups" 2>/dev/null)" ]]; then
  echo "✗ 未找到任何可分组的 txt"
  exit 1
fi

# ── 单专题处理 ───────────────────────────────────────────────
run_topic() {
  local key="$1"
  local entries; entries="$(cat "$WORK/groups/$key")"
  local sub="${key%%#*}" tp="${key##*#}"
  local out; out="$(compute_out "$sub")"
  local label="专题$tp"; [[ -n "$sub" ]] && label="$sub 专题$tp"
  local files=() total=0 too_small=""

  while IFS='|' read -r ep path; do
    [[ -z "$path" ]] && continue
    local n; n="$(wc -m < "$path" | tr -d ' ')"
    (( n < MIN_CHARS )) && too_small+="    - $(basename "$path") (${n} 字)"$'\n'
    total=$(( total + n ))
    files+=("$path")
  done < <(printf '%s' "$entries" | sort -t'|' -k1,1n)

  mkdir -p "$out"

  if compgen -G "$out/专题${tp}*.md" > /dev/null; then
    echo "⊘ $label 已存在,跳过"
    return 0
  fi

  if [[ -n "$too_small" ]]; then
    echo "✗ $label 跳过 —— 存在字数 < ${MIN_CHARS} 的文件(疑似清洗时被清空):"
    printf '%s' "$too_small"
    return 0
  fi

  echo "▶ $label   ${#files[@]} 个文件   ${total} 字   → $out/"
  printf '%s\n' "${files[@]}" | sed "s|^$SRC_DIR/|    |"

  local teacher_line=""
  [[ -n "$TEACHER" ]] && teacher_line="frontmatter 的 老师 字段填:${TEACHER}"
  local sub_line=""
  [[ -n "$sub" ]] && sub_line="本专题属于子学科:${sub}(三国法三个子学科各自都有专题01,不要与其他子学科的同号专题混淆)"

  local prompt
  prompt="$(cat <<EOF
请先读取下列文件,并在开始前声明你读到了哪几个:

1. CLAUDE.md            —— 特别是开头的「五条铁律」
2. ${SPEC_FILE}          —— 分科规范,与 CLAUDE.md 冲突时以此为准
3. 00_样本/反例/反例_典型幻觉形态.md —— 七种幻觉形态,产出前后各自查一遍

⚠️ 读不到 ${SPEC_FILE} 就中止并报告,不要用通用规则代跑。

任务:产出深入版一份,写入 ${out}/ 目录。
${sub_line}
${teacher_line}

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

  local log="$out/.log_专题${tp}.txt"
  if printf '%s' "$prompt" | $CLI > "$log" 2>&1; then
    echo "✓ $label 完成   日志: $log"
  else
    echo "✗ $label 失败(退出码 $?),见 $log"
  fi
}

# ── 主循环 ───────────────────────────────────────────────────
# 子学科按 公法 → 私法 → 经济法 排,专题号升序
sort_keys() {
  ( cd "$WORK/groups" && ls ) | awk -F'#' '{
      order = 9
      if ($1 == "")           order = 0
      else if ($1 == "国际公法")   order = 1
      else if ($1 == "国际私法")   order = 2
      else if ($1 == "国际经济法") order = 3
      printf "%d\t%s\t%s\n", order, $2, $0
    }' | sort -k1,1n -k2,2 | cut -f3
}

keys=""
while IFS= read -r k; do
  [[ -z "$k" ]] && continue
  keys="${keys}${k}"$'\n'
done < <(sort_keys)

if [[ -n "$ONLY_TOPICS" ]]; then
  filtered=""
  for t in $ONLY_TOPICS; do
    t="$(printf '%02d' "$((10#$t))")"
    hit=0
    while IFS= read -r k; do
      [[ -z "$k" ]] && continue
      if [[ "${k##*#}" == "$t" ]]; then
        filtered="${filtered}${k}"$'\n'
        hit=1
      fi
    done < <(printf '%s' "$keys")
    if [[ "$hit" -eq 0 ]]; then echo "⚠ 专题$t 无素材,忽略"; fi
  done
  keys="$filtered"
fi

if [[ -z "$keys" ]]; then
  echo "✗ 没有要处理的专题"
  exit 1
fi

count="$(printf '%s' "$keys" | grep -c .)"
echo "计划处理 ${count} 个专题:"
while IFS= read -r k; do
  [[ -z "$k" ]] && continue
  sub="${k%%#*}"; tp="${k##*#}"
  if [[ -n "$sub" ]]; then echo "    $sub 专题$tp"; else echo "    专题$tp"; fi
done < <(printf '%s' "$keys")
echo

running=0
while IFS= read -r k; do
  [[ -z "$k" ]] && continue
  if [[ "$CONC" -le 1 ]]; then
    run_topic "$k"
  else
    run_topic "$k" &
    running=$(( running + 1 ))
    if [[ "$running" -ge "$CONC" ]]; then
      wait -n 2>/dev/null || wait
      running=$(( running - 1 ))
    fi
  fi
done < <(printf '%s' "$keys")
wait

echo
echo "全部结束。接下来:"
echo "  1. 逐个验收深入版(重点看溯源表和被舍弃的考点)"
echo "  2. /backfill $SRC_NAME   回填错字表"
echo "  3. 全科跑完后 /rollup $SRC_NAME   生成预习版和冲刺版"
