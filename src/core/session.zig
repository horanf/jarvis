const std = @import("std");

pub const Role = enum { user, assistant, system };

pub const ContentKind = enum { text, json_array };

pub const Message = struct {
    role: Role,
    content: []const u8,
    content_kind: ContentKind = .text,
};

pub const Session = struct {
    messages: std.ArrayListUnmanaged(Message) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Session {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Session) void {
        for (self.messages.items) |message| {
            self.allocator.free(message.content);
        }
        self.messages.deinit(self.allocator);
    }

    pub fn append(
        self: *Session,
        role: Role,
        content: []const u8,
        content_kind: ContentKind,
    ) !void {
        const owned_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned_content);
        try self.messages.append(self.allocator, .{
            .role         = role,
            .content      = owned_content,
            .content_kind = content_kind,
        });
    }
};

test "session append message" {
    var s = Session.init(std.testing.allocator);
    defer s.deinit();
    try s.append(.user, "hello", .text);
    try std.testing.expectEqual(@as(usize, 1), s.messages.items.len);
    try std.testing.expectEqual(Role.user, s.messages.items[0].role);
}

test "session append copies caller-owned text" {
    var s = Session.init(std.testing.allocator);
    defer s.deinit();

    var buf = [_]u8{ 'h', 'i' };
    try s.append(.user, buf[0..], .text);
    buf[0] = 'b';

    try std.testing.expectEqualStrings("hi", s.messages.items[0].content);
}

test "session append copies caller-owned utf8 text" {
    var s = Session.init(std.testing.allocator);
    defer s.deinit();

    var buf = [_]u8{ 0xe4, 0xbd, 0xa0, 0xe5, 0xa5, 0xbd };
    try s.append(.user, buf[0..], .text);
    buf[0] = 'x';

    try std.testing.expectEqualStrings("你好", s.messages.items[0].content);
}

test "message content_kind defaults to text" {
    const m = Message{ .role = .user, .content = "hi" };
    try std.testing.expectEqual(ContentKind.text, m.content_kind);
}

test "session append with json_array content_kind" {
    var s = Session.init(std.testing.allocator);
    defer s.deinit();
    try s.append(.user, "[{\"type\":\"tool_result\"}]", .json_array);
    try std.testing.expectEqual(@as(usize, 1), s.messages.items.len);
    try std.testing.expectEqual(ContentKind.json_array, s.messages.items[0].content_kind);
}
