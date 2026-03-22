const std = @import("std");

pub const Role = enum { user, assistant, system };

pub const Message = struct {
    role: Role,
    content: []const u8,
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

    pub fn append(self: *Session, role: Role, content: []const u8) !void {
        try self.messages.append(self.allocator, .{ .role = role, .content = content });
    }
};

test "session append message" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    try session.append(.user, "hello");
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expectEqual(Role.user, session.messages.items[0].role);
}
