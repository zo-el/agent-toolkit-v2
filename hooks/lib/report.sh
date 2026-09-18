# The finding list and the hook report Claude Code reads. Sourced by install.sh
# and hooks/update.sh, so a session start is told about the toolkit and about
# releases in one shape. Contract: documentation/specs/install.md, Reports.
#
# Sourced, never run: it defines and declares, and prints only when asked.

F_SEV=() F_WHO=() F_TEXT=() F_FIX=()
CONTEXT=()   # what the report says after its findings
MESSAGE=()   # what systemMessage says beyond the findings

finding() { # severity (required|advisory), who (user|install|toolkit), text, fix lines
  F_SEV+=("$1") F_WHO+=("$2") F_TEXT+=("$3") F_FIX+=("${4:-}")
}

count() { # severity
  local n=0 s
  for s in "${F_SEV[@]}"; do [ "$s" = "$1" ] && n=$((n + 1)); done
  echo "$n"
}

mark() { [ "$1" = required ] && printf '✗' || printf '!'; }

plural() { [ "$1" -eq 1 ] && echo "$1 $2" || echo "$1 ${2}s"; }

join() { # separator, items
  local sep="$1" out="" item
  shift
  for item in "$@"; do out+="${out:+$sep}$item"; done
  printf '%s' "$out"
}

one_line() { tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-400; }

json_str() {
  local s="$1"
  s="${s//\\/\\\\}" s="${s//\"/\\\"}" s="${s//$'\n'/\\n}" s="${s//$'\t'/\\t}" s="${s//$'\r'/}"
  s="${s//[[:cntrl:]]/}"
  printf '"%s"' "$s"
}

# Exactly one JSON object, or nothing when there is nothing to say. The caller
# owns what counts as something: it fills CONTEXT and MESSAGE first.
hook_report() { # event, the line additionalContext opens with, reloadSkills 0|1
  local i fixes context
  if [ ${#F_SEV[@]} -eq 0 ] && [ ${#CONTEXT[@]} -eq 0 ] && [ ${#MESSAGE[@]} -eq 0 ]; then
    if [ "$3" = 1 ]; then
      printf '{"hookSpecificOutput":{"hookEventName":%s,"reloadSkills":true}}\n' "$(json_str "$1")"
    fi
    return 0
  fi
  context="$2"
  for i in "${!F_SEV[@]}"; do
    mapfile -t fixes <<<"${F_FIX[i]}"
    if [ -n "${F_FIX[i]}" ]; then
      context+=$'\n'"$(mark "${F_SEV[i]}") ${F_TEXT[i]}. Fix (${F_WHO[i]}): $(join "; then " "${fixes[@]}")"
    else
      context+=$'\n'"$(mark "${F_SEV[i]}") ${F_TEXT[i]}. Who acts: ${F_WHO[i]}"
    fi
  done
  for i in "${CONTEXT[@]}"; do context+=$'\n'"$i"; done
  printf '{'
  if [ ${#MESSAGE[@]} -gt 0 ]; then
    printf '"systemMessage":%s,' "$(json_str "agent-toolkit: $(join ". " "${MESSAGE[@]}")")"
  fi
  printf '"hookSpecificOutput":{"hookEventName":%s,"additionalContext":%s' "$(json_str "$1")" "$(json_str "$context")"
  [ "$3" = 1 ] && printf ',"reloadSkills":true'
  printf '}}\n'
}
