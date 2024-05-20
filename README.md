# tls13-zig

The first TLS1.3 implementation in Zig(0.12.0) only with std.


This repository is an experimental implementation and is not intended for production use.

# LICENSE


```
Copyright 2022, Naoki MATSUMOTO (Original Author)
Copyright 2022, Shiguredo Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

# Features
- Supported CipherSuite
  - TLS_AES_128_GCM_SHA256
  - TLS_AES_256_GCM_SHA384
  - TLS_CHACHA20_POLY1305_SHA256
- Supported KeyShare
  - x25519
  - secp256r1
- Supported SignatureAlgorithm
  - ecdsa_secp256r1_sha256
  - ecdsa_secp384r1_sha384
  - rsa_pss_rsae_sha256

# How to use
This client retrieves contents from `www.google.com` with TLS1.3.
If you want to try this, simple executes `zig run src/main.zig`.
## Client
```zig
const std = @import("std");
const log = std.log;
const allocator = std.heap.page_allocator;

const client = @import("client.zig");

pub fn main() !void {
    log.info("started.", .{});
    var tls_client = try client.TLSClientTCP.init(allocator);
    defer tls_client.deinit();
    tls_client.print_keys = true;

    try tls_client.connect("www.google.com", 443);

    const http_req = "GET / HTTP/1.1\r\nHost: www.google.com\r\nUser-Agent: tls13-zig\r\nAccept: */*\r\n\r\n";
    _ = try tls_client.send(http_req);

    var recv_bytes: [4096]u8 = undefined;
    const recv_size = try tls_client.recv(&recv_bytes);
    log.info("RECV=\n {s}", .{recv_bytes[0..recv_size]});

    try tls_client.close();
    log.info("finished.", .{});

    return;
}
```

## Server
This server is tested with latest Chrome and Firefox in Windows.
If you want to try this, simple executes `zig run src/main_test_server.zig`.
```zig
const std = @import("std");
const log = std.log;
const os = std.os;
const allocator = std.heap.page_allocator;

const server = @import("server.zig");

pub fn main() !void {
    // ignore SIGCHLD
    var act = os.Sigaction{
        .handler = .{ .handler = os.SIG.IGN },
        .mask = os.empty_sigset,
        .flags = (os.SA.SIGINFO | os.SA.RESTART | os.SA.RESETHAND),
    };
    try os.sigaction(os.SIG.CHLD, &act, null);

    log.info("started.", .{});

    // key and certificates need to be der-formatted.
    // if you want to use RSAPrivateKey, please change '.ec' to '.rsa'.
    // The procedure to generate test certificate is described in test/gen_cert.sh
    var tls_server = try server.TLSServerTCP.init("./test/key.pem", "./test/cert.pem", null, "localhost", allocator);
    defer tls_server.deinit();

    // Enable KEYLOG output.
    tls_server.print_keys = true;
    tls_server.record_size_limit = 2 << 12;
    tls_server.accept_resume = true;
    tls_server.accept_early_data = true;

    try tls_server.listen(8443);
    while (true) {
        var con = try tls_server.accept();
        const fork_pid = std.os.fork() catch {
            log.err("fork failed", .{});
            return;
        };
        if (fork_pid != 0) {
            continue;
        }
        log.debug("forked", .{});

        defer {
            con.close();
            log.info("connection closed", .{});
        }
        try con.handshake();

        var recv_bytes: [4096]u8 = undefined;
        // receieve contents
        const recv_size = try con.recv(&recv_bytes);
        log.info("RECV=\n{s}", .{recv_bytes[0..recv_size]});
        const get_req = "GET / ";
        if (std.mem.eql(u8, recv_bytes[0..get_req.len], get_req)) {
            log.info("HTTP GET received", .{});
            const http_res = "HTTP/1.0 200 ok\r\nContent-type: text/html\r\n\r\n<HTML><BODY>tls13-zig</BODY></HTML>";
            // send contents
            try con.tlsWriter().writeAll(http_res);
        }

        return;
    }

    return;
}

```

# TODO
## Priority: High
- [x] Support HelloRetryRequest.
- [ ] Error handle
  - [ ] Send 'alert' when an error occur.
- [x] Support KeyUpdate.
- [x] Support NewSessionTicket.
- [x] Support 0-RTT handshake(resumption). (disabled in server by default)
- [ ] Add more E2E tests.
    - [x] Static tests for server.
    - [ ] Server tests with Web browser.
- [ ] Support X.509(src/x509.zig) fully.
  - [ ] Add more tests.
  - [ ] Implement X.509 Certificate encoder.
  - [ ] Verify implementation with NIST's test vectors.
- [x] Verify X.509 Certificate itself. 
- [ ] Check the implementation follows RFC8446.

## Priority: Low
- [ ] Support Extensions.
   - [x] record_size_limit
   - [ ] application_layer_protocol_negotiation
   - [x] pks_key_exchange_modes
   - [ ] post_handshake_auth
   - [ ] ec_points_format
   - [ ] next_protocol_negotiation
   - [ ] encrypt_then_mac
   - [ ] extended_master_secret
   - [ ] status_request
   - [ ] signed_certificate_timestamp
   - [ ] session_ticket
   - [ ] compress_certificate
   - [ ] application_settings
- [ ] Improve slow RSA(src/rsa.zig).
- [ ] Improve comments.

# Example
## TLS Termination Proxy
This is simple TLS termination proxy using tls13-zig.
This proxy terminates TLS1.3 and redirect contents to local server(localhost:8080).
If you want to try this, simple executes `cd examples/proxy && docker compose up`.

This sample works on [tls13.pibvt.net](https://tls13.pibvt.net)
