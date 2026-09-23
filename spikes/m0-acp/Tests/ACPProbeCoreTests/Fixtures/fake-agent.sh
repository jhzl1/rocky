#!/bin/bash
# Minimal scripted ACP agent. Mode "ok": noise, 200 KB stderr, notification, permission request, response.
# Mode "exit": reads one request and exits 3. Mode "env": responds with $ROCKY_PROBE.
mode="${1:-ok}"
read -r _request
case "$mode" in
  exit)
    echo "missing credentials" >&2
    exit 3
    ;;
  env)
    echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"probe\":\"$ROCKY_PROBE\"}}"
    ;;
  ok)
    echo "fake-agent booting"
    head -c 200000 /dev/zero | tr '\0' 'x' >&2
    echo '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}'
    echo '{"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{"options":[{"optionId":"allow","kind":"allow_once"}]}}'
    read -r permission_reply
    echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"echo\":$permission_reply}}"
    ;;
esac
