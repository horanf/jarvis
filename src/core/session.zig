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
        self.messages.deinit(self.allocator);
    }

    pub fn append(
        self: *Session,
        role: Role,
        content: []const u8,
        content_kind: ContentKind,
    ) !void {
        try self.messages.append(self.allocator, .{
            .role         = role,
            .content      = content,
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
