const std = @import("std");
const log = std.log;
const io = std.io;
const assert = std.debug.assert;
const hmac = std.crypto.auth.hmac;
const ArrayList = std.ArrayList;
const BoundedArray = std.BoundedArray;

const crypto = @import("crypto.zig");
const Extension = @import("extension.zig").Extension;
const ExtensionType = @import("extension.zig").ExtensionType;
const ServerHello = @import("server_hello.zig").ServerHello;
const ClientHello = @import("client_hello.zig").ClientHello;
const Handshake = @import("handshake.zig").Handshake;
const HandshakeType = @import("handshake.zig").HandshakeType;

pub const NamedGroup = enum(u16) {
    x25519 = 0x001D,
    x448 = 0x001e,
    secp256r1 = 0x0017,
    secp384r1 = 0x0018,
    secp521r1 = 0x0019,

    ffdhe2048 = 0x0100,
    ffdhe3072 = 0x0101,
    ffdhe4096 = 0x0102,
    ffdhe6144 = 0x0103,
    ffdhe8192 = 0x0104,
};

pub const CipherSuite = enum(u16) {
    TLS_AES_128_GCM_SHA256 = 0x1301,
    TLS_AES_256_GCM_SHA384 = 0x1302,
    TLS_CHACHA20_POLY1305_SHA256 = 0x1303,
    TLS_AES_128_CCM_SHA256 = 0x1304,
    TLS_AES_128_CCM_8_SHA256 = 0x1305,

    TLS_EMPTY_RENEGOTIATION_INFO_SCSV = 0x0,
};

pub const SessionID = struct {
    const MAX_SESSIONID_LENGTH = 32;

    session_id: BoundedArray(u8, MAX_SESSIONID_LENGTH),

    const Self = @This();

    pub fn init(len: usize) !Self {
        return Self{
            .session_id = try BoundedArray(u8, 32).init(len),
        };
    }

    pub fn decode(reader: anytype) !Self {
        var res = try Self.init(try reader.readIntBig(u8));
        _ = try reader.readAll(res.session_id.slice());

        return res;
    }

    pub fn encode(self: Self, writer: anytype) !usize {
        var len: usize = 0;

        try writer.writeIntBig(u8, @intCast(u8, self.session_id.len));
        len += @sizeOf(u8);

        try writer.writeAll(self.session_id.slice());
        len += self.session_id.len;

        return len;
    }

    pub fn length(self: Self) usize {
        var len: usize = 0;
        len += @sizeOf(u8);
        len += self.session_id.len;

        return len;
    }

    pub fn print(self: Self) void {
        log.debug("SessionID", .{});
        log.debug("- id = {}", .{std.fmt.fmtSliceHexLower(&self.session_id.slice())});
    }
};

pub fn decodeCipherSuites(reader: anytype, suites: *ArrayList(CipherSuite)) !void {
    var len: usize = try reader.readIntBig(u16);
    assert(len % 2 == 0);

    var i: usize = 0;
    while (i < len) : (i += @sizeOf(u16)) {
        try suites.append(@intToEnum(CipherSuite, try reader.readIntBig(u16)));
    }

    assert(i == len);
}

pub fn encodeCipherSuites(writer: anytype, suites: ArrayList(CipherSuite)) !usize {
    var len: usize = 0;
    try writer.writeIntBig(u16, @intCast(u16, suites.items.len * @sizeOf(CipherSuite)));
    len += @sizeOf(u16);

    for (suites.items) |suite| {
        try writer.writeIntBig(u16, @enumToInt(suite));
        len += @sizeOf(CipherSuite);
    }

    return len;
}

pub fn decodeExtensions(reader: anytype, allocator: std.mem.Allocator, extensions: *ArrayList(Extension), ht: HandshakeType, is_hello_retry: bool) !void {
    const ext_len = try reader.readIntBig(u16);
    var i: usize = 0;
    while (i < ext_len) {
        var ext = try Extension.decode(reader, allocator, ht, is_hello_retry);
        try extensions.append(ext);
        i += ext.length();
    }
    assert(i == ext_len);
}

pub fn encodeExtensions(writer: anytype, extensions: ArrayList(Extension)) !usize {
    var ext_len: usize = 0;
    for (extensions.items) |ext| {
        ext_len += ext.length();
    }

    var len: usize = 0;
    try writer.writeIntBig(u16, @intCast(u16, ext_len));
    len += @sizeOf(u16);

    for (extensions.items) |ext| {
        len += try ext.encode(writer);
    }

    return len;
}

pub const ExtensionError = error{
    ExtensionNotFound,
};

pub const DecodeError = error{
    HashNotSpecified,
    NotAllDecoded,
};

pub fn getExtension(extensions: ArrayList(Extension), ext_type: ExtensionType) !Extension {
    for (extensions.items) |e| {
        if (e == ext_type) {
            return e;
        }
    }

    return ExtensionError.ExtensionNotFound;
}

pub const Finished = struct {
    const my_crypto = @import("crypto.zig");
    const MAX_DIGEST_LENGTH = my_crypto.Hkdf.MAX_DIGEST_LENGTH;

    hkdf: my_crypto.Hkdf,
    verify_data: BoundedArray(u8, MAX_DIGEST_LENGTH) = undefined,

    const Self = @This();

    pub fn init(hkdf: my_crypto.Hkdf) !Self {
        return Self{
            .hkdf = hkdf,
            .verify_data = try BoundedArray(u8, MAX_DIGEST_LENGTH).init(hkdf.digest_length),
        };
    }

    pub fn deinit(self: Self) void {
        _ = self;
    }

    pub fn decode(reader: anytype, hkdf: my_crypto.Hkdf) !Self {
        var res = try Self.init(hkdf);
        _ = try reader.readAll(res.verify_data.slice());

        return res;
    }

    pub fn encode(self: Self, writer: anytype) !usize {
        try writer.writeAll(self.verify_data.slice());
        return self.verify_data.len;
    }

    pub fn length(self: Self) usize {
        return self.verify_data.len;
    }

    pub fn fromMessageBytes(m: []const u8, secret: []const u8, hkdf: my_crypto.Hkdf) !Self {
        var res = try Self.init(hkdf);
        var hash: [MAX_DIGEST_LENGTH]u8 = undefined;
        var digest: [MAX_DIGEST_LENGTH]u8 = undefined;
        hkdf.hash(&hash, m);
        hkdf.create(&digest, &hash, secret);
        std.mem.copy(u8, res.verify_data.slice(), digest[0..hkdf.digest_length]);

        return res;
    }

    pub fn verify(self: Self, m: []const u8, secret: []const u8) bool {
        var hash: [MAX_DIGEST_LENGTH]u8 = undefined;
        var digest: [MAX_DIGEST_LENGTH]u8 = undefined;
        self.hkdf.hash(&hash, m);
        self.hkdf.create(&digest, &hash, secret);

        return std.mem.eql(u8, digest[0..self.hkdf.digest_length], self.verify_data.slice());
    }
};

pub const NewSessionTicket = struct {
    const MAX_TICKET_NONCE_LENGTH = 256;

    ticket_lifetime: u32 = undefined,
    ticket_age_add: u32 = undefined,
    ticket_nonce: BoundedArray(u8, MAX_TICKET_NONCE_LENGTH) = undefined,
    ticket: []u8 = undefined,
    extensions: ArrayList(Extension) = undefined,

    allocator: std.mem.Allocator = undefined,

    const Self = @This();
    fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .extensions = ArrayList(Extension).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn decode(reader: anytype, allocator: std.mem.Allocator) !Self {
        var res = try Self.init(allocator);

        res.ticket_lifetime = try reader.readIntBig(u32);
        res.ticket_age_add = try reader.readIntBig(u32);
        const nonce_len = try reader.readIntBig(u8);
        res.ticket_nonce = try BoundedArray(u8, MAX_TICKET_NONCE_LENGTH).init(nonce_len);
        try reader.readNoEof(res.ticket_nonce.slice());

        const ticket_len = try reader.readIntBig(u16);
        res.ticket = try allocator.alloc(u8, ticket_len);
        try reader.readNoEof(res.ticket);

        try decodeExtensions(reader, allocator, &res.extensions, .new_session_ticket, false);

        return res;
    }

    pub fn deinit(self: Self) void {
        for (self.extensions.items) |e| {
            e.deinit();
        }
        self.extensions.deinit();
    }
};

const expect = std.testing.expect;
const expectError = std.testing.expectError;

test "Finished decode" {
    const recv_data = [_]u8{ 0x14, 0x00, 0x00, 0x20, 0x9b, 0x9b, 0x14, 0x1d, 0x90, 0x63, 0x37, 0xfb, 0xd2, 0xcb, 0xdc, 0xe7, 0x1d, 0xf4, 0xde, 0xda, 0x4a, 0xb4, 0x2c, 0x30, 0x95, 0x72, 0xcb, 0x7f, 0xff, 0xee, 0x54, 0x54, 0xb7, 0x8f, 0x07, 0x18 };
    var readStream = io.fixedBufferStream(&recv_data);

    const res = try Handshake.decode(readStream.reader(), std.testing.allocator, crypto.Hkdf.Sha256.hkdf);
    defer res.deinit();

    // check all data was read.
    try expectError(error.EndOfStream, readStream.reader().readByte());

    try expect(res == .finished);
}
