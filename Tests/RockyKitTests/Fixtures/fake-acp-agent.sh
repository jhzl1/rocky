#!/bin/bash
# Scripted ACP agent for ChatSessionModel tests.
# Answers initialize, session/new, session/load (replaying one old message first), session/prompt and
# session/set_config_option. session/new and session/load offer the agent's models, the current model's effort levels
# and two modes ("default", "plan"); set_config_option answers with the whole new list, as both adapters do (AGM-07).
# FAKE_ACP_AGENT picks the lists (AGM-02):
#   claude (the default): "default" (Default: Low, High; starts at High) and "opus" (Opus: Low, Medium, High, Max;
#   starts at Medium).
#   opencode: "claude-sonnet-5" (Claude Sonnet 5: High, Max, Default), "gpt-5.5" (GPT-5.5: Minimal, Low, Medium, High,
#   Default), both starting at Default, and "qwen3-coder" (Qwen3 Coder), with no effort option.
# A model change resets the effort to the new model's starting level, as OpenCode does.
# The prompt's tool t1 is an "execute" call.
# A prompt streams "Hel" + "lo", announces tool t1, asks permission, then reports t1 completed or failed.
# FAKE_ACP_LOAD_SESSION=false makes initialize report loadSession=false.
# FAKE_ACP_LOAD_FAILS=true makes session/load answer "Resource not found", like a session the agent does not have.
# FAKE_ACP_ASKS=true makes a prompt ask "Which color?" (Blue or Red) with elicitation/create, as Claude's
# AskUserQuestion does, and reply "answered <color>" or "no answer".
# Commands: right after the session/new and session/load results, as both adapters do from a setTimeout, the agent
# announces compact (with a hint), review (input null) and mcp:linear:triage (with a hint and _meta).
# FAKE_ACP_COMMANDS_EARLY=true sends that list before the session/new result instead, as if the notification had
# reached the client ahead of the response.
# A prompt "change commands" announces a new list, init alone, and ends the turn.
# A prompt "edit files" (DIFF-06) announces two edit calls with Claude's optimistic diffs: t2, a Write that reads as a
# new file (3 lines), and t3, an Edit (a b c → a B C d). It asks permission for t2. Allowed: t2 gets the real hunk
# with Claude's counts (+2 −1) in an update with only content, then completed; t3 completes without content, so its
# optimistic diff stands (+3 −2). Rejected: t2 fails with a text content, and t3 fails.
# A prompt "update edits" then sends t2 completed again without content, and t3 new content (+1 −1), and ends the turn.
# A prompt "add a model" adds "haiku" (Haiku, no effort option) to the models, announces the list in a
# config_option_update, and ends the turn.
# FAKE_ACP_LOG=<file> appends every line the agent receives to that file, to tell what reached it.
load_session="${FAKE_ACP_LOAD_SESSION:-true}"
load_fails="${FAKE_ACP_LOAD_FAILS:-false}"
asks="${FAKE_ACP_ASKS:-false}"
commands_early="${FAKE_ACP_COMMANDS_EARLY:-false}"
log="${FAKE_ACP_LOG:-}"
agent="${FAKE_ACP_AGENT:-claude}"
if [[ $agent == opencode ]]; then
  models='[{"value":"claude-sonnet-5","name":"Claude Sonnet 5"},{"value":"gpt-5.5","name":"GPT-5.5"},{"value":"qwen3-coder","name":"Qwen3 Coder"}]'
  model=claude-sonnet-5
else
  models='[{"value":"default","name":"Default"},{"value":"opus","name":"Opus"}]'
  model=default
fi
# The effort levels of model $1, as a JSON list; nothing for a model without levels.
efforts_of() {
  case "$1" in
    default) echo '[{"value":"low","name":"Low"},{"value":"high","name":"High"}]' ;;
    opus) echo '[{"value":"low","name":"Low"},{"value":"medium","name":"Medium"},{"value":"high","name":"High"},{"value":"max","name":"Max"}]' ;;
    claude-sonnet-5) echo '[{"value":"high","name":"High"},{"value":"max","name":"Max"},{"value":"default","name":"Default"}]' ;;
    gpt-5.5) echo '[{"value":"minimal","name":"Minimal"},{"value":"low","name":"Low"},{"value":"medium","name":"Medium"},{"value":"high","name":"High"},{"value":"default","name":"Default"}]' ;;
  esac
}
# The level model $1 starts at.
starting_effort_of() {
  case "$1" in
    default) echo high ;;
    opus) echo medium ;;
    claude-sonnet-5|gpt-5.5) echo default ;;
  esac
}
effort=$(starting_effort_of "$model")
mode=default
# The session's whole option list, from the state above.
options() {
  local list="[{\"id\":\"model\",\"name\":\"Model\",\"category\":\"model\",\"type\":\"select\",\"currentValue\":\"$model\",\"options\":$models}"
  local levels
  levels=$(efforts_of "$model")
  if [[ -n $levels ]]; then
    list+=",{\"id\":\"effort\",\"name\":\"Effort\",\"category\":\"thought_level\",\"type\":\"select\",\"currentValue\":\"$effort\",\"options\":$levels}"
  fi
  list+=",{\"id\":\"mode\",\"name\":\"Mode\",\"category\":\"mode\",\"type\":\"select\",\"currentValue\":\"$mode\",\"options\":[{\"value\":\"default\",\"name\":\"Manual\"},{\"value\":\"plan\",\"name\":\"Plan\"}]}]"
  echo "$list"
}
update() {
  echo "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"fake-1\",\"update\":$1}}"
}
commands='{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"compact","description":"Clear conversation history but keep a summary in context","input":{"hint":"<optional custom summarization instructions>"}},{"name":"review","description":"Review a pull request","input":null},{"name":"mcp:linear:triage","description":"Triage a Linear issue","input":{"hint":"<issue>"},"_meta":{"source":"mcp"}}]}'
changed_commands='{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"init","description":"Write a CLAUDE.md for this repository"}]}'
while IFS= read -r line; do
  if [[ -n $log ]]; then echo "$line" >> "$log"; fi
  id=""
  if [[ $line =~ \"id\":([0-9]+) ]]; then id="${BASH_REMATCH[1]}"; fi
  case "$line" in
    *'"method":"initialize"'*)
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{\"loadSession\":$load_session}}}"
      ;;
    *'"method":"session/new"'*)
      # Before the result: the client has no session id yet and drops it.
      update '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"too early"}}'
      if [[ $commands_early == true ]]; then update "$commands"; fi
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"sessionId\":\"fake-1\",\"configOptions\":$(options)}}"
      if [[ $commands_early != true ]]; then update "$commands"; fi
      ;;
    *'"method":"session/set_config_option"'*)
      config=""
      value=""
      if [[ $line =~ \"configId\":\"([^\"]+)\" ]]; then config="${BASH_REMATCH[1]}"; fi
      if [[ $line =~ \"value\":\"([^\"]+)\" ]]; then value="${BASH_REMATCH[1]}"; fi
      case "$config" in
        model)
          model="$value"
          effort=$(starting_effort_of "$model")
          ;;
        effort) effort="$value" ;;
        mode) mode="$value" ;;
      esac
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"configOptions\":$(options)}}"
      ;;
    *'"method":"session/load"'*)
      if [[ $load_fails == true ]]; then
        echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32002,\"message\":\"Resource not found\"}}"
      else
        update '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"replayed"}}'
        echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"configOptions\":$(options)}}"
        update "$commands"
      fi
      ;;
    *'"method":"session/prompt"'*)
      if [[ $line == *'"text":"add a model"'* ]]; then
        models="${models%]},{\"value\":\"haiku\",\"name\":\"Haiku\"}]"
        update "{\"sessionUpdate\":\"config_option_update\",\"configOptions\":$(options)}"
        echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"stopReason\":\"end_turn\"}}"
        continue
      fi
      if [[ $line == *'"text":"change commands"'* ]]; then
        update "$changed_commands"
        echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"stopReason\":\"end_turn\"}}"
        continue
      fi
      if [[ $line == *'"text":"edit files"'* ]]; then
        update '{"sessionUpdate":"tool_call","toolCallId":"t2","title":"Write notes.md","status":"pending","kind":"edit","locations":[{"path":"/tmp/notes.md"}],"content":[{"type":"diff","path":"/tmp/notes.md","oldText":null,"newText":"one\ntwo\nthree\n"}]}'
        update '{"sessionUpdate":"tool_call","toolCallId":"t3","title":"Edit README.md","status":"pending","kind":"edit","locations":[{"path":"/tmp/README.md"}],"content":[{"type":"diff","path":"/tmp/README.md","oldText":"a\nb\nc","newText":"a\nB\nC\nd"}]}'
        echo '{"jsonrpc":"2.0","id":"perm-2","method":"session/request_permission","params":{"sessionId":"fake-1","toolCall":{"toolCallId":"t2","title":"Write notes.md"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"reject","name":"Reject","kind":"reject_once"}]}}'
        IFS= read -r reply
        if [[ $reply == *'"optionId":"allow"'* ]]; then
          update '{"sessionUpdate":"tool_call_update","toolCallId":"t2","_meta":{"claudeCode":{"toolName":"Write"}},"content":[{"type":"diff","path":"/tmp/notes.md","oldText":"one\n2","newText":"one\ntwo\nthree","_meta":{"jetbrains":{"air":{"version":1,"diffStats":{"version":1,"added":2,"removed":1}}}}}]}'
          update '{"sessionUpdate":"tool_call_update","toolCallId":"t2","status":"completed"}'
          update '{"sessionUpdate":"tool_call_update","toolCallId":"t3","status":"completed"}'
        else
          update '{"sessionUpdate":"tool_call_update","toolCallId":"t2","status":"failed","content":[{"type":"content","content":{"type":"text","text":"The user rejected the edit"}}]}'
          update '{"sessionUpdate":"tool_call_update","toolCallId":"t3","status":"failed"}'
        fi
        echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"stopReason\":\"end_turn\"}}"
        continue
      fi
      if [[ $line == *'"text":"update edits"'* ]]; then
        update '{"sessionUpdate":"tool_call_update","toolCallId":"t2","status":"completed"}'
        update '{"sessionUpdate":"tool_call_update","toolCallId":"t3","content":[{"type":"diff","path":"/tmp/README.md","oldText":"a\nb\nc","newText":"a\nB\nc"}]}'
        echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"stopReason\":\"end_turn\"}}"
        continue
      fi
      if [[ $asks == true ]]; then
        echo '{"jsonrpc":"2.0","id":"ask-1","method":"elicitation/create","params":{"mode":"form","sessionId":"fake-1","message":"Which color?","requestedSchema":{"type":"object","properties":{"question_0":{"type":"string","title":"Color","oneOf":[{"const":"Blue","title":"Blue"},{"const":"Red","title":"Red","description":"Warm"}]},"question_0_custom":{"type":"string","title":"Other"}}}}}'
        IFS= read -r reply
        if [[ $reply =~ \"question_0\":\"([A-Za-z]+)\" ]]; then answer="answered ${BASH_REMATCH[1]}"; else answer="no answer"; fi
        update "{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"$answer\"}}"
        echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"stopReason\":\"end_turn\"}}"
        continue
      fi
      update '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hel"}}'
      update '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"lo"}}'
      update '{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Run printenv","status":"pending","kind":"execute"}'
      echo '{"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{"sessionId":"fake-1","toolCall":{"toolCallId":"t1","title":"Run printenv"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"reject","name":"Reject","kind":"reject_once"}]}}'
      IFS= read -r reply
      if [[ $reply == *'"optionId":"allow"'* ]]; then status=completed; else status=failed; fi
      update "{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t1\",\"status\":\"$status\"}"
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"stopReason\":\"end_turn\"}}"
      ;;
  esac
done
