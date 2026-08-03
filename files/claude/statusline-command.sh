#!/usr/bin/env bash
input=$(cat)
model_id=$(jq -r '.model.id // ""' <<<"$input")
model_name=$(jq -r '.model.display_name // "Claude"' <<<"$input")
effort=$(jq -r '.effort.level // empty' <<<"$input")
session_cost=$(jq -r '.cost.total_cost_usd // 0' <<<"$input")
five_h_pct=$(jq -r '.rate_limits.five_hour.used_percentage // empty' <<<"$input")
week_pct=$(jq -r '.rate_limits.seven_day.used_percentage // empty' <<<"$input")
five_h_resets=$(jq -r '.rate_limits.five_hour.resets_at // empty' <<<"$input")
week_resets=$(jq -r '.rate_limits.seven_day.resets_at // empty' <<<"$input")
USD_TO_INR=88.50
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
WHITE=$'\033[37m'
GRAY=$'\033[90m'
PLUM=$'\033[38;5;97m'
SLATE=$'\033[38;5;67m'
SAGE=$'\033[38;5;108m'
DUSKBLUE=$'\033[38;5;60m'
OLIVE=$'\033[38;5;136m'
MINT=$'\033[38;5;108m'
STEEL=$'\033[38;5;66m'
AMBER=$'\033[38;5;178m'
TERRACOTTA=$'\033[38;5;173m'
BRICK=$'\033[38;5;131m'
case "$model_id" in
  claude-fable-5*)  emoji="📖"; model_color="$DUSKBLUE" ;;
  claude-mythos-5*) emoji="🏛️"; model_color="$OLIVE" ;;
  claude-opus*)     emoji="👑"; model_color="$PLUM" ;;
  claude-sonnet*)   emoji="🎵"; model_color="$SLATE" ;;
  claude-haiku*)    emoji="🍃"; model_color="$SAGE" ;;
  *)                emoji="✨"; model_color="$WHITE" ;;
esac
case "$effort" in
  low)    effort_color="$MINT" ;;
  medium) effort_color="$STEEL" ;;
  high)   effort_color="$AMBER" ;;
  xhigh)  effort_color="$TERRACOTTA" ;;
  max)    effort_color="$BRICK" ;;
  *)      effort_color="$DIM" ;;
esac
read -r day_cost week_cost < <(python3 "$HOME/.claude/cost_aggregate.py" 2>/dev/null)
day_cost=${day_cost:-0}
week_cost=${week_cost:-0}
bar() {
  local pct="$1" segs=10
  local filled=$(( (${pct%.*} * segs + 50) / 100 ))
  (( filled < 0 )) && filled=0
  (( filled > segs )) && filled=$segs
  local color="$GREEN"
  (( ${pct%.*} >= 50 )) && color="$YELLOW"
  (( ${pct%.*} >= 80 )) && color="$RED"
  local out="${color}"
  for ((i=0; i<filled; i++)); do out+="█"; done
  out+="${GRAY}"
  for ((i=filled; i<segs; i++)); do out+="░"; done
  out+="${RESET}"
  printf '%s' "$out"
}
fmt_inr() {
  awk -v usd="$1" -v rate="$USD_TO_INR" 'BEGIN { printf "₹%.2f", usd * rate }'
}
parts=()
parts+=("${BOLD}${model_color}${emoji} ${model_name}${RESET}")
[ -n "$effort" ] && parts+=("${effort_color}[${effort}]${RESET}")
if [ -n "$five_h_pct" ]; then
  five_h_line="${DIM}5h${RESET} $(bar "$five_h_pct") ${DIM}${five_h_pct%.*}%${RESET}"
  if [ -n "$five_h_resets" ]; then
    five_h_time=$(date -d "@${five_h_resets}" '+%-I:%M %p' 2>/dev/null)
    [ -n "$five_h_time" ] && five_h_line+=" ${DIM}(${five_h_time})${RESET}"
  fi
  parts+=("$five_h_line")
fi
if [ -n "$week_pct" ]; then
  week_line="${DIM}7d${RESET} $(bar "$week_pct") ${DIM}${week_pct%.*}%${RESET}"
  if [ -n "$week_resets" ]; then
    week_date=$(date -d "@${week_resets}" '+%-d %b' 2>/dev/null)
    [ -n "$week_date" ] && week_line+=" ${DIM}(${week_date})${RESET}"
  fi
  parts+=("$week_line")
fi
parts+=("${GREEN}$(fmt_inr "$session_cost")${RESET}${DIM} session${RESET}")
parts+=("${GREEN}$(fmt_inr "$day_cost")${RESET}${DIM} today${RESET}")
parts+=("${GREEN}$(fmt_inr "$week_cost")${RESET}${DIM} week${RESET}")
output=""
for p in "${parts[@]}"; do
  if [ -z "$output" ]; then
    output="$p"
  else
    output="${output}  ${p}"
  fi
done
printf '%s\n' "$output"