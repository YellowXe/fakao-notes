#!/usr/bin/env bash
# 溯源校验 —— 把自检报告里的字幕原文片段拿回字幕逐字检索
#
# 不调用任何模型,纯 grep,零成本。搜不到的片段基本就是编造的。
# 这是切换到便宜模型之后最重要的一道闸。
#
# 用法:
#   ./verify.sh 民法李建伟           # 校验该科全部自检报告
#   ./verify.sh 民法李建伟 07        # 只校验专题07
#   ./verify.sh 三国法               # 三个子学科全查
#
# 退出码:0 = 全部命中;1 = 有未命中(或没找到自检报告)
#
# 兼容 macOS 自带的 bash 3.2。

set -uo pipefail

VAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$VAULT" || exit 1

# shellcheck source=00_流程/map.sh
. "00_流程/map.sh"

SRC_NAME="${1:-}"
if [[ -z "$SRC_NAME" ]]; then
  echo "用法: ./verify.sh <素材目录> [专题号]"
  echo "可用素材目录见 00_流程/目录映射.md"
  exit 1
fi
ONLY_TOPIC="${2:-}"
[[ -n "$ONLY_TOPIC" ]] && ONLY_TOPIC="$(printf '%02d' "$((10#$ONLY_TOPIC))")"

resolve_spec "$SRC_NAME" || exit 1
resolve_mainline

SRC_DIR="00_素材/$SRC_NAME"
[[ -d "$SRC_DIR" ]] || { echo "✗ 素材目录不存在: $SRC_DIR"; exit 1; }

if ! ls "$SRC_DIR"/*.txt >/dev/null 2>&1; then
  echo "✗ $SRC_DIR 下没有 txt 素材,无法校验"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 把全部字幕拼成一份,另存一份去标点的宽松版 ────────────────
# ⚠️ 必须去掉换行:清洗稿有单行版也有多行版,换行是清洗产物而非语义分段。
#    片段若跨行,不去换行会导致大量假失败。
cat "$SRC_DIR"/*.txt | tr -d '\n\r' > "$WORK/all.txt"
strip_punct() {
  sed -e 's/，//g' -e 's/。//g' -e 's/、//g' -e 's/；//g' -e 's/：//g' \
      -e 's/？//g' -e 's/！//g' -e 's/…//g' -e 's/·//g' \
      -e 's/“//g' -e 's/”//g' -e "s/‘//g" -e "s/’//g" \
      -e 's/（//g' -e 's/）//g' -e 's/《//g' -e 's/》//g' \
      -e 's/「//g' -e 's/」//g' -e 's/【//g' -e 's/】//g' \
      -e 's/,//g' -e 's/\.//g' -e 's/;//g' -e 's/://g' \
      -e 's/?//g' -e 's/!//g' -e 's/(//g' -e 's/)//g' \
      -e 's/ //g' -e 's/　//g'
}
strip_punct < "$WORK/all.txt" > "$WORK/all.loose.txt"

# ── 收集自检报告 ─────────────────────────────────────────────
# 三国法要遍历三个子学科;所有科目都要顺带看 补充/
collect_reports() {
  local dirs=""
  if [[ "$SRC_NAME" == "三国法" ]]; then
    for s in $SANGUOFA_SUBJECTS; do
      dirs="$dirs $OUT_BASE/$s/_自检 $OUT_BASE/$s/补充/_自检"
    done
  else
    dirs="$OUT_BASE/_自检 $OUT_BASE/补充/_自检"
  fi
  for d in $dirs; do
    [[ -d "$d" ]] || continue
    for f in "$d"/专题*.md; do
      [[ -e "$f" ]] || continue
      if [[ -n "$ONLY_TOPIC" ]]; then
        case "$(basename "$f")" in
          专题${ONLY_TOPIC}*) ;;
          *) continue ;;
        esac
      fi
      echo "$f"
    done
  done
}

# ── 提取「## 溯源」小节里反引号包裹的片段 ────────────────────
extract_snippets() {
  awk '
    /^##[ 　]*溯源/ { inblock = 1; next }
    /^##[ 　]/      { inblock = 0 }
    inblock         { print }
  ' "$1" \
  | grep -o '`[^`]*`' \
  | sed -e 's/^`//' -e 's/`$//' \
  | grep -v '^[[:space:]]*$' \
  | grep -v '^——$' \
  | grep -v '^-*$' \
  | grep -v '^#' \
  | grep -v '\.\(txt\|md\|sh\|py\)$' \
  | grep -v '^【.*】$'
}

REPORTS="$(collect_reports)"
if [[ -z "$REPORTS" ]]; then
  echo "✗ 没找到自检报告。"
  echo "  期望路径: $OUT_BASE/_自检/专题NN.md"
  [[ "$SRC_NAME" == "三国法" ]] && echo "            $OUT_BASE/<子学科>/_自检/专题NN.md"
  echo "  格式见 00_流程/自检报告模板.md"
  exit 1
fi

echo "素材: $SRC_DIR  ($(ls "$SRC_DIR"/*.txt | wc -l | tr -d ' ') 个文件)"
echo "规范: $SPEC_FILE"
echo

TOTAL=0; HIT=0; LOOSE=0; MISS=0
MISS_LIST=""

while IFS= read -r report; do
  [[ -z "$report" ]] && continue
  n=0; h=0; l=0; m=0
  local_miss=""

  while IFS= read -r snip; do
    [[ -z "$snip" ]] && continue
    n=$(( n + 1 ))
    if grep -qF -- "$snip" "$WORK/all.txt"; then
      h=$(( h + 1 ))
    else
      loose_snip="$(printf '%s' "$snip" | strip_punct)"
      if [[ -n "$loose_snip" ]] && grep -qF -- "$loose_snip" "$WORK/all.loose.txt"; then
        l=$(( l + 1 ))
        local_miss="${local_miss}      ⚠ 仅忽略标点后命中: \`${snip}\`"$'\n'
      else
        m=$(( m + 1 ))
        local_miss="${local_miss}      ✗ 字幕中找不到:     \`${snip}\`"$'\n'
      fi
    fi
  done < <(extract_snippets "$report")

  if [[ "$n" -eq 0 ]]; then
    echo "⚠ $report"
    echo "      没提取到任何片段 —— 检查是否有「## 溯源」小节、片段是否用反引号包裹"
    MISS=$(( MISS + 1 ))
    MISS_LIST="${MISS_LIST}${report}(无片段)"$'\n'
    continue
  fi

  if [[ "$m" -eq 0 && "$l" -eq 0 ]]; then
    echo "✓ $report   ${n} 条全部命中"
  else
    echo "✗ $report   共 ${n} 条:命中 ${h},仅忽略标点命中 ${l},找不到 ${m}"
    printf '%s' "$local_miss"
    MISS_LIST="${MISS_LIST}${report}"$'\n'
  fi

  # ── 覆盖率提示 ────────────────────────────────────────────
  # 脚本只能验「填进来的对不对」,验不了「该填的填没填」。
  # 溯源表填得越少越容易全部命中,所以粗略比一下笔记里的数字量。
  tp_num="$(basename "$report" .md | sed 's/^专题//')"
  note_dir="$(dirname "$(dirname "$report")")"
  note_file="$(ls "$note_dir"/专题${tp_num}*.md 2>/dev/null | head -1)"
  if [[ -n "$note_file" && -f "$note_file" ]]; then
    note_nums="$(grep -o '[0-9][0-9]*' "$note_file" | wc -l | tr -d ' ')"
    echo "      笔记中出现数字 ${note_nums} 处,溯源表 ${n} 条"
    if [[ "$note_nums" -gt 0 ]] && [[ $(( n * 3 )) -lt "$note_nums" ]]; then
      echo "      ⚠ 溯源表条数明显偏少 —— 大量数字未被校验。"
      echo "        规范要求法条/数字/真题/口诀「每一条都要能指回字幕」;"
      echo "        某类超过 20 条时列前 20 条并注明该类总数。"
    fi
  fi

  TOTAL=$(( TOTAL + n )); HIT=$(( HIT + h )); LOOSE=$(( LOOSE + l )); MISS=$(( MISS + m ))
done < <(printf '%s\n' "$REPORTS")

echo
echo "════════ 汇总 ════════"
echo "片段总数:       $TOTAL"
echo "严格命中:       $HIT"
echo "忽略标点后命中: $LOOSE   (片段没照抄原文,建议修正;不算幻觉)"
echo "字幕中找不到:   $MISS"

if [[ "$MISS" -gt 0 ]]; then
  echo
  echo "⚠️  「找不到」的条目要逐条处理,两种可能:"
  echo "   1. 片段没有原样照抄字幕(改成了笔记里的规范表述)→ 修正自检报告"
  echo "   2. 内容是编造的 → 回笔记里把对应表述删掉,并重跑该专题"
  echo
  echo "   ⚠️ 第 2 种若出现在数字、法条编号、真题上,说明该模型在本科不可信,"
  echo "      不要放开批量。"
  exit 1
fi

echo
echo "✓ 全部片段都能在字幕中定位。"
[[ "$LOOSE" -gt 0 ]] && echo "  (有 $LOOSE 条建议改成原文照抄,便于后续复核)"
exit 0
