#!/usr/bin/env python3
"""Static checks for the reconstruction-only XPC ping; no device RPC executed."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1] / "sources"
header = (ROOT / "common" / "CRPaths.h").read_text(encoding="utf-8")
client = (ROOT / "libcrane" / "CRManager.m").read_text(encoding="utf-8")
server = (ROOT / "cranehelperd" / "CRHelperd.m").read_text(encoding="utf-8")

assert re.search(r'#define\s+CR_HELPERD_PING_PROTOCOL_V1\s+"crane-reconstruction-ping-v1"', header)
assert 'xpc_dictionary_set_string(request, "protocol", CR_HELPERD_PING_PROTOCOL_V1)' in client
assert 'strcmp(protocol, CR_HELPERD_PING_PROTOCOL_V1) == 0' in client
assert 'strcmp(protocol, CR_HELPERD_PING_PROTOCOL_V1) != 0' in server
assert 'xpc_dictionary_set_string(reply, "protocol", CR_HELPERD_PING_PROTOCOL_V1)' in server
assert 'strcmp(operation, "ping") != 0' in server
assert 'xpc_get_type(message) != XPC_TYPE_DICTIONARY' in server
assert 'xpc_get_type(message) == XPC_TYPE_ERROR' in server
for source in (client, server):
    stripped = re.sub(r'/\*.*?\*/|//[^\n]*', '', source, flags=re.S)
    assert not re.search(r'\bxpc_connection_get_(?:pid|euid)\s*\(', stripped)
print("XPC ping static contract: PASS (runtime unverified)")
