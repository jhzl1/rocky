#!/bin/bash
# Scripted ACP agent for ChatSessionModel tests.
# Answers initialize, session/new, session/load (replaying one old message first), session/prompt and
# session/set_config_option. session/new offers two models ("default", "opus") as Claude's adapter does.
# A prompt streams "Hel" + "lo", announces tool t1, asks permission, then reports t1 completed or failed.
# FAKE_ACP_LOAD_SESSION=false makes initialize report loadSession=false.
# FAKE_ACP_LOAD_FAILS=true makes session/load answer "Resource not found", like a session the agent does not have.
load_session="${FAKE_ACP_LOAD_SESSION:-true}"
load_fails="${FAKE_ACP_LOAD_FAILS:-false}"
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
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"sessionId\":\"fake-1\",\"configOptions\":[{\"id\":\"model\",\"name\":\"Model\",\"category\":\"model\",\"type\":\"select\",\"currentValue\":\"default\",\"options\":[{\"value\":\"default\",\"name\":\"Default\"},{\"value\":\"opus\",\"name\":\"Opus\"}]}]}}"
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
      update '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hel"}}'
      update '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"lo"}}'
      update '{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Run printenv","status":"pending"}'
      echo '{"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{"sessionId":"fake-1","toolCall":{"toolCallId":"t1","title":"Run printenv"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"reject","name":"Reject","kind":"reject_once"}]}}'
      IFS= read -r reply
      if [[ $reply == *'"optionId":"allow"'* ]]; then status=completed; else status=failed; fi
      update "{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t1\",\"status\":\"$status\"}"
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"stopReason\":\"end_turn\"}}"
      ;;
  esac
done
