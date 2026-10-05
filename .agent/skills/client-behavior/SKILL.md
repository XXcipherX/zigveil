---
name: zigveil-client-behavior
description: Evidence policy and compatibility expectations for ClientHello, encrypted tunnels and TCP half-close.
---

# Client compatibility

## Evidence policy

Separate standards-backed behavior, version-pinned implementation observations,
captured traffic and synthetic tests. A valid test fixture proves only its own
case. Do not assert that every client or post-quantum TLS stack
behaves the same without a versioned source or capture.

Record client name/version, offered outer SNI, total initial wire size, record
count, TCP delivery shape, hello/connect timing and FIN/reset order. Do not commit
user captures or payloads without explicit scope and appropriate sanitization.

## Admission contract

TCP fragmentation is supported. ClientHello can span at most 64 TLS handshake
records and 64 KiB of inspected wire input. Each record payload is 1..16384 bytes.
Fields and hostnames may cross records. Trailing staged bytes survive routing.
Only host_name is used; names are strict canonical ASCII DNS labels, not Unicode,
wildcards, IP literals or names with trailing dots. Missing/unknown SNI follows
explicit fallback. Classification failure (including malformed framing/names and
inspection limits) also selects the default backend when configured. Partial clean
EOF forwards the prefix before FIN; partial hello expiry selects fallback without
closing the client read half. Empty EOF closes normally, empty expiry times out.
Fatal transport/capacity errors and failure of a selected backend close without rerouting.

The selected backend sees the exact original prefix, optionally preceded by a
fallback-only PROXY v2 preamble. Ordinary routes always remain raw; fallback's
listener must consume the configured framing before TLS/data. TLS version/cipher/key-share
semantics are opaque. Later handshake flights, application records, early data
and protocol tunneling are not parsed. Encrypted inner SNI (ECH) is unavailable;
only the visible outer name can select a route.

## Relay expectations

Long silent intervals are governed by the configured idle timeout; set it to zero
when the application needs unbounded established idleness. Hello, connect and
prefix deadlines stay finite. EOF in one direction permits the other direction to
continue; this is required for request-then-FIN protocols and delayed replies.
Application resets may destroy queued data and are counted as I/O failures rather
than graceful FIN. TLS close_notify is application data and is forwarded unchanged.

## Diagnostics

Distinguish parser rejection, no route, connection failure, idle expiry and peer
reset with aggregate counters and a controlled reproduction. Validate the actual
backend service with its own client. Synthetic echo establishes byte preservation,
not real protocol interoperability. Current tests additionally complete real TLS
through an IPv6 backend and through a PROXY v2-consuming default backend. These
tests do not imply compatibility with every client. Classification counters can
describe input that was successfully forwarded; use fallback_routed alongside them.
