const std = @import("std");
const log = std.log;
const os = std.os;

const server = @import("server.zig");

pub fn main() !void {
    try do(true, std.heap.page_allocator);
}

fn handler_sigchld(signum: c_int) callconv(.C) void {
    // nothing to do
    _ = signum;
}

pub fn do(fork: bool, allocator: std.mem.Allocator) !void {
    // ignore SIGCHLD
    var act = os.Sigaction{
        .handler = .{ .handler = handler_sigchld },
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
        defer con.deinit();
        if (fork) {
            const fork_pid = std.os.fork() catch {
                log.err("fork failed", .{});
                return;
            };
            if (fork_pid != 0) {
                continue;
            }
            log.debug("forked", .{});
        }

        defer {
            con.close();
            log.info("connection closed", .{});
        }
        con.handshake() catch |err| {
            switch (err) {
                error.EndOfStream => {
                    if (fork) {
                        return err;
                    } else {
                        continue;
                    }
                },
                else => return err,
            }
        };

        var recv_bytes: [4096]u8 = undefined;
        // receieve contents
        const recv_size = con.recv(&recv_bytes) catch |err| {
            switch (err) {
                error.EndOfStream => {
                    std.log.warn("peer disconnected", .{});
                    return;
                },
                else => return err,
            }
        };
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

test "e2e server" {
    try do(false, std.testing.allocator);
}
