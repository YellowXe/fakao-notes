#!/usr/bin/env bash
# 目录映射的共享实现 —— 被 run.sh 和 verify.sh 引用(source)
#
# ⚠️ 单一事实源是 00_流程/目录映射.md。改本文件必须同步改那份文档,
#    否则人看的规则和机器执行的规则会不一致,且不会报错。
#
# 兼容 macOS 自带的 bash 3.2:不使用关联数组。

# 素材目录 → SPEC(分科规范名) / OUT_BASE(输出根) / TEACHER(老师名,单老师为空)
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
      echo "✗ 未知素材目录: $1" >&2
      echo "  已登记的目录见 00_流程/目录映射.md;新增目录需同时改该文件与 00_流程/map.sh" >&2
      return 1 ;;
  esac
  SPEC_FILE="00_规范/${SPEC}.md"
  return 0
}

# 子学科识别(仅三国法)
# ⚠️ 顺序不可颠倒:私法、经济法的名字里也含"国际"二字,必须先匹配长的
detect_sub() {
  case "$1" in
    *国际私法*)          echo 国际私法   ;;
    *国际经济法*)        echo 国际经济法 ;;
    *国际公法*|*国际法*) echo 国际公法   ;;
    *)                   echo ""         ;;
  esac
}

# 三国法的三个子学科(供 verify.sh 遍历)
# ⚠️ 变量名只能用 ASCII —— bash 不接受中文变量名(bash 3.2 会直接报 command not found)
SANGUOFA_SUBJECTS="国际公法 国际私法 国际经济法"

# 读分科规范里的主线老师字段
read_main_teacher() {
  grep -m1 '^主线老师:' "$SPEC_FILE" 2>/dev/null | sed 's/^主线老师:[[:space:]]*//'
}

# 本次的老师是否为主线(单老师科目恒为是)
# 用法:resolve_mainline;结果写入 IS_MAINLINE
resolve_mainline() {
  IS_MAINLINE=1
  if [[ -n "${TEACHER:-}" ]]; then
    MAIN_TEACHER="$(read_main_teacher)"
    if [[ "$MAIN_TEACHER" == *"$TEACHER"* ]]; then IS_MAINLINE=1; else IS_MAINLINE=0; fi
  else
    MAIN_TEACHER="$(read_main_teacher)"
  fi
}

# 输出目录  $1 = 子学科(可为空)
compute_out() {
  if [[ -n "${OUTDIR:-}" ]]; then echo "$OUTDIR"; return; fi
  local base="$OUT_BASE"
  [[ -n "${1:-}" ]] && base="$base/$1"
  [[ "${IS_MAINLINE:-1}" -eq 0 ]] && base="$base/补充"
  echo "$base"
}
