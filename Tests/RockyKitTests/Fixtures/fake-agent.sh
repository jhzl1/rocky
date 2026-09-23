#!/bin/bash
# Scripted transport-level agent for ACPConnectionTests.
# ok: stdout noise, 200 KB stderr, notification with U+2028, permission request, echo reply.
# exit: reads one request and exits 3. env: responds with $ROCKY_PROBE. error: JSON-RPC error.
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
  error)
    echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Authentication required"}}'
    ;;
  ok)
    echo "fake-agent booting"
    head -c 200000 /dev/zero | tr '\0' 'x' >&2
    printf '{"jsonrpc":"2.0","method":"session/update","params":{"text":"a\xe2\x80\xa8b"}}\n'
    echo '{"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{"options":[{"optionId":"allow","kind":"allow_once"}]}}'
    read -r permission_reply
    echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"echo\":$permission_reply}}"
    ;;
esac
