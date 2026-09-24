#!/bin/bash
# Scripted ACP agent for ChatSessionModel tests.
# Answers initialize, session/new, session/load (replaying one old message first), session/prompt and
# session/set_config_option. session/new offers two models ("default", "opus"), two effort levels
# ("low", "high") and two modes ("default", "plan") as Claude's adapter does; set_config_option answers without the list.
# The prompt's tool t1 is an "execute" call.
# A prompt streams "Hel" + "lo", announces tool t1, asks permission, then reports t1 completed or failed.
# FAKE_ACP_LOAD_SESSION=false makes initialize report loadSession=false.
# FAKE_ACP_LOAD_FAILS=true makes session/load answer "Resource not found", like a session the agent does not have.
# FAKE_ACP_ASKS=true makes a prompt ask "Which color?" (Blue or Red) with elicitation/create, as Claude's
# AskUserQuestion does, and reply "answered <color>" or "no answer".
load_session="${FAKE_ACP_LOAD_SESSION:-true}"
load_fails="${FAKE_ACP_LOAD_FAILS:-false}"
asks="${FAKE_ACP_ASKS:-false}"
update() {
  echo "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"fake-1\",\"update\":$1}}"
}
while IFS= read -r line; do
  id=""
  if [[ $line =~ \"id\":([0-9]+) ]]; then id="${BASH_REMATCH[1]}"; fi
  case "$line" in
    *'"method":"initialize"'*)
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{\"loadSession\":$load_session}}}"
      ;;
    *'"method":"session/new"'*)
      update '{"sessionUpdate":"available_commands_update","availableCommands":[]}'
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"sessionId\":\"fake-1\",\"configOptions\":[{\"id\":\"model\",\"name\":\"Model\",\"category\":\"model\",\"type\":\"select\",\"currentValue\":\"default\",\"options\":[{\"value\":\"default\",\"name\":\"Default\"},{\"value\":\"opus\",\"name\":\"Opus\"}]},{\"id\":\"effort\",\"name\":\"Effort\",\"category\":\"thought_level\",\"type\":\"select\",\"currentValue\":\"high\",\"options\":[{\"value\":\"low\",\"name\":\"Low\"},{\"value\":\"high\",\"name\":\"High\"}]},{\"id\":\"mode\",\"name\":\"Mode\",\"category\":\"mode\",\"type\":\"select\",\"currentValue\":\"default\",\"options\":[{\"value\":\"default\",\"name\":\"Manual\"},{\"value\":\"plan\",\"name\":\"Plan\"}]}]}}"
      ;;
    *'"method":"session/set_config_option"'*)
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"configOptions\":[]}}"
      ;;
    *'"method":"session/load"'*)
      if [[ $load_fails == true ]]; then
        echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32002,\"message\":\"Resource not found\"}}"
      else
        update '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"replayed"}}'
        echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":null}"
      fi
      ;;
    *'"method":"session/prompt"'*)
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
