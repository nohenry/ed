const std = @import("std");
const Allocator = std.mem.Allocator;

const ed = @import("ed.zig");

const builtin = @import("builtin");
pub const Self = @This();

fn addOrOom(a: usize, b: usize) error{OutOfMemory}!usize {
    const result, const overflow = @addWithOverflow(a, b);
    if (overflow != 0) return error.OutOfMemory;
    return result;
}

pub const GrowableString = struct {
    /// Contents of the list. This field is intended to be accessed
    /// directly.
    ///
    /// Pointers to elements in this slice are invalidated by various
    /// functions of this ArrayList in accordance with the respective
    /// documentation. In all cases, "invalidated" means that the memory
    /// has been passed to an allocator's resize or free function.
    items: Slice,
    /// How many T values this list can hold without allocating
    /// additional memory.
    capacity: usize,
    is_readonly: bool,

    /// An ArrayList containing no elements.
    pub const empty: GrowableString = .{
        .items = &.{},
        .capacity = 0,
        .is_readonly = false,
    };

    pub const Slice = []u8;

    pub const SentinelSlice = [:0]u8;
    pub const alignment = std.mem.Alignment.@"1";

    /// Initialize with capacity to hold exactly `num` elements.
    /// Deinitialize with `deinit` or `toOwnedSlice`.
    pub fn initCapacity(gpa: Allocator, num: usize) Allocator.Error!GrowableString {
        var self: GrowableString = .empty;
        try self.ensureTotalCapacityPrecise(gpa, num);
        return self;
    }

    /// Initialize with externally-managed memory. The buffer determines the
    /// capacity, and the length is set to zero.
    ///
    /// When initialized this way, all functions that accept an Allocator
    /// argument cause illegal behavior.
    pub fn initReadonly(buffer: []const u8) GrowableString {
        return .{
            .items = @constCast(buffer),
            .capacity = buffer.len,
            .is_readonly = true,
        };
    }

    /// Release all allocated memory.
    pub fn deinit(self: *GrowableString, gpa: Allocator) void {
        gpa.free(self.allocatedSlice());
        self.* = undefined;
    }

    /// ArrayList takes ownership of the passed in slice.
    /// Deinitialize with `deinit` or use `toOwnedSlice`.
    pub fn fromOwnedSlice(slice: Slice) GrowableString {
        return GrowableString{
            .items = slice,
            .capacity = slice.len,
        };
    }

    /// ArrayList takes ownership of the passed in slice.
    /// Deinitialize with `deinit` or use `toOwnedSlice`.
    pub fn fromOwnedSliceSentinel(comptime sentinel: u8, slice: [:sentinel]u8) GrowableString {
        return GrowableString{
            .items = slice,
            .capacity = slice.len + 1,
        };
    }

    /// The caller owns the returned memory. Empties this ArrayList.
    /// Its capacity is cleared, making deinit() safe but unnecessary to call.
    pub fn toOwnedSlice(self: *GrowableString, gpa: Allocator) Allocator.Error!Slice {
        const old_memory = self.allocatedSlice();
        if (gpa.remap(old_memory, self.items.len)) |new_items| {
            self.* = .empty;
            return new_items;
        }

        const new_memory = try gpa.alignedAlloc(u8, alignment, self.items.len);
        @memcpy(new_memory, self.items);
        self.clearAndFree(gpa);
        return new_memory;
    }

    /// The caller owns the returned memory. ArrayList becomes empty.
    pub fn toOwnedSliceSentinel(self: *GrowableString, gpa: Allocator, comptime sentinel: u8) Allocator.Error!SentinelSlice(sentinel) {
        // This addition can never overflow because `self.items` can never occupy the whole address space.
        try self.ensureTotalCapacityPrecise(gpa, self.items.len + 1);
        self.appendAssumeCapacity(sentinel);
        errdefer self.items.len -= 1;
        const result = try self.toOwnedSlice(gpa);
        return result[0 .. result.len - 1 :sentinel];
    }

    /// The caller owns the returned memory. Empties this ArrayList.
    /// Its capacity is cleared, making deinit() safe but unnecessary to call.
    ///
    /// Asserts what the capacity is equal to the length.
    pub fn toOwnedSliceAssert(self: *GrowableString) Slice {
        std.debug.assert(self.items.len == self.capacity);
        const items = self.items;
        self.* = .empty;
        return items;
    }

    /// The caller owns the returned memory. ArrayList becomes empty.
    /// Asserts what the capacity is equal to the length + 1.
    pub fn toOwnedSliceSentinelAssert(self: *GrowableString, comptime sentinel: u8) SentinelSlice(sentinel) {
        std.debug.assert(self.items.len + 1 == self.capacity);
        self.appendAssumeCapacity(sentinel);
        const result = self.toOwnedSliceAssert();
        return result[0 .. result.len - 1 :sentinel];
    }

    /// Creates a copy of this ArrayList.
    pub fn clone(self: GrowableString, gpa: Allocator) Allocator.Error!GrowableString {
        var cloned = try GrowableString.initCapacity(gpa, self.capacity);
        cloned.appendSliceAssumeCapacity(self.items);
        return cloned;
    }

    /// Insert `item` at index `i`. Moves `list[i .. list.len]` to higher indices to make room.
    /// If `i` is equal to the length of the list this operation is equivalent to append.
    /// This operation is O(N).
    /// Invalidates element pointers if additional memory is needed.
    /// Asserts that the index is in bounds or equal to the length.
    pub fn insert(self: *GrowableString, gpa: Allocator, i: usize, item: u8) Allocator.Error!void {
        const dst = try self.addManyAt(gpa, i, 1);
        dst[0] = item;
    }

    /// Insert `item` at index `i`. Moves `list[i .. list.len]` to higher indices to make room.
    ///
    /// If `i` is equal to the length of the list this operation is equivalent to append.
    ///
    /// This operation is O(N).
    ///
    /// Asserts that the list has capacity for one additional item.
    ///
    /// Asserts that the index is in bounds or equal to the length.
    pub fn insertAssumeCapacity(self: *GrowableString, i: usize, item: u8) void {
        std.debug.assert(self.items.len < self.capacity);
        self.items.len += 1;

        @memmove(self.items[i + 1 .. self.items.len], self.items[i .. self.items.len - 1]);
        self.items[i] = item;
    }

    /// Add `count` new elements at position `index`, which have
    /// `undefined` values. Returns a slice pointing to the newly allocated
    /// elements, which becomes invalid after various `ArrayList`
    /// operations.
    /// Invalidates pre-existing pointers to elements at and after `index`.
    /// Invalidates all pre-existing element pointers if capacity must be
    /// increased to accommodate the new elements.
    /// Asserts that the index is in bounds or equal to the length.
    pub fn addManyAt(self: *GrowableString, index: usize, count: usize) Allocator.Error![]u8 {
        const new_len = try addOrOom(self.items.len, count);

        if (self.capacity >= new_len)
            return addManyAtAssumeCapacity(self, index, count);

        // Here we avoid copying allocated but unused bytes by
        // attempting a resize in place, and falling back to allocating
        // a new buffer and doing our own copy. With a realloc() call,
        // the allocator implementation would pointlessly copy our
        // extra capacity.
        const new_capacity = GrowableString.growCapacity(new_len);
        const old_memory = self.allocatedSlice();
        if (self.allocator.remap(old_memory, new_capacity)) |new_memory| {
            self.items.ptr = new_memory.ptr;
            self.capacity = new_memory.len;
            return addManyAtAssumeCapacity(self, index, count);
        }

        // Make a new allocation, avoiding `ensureTotalCapacity` in order
        // to avoid extra memory copies.
        const new_memory = try self.allocator.alignedAlloc(u8, alignment, new_capacity);
        const to_move = self.items[index..];
        @memcpy(new_memory[0..index], self.items[0..index]);
        @memcpy(new_memory[index + count ..][0..to_move.len], to_move);
        self.allocator.free(old_memory);
        self.items = new_memory[0..new_len];
        self.capacity = new_memory.len;
        // The inserted elements at `new_memory[index..][0..count]` have
        // already been set to `undefined` by memory allocation.
        return new_memory[index..][0..count];
    }

    /// Add `count` new elements at position `index`, which have
    /// `undefined` values. Returns a slice pointing to the newly allocated
    /// elements, which becomes invalid after various `ArrayList`
    /// operations.
    /// Invalidates pre-existing pointers to elements at and after `index`, but
    /// does not invalidate any before that.
    /// Asserts that the list has capacity for the additional items.
    /// Asserts that the index is in bounds or equal to the length.
    pub fn addManyAtAssumeCapacity(self: *GrowableString, index: usize, count: usize) []u8 {
        const new_len = self.items.len + count;
        std.debug.assert(self.capacity >= new_len);
        const to_move = self.items[index..];
        self.items.len = new_len;
        @memmove(self.items[index + count ..][0..to_move.len], to_move);
        const result = self.items[index..][0..count];
        @memset(result, undefined);
        return result;
    }

    /// Insert slice `items` at index `i` by moving `list[i .. list.len]` to make room.
    /// This operation is O(N).
    /// Invalidates pre-existing pointers to elements at and after `index`.
    /// Invalidates all pre-existing element pointers if capacity must be
    /// increased to accommodate the new elements.
    /// Asserts that the index is in bounds or equal to the length.
    pub fn insertSlice(
        self: *GrowableString,
        gpa: Allocator,
        index: usize,
        items: []const u8,
    ) Allocator.Error!void {
        const dst = try self.addManyAt(
            gpa,
            index,
            items.len,
        );
        @memcpy(dst, items);
    }

    /// Insert slice `items` at index `i` by moving `list[i .. list.len]` to make room.
    /// This operation is O(N).
    /// Invalidates pre-existing pointers to elements at and after `index`.
    /// Asserts that the list has capacity for the additional items.
    /// Asserts that the index is in bounds or equal to the length.
    pub fn insertSliceAssumeCapacity(
        self: *GrowableString,
        index: usize,
        items: []const u8,
    ) void {
        const dst = self.addManyAtAssumeCapacity(index, items.len);
        @memcpy(dst, items);
    }

    /// Grows or shrinks the list as necessary.
    /// Invalidates element pointers if additional capacity is allocated.
    /// Asserts that the range is in bounds.
    pub fn replaceRange(
        self: *GrowableString,
        gpa: Allocator,
        start: usize,
        len: usize,
        new_items: []const u8,
    ) Allocator.Error!void {
        try self.ensureTotalCapacity(gpa, try addOrOom(self.items.len - len, new_items.len));
        self.replaceRangeAssumeCapacity(start, len, new_items);
    }

    /// Grows or shrinks the list as necessary.
    ///
    /// Never invalidates element pointers.
    ///
    /// Asserts the capacity is enough for additional items.
    pub fn replaceRangeAssumeCapacity(
        self: *GrowableString,
        start: usize,
        len: usize,
        new_items: []const u8,
    ) void {
        std.debug.assert(self.capacity - self.items.len >= new_items.len -| len);

        const tail = self.items[start + len ..];
        const vacated = self.items[self.items.len - (len -| new_items.len) ..];
        self.items.len = self.items.len - len + new_items.len;
        @memmove(self.items[start + new_items.len ..], tail);
        @memcpy(self.items[start..][0..new_items.len], new_items);
        @memset(vacated, undefined);
    }

    /// Extend the list by 1 element. Allocates more memory as necessary.
    /// Invalidates element pointers if additional memory is needed.
    pub fn append(self: *GrowableString, gpa: Allocator, item: u8) Allocator.Error!void {
        const new_item_ptr = try self.addOne(gpa);
        new_item_ptr.* = item;
    }

    /// Extend the list by 1 element.
    ///
    /// Never invalidates element pointers.
    ///
    /// Asserts that the list can hold one additional item.
    pub fn appendAssumeCapacity(self: *GrowableString, item: u8) void {
        self.addOneAssumeCapacity().* = item;
    }

    /// Remove the element at index `i` from the list and return its value.
    /// Invalidates pointers to the last element.
    /// This operation is O(N).
    /// Asserts that the index is in bounds.
    pub fn orderedRemove(self: *GrowableString, i: usize) u8 {
        const old_item = self.items[i];
        self.replaceRangeAssumeCapacity(i, 1, &.{});
        return old_item;
    }

    /// Remove the elements indexed by `sorted_indexes`. The indexes to be
    /// removed correspond to the array list before deletion.
    ///
    /// Asserts:
    /// * Each index to be removed is in bounds.
    /// * The indexes to be removed are sorted ascending.
    ///
    /// Duplicates in `sorted_indexes` are allowed.
    ///
    /// This operation is O(N).
    ///
    /// Invalidates element pointers beyond the first deleted index.
    pub fn orderedRemoveMany(self: *GrowableString, sorted_indexes: []const usize) void {
        if (sorted_indexes.len == 0) return;
        var shift: usize = 1;
        for (sorted_indexes[0 .. sorted_indexes.len - 1], sorted_indexes[1..]) |removed, end| {
            if (removed == end) continue; // allows duplicates in `sorted_indexes`
            const start = removed + 1;
            const len = end - start; // safety checks `sorted_indexes` are sorted
            @memmove(self.items[start - shift ..][0..len], self.items[start..][0..len]); // safety checks initial `sorted_indexes` are in range
            shift += 1;
        }
        const start = sorted_indexes[sorted_indexes.len - 1] + 1;
        const end = self.items.len;
        const len = end - start; // safety checks final `sorted_indexes` are in range
        @memmove(self.items[start - shift ..][0..len], self.items[start..][0..len]);
        self.items.len = end - shift;
    }

    /// Removes the element at the specified index and returns it.
    /// The empty slot is filled from the end of the list.
    /// Invalidates pointers to last element.
    /// This operation is O(1).
    /// Asserts that the index is in bounds.
    pub fn swapRemove(self: *GrowableString, i: usize) u8 {
        const val = self.items[i];
        self.items[i] = self.items[self.items.len - 1];
        self.items[self.items.len - 1] = undefined;
        self.items.len -= 1;
        return val;
    }

    /// Append the slice of items to the list. Allocates more
    /// memory as necessary.
    /// Invalidates element pointers if additional memory is needed.
    pub fn appendSlice(self: *GrowableString, gpa: Allocator, items: []const u8) Allocator.Error!void {
        try self.ensureUnusedCapacity(gpa, items.len);
        self.appendSliceAssumeCapacity(items);
    }

    /// Append the slice of items to the list.
    ///
    /// Asserts that the list can hold the additional items.
    pub fn appendSliceAssumeCapacity(self: *GrowableString, items: []const u8) void {
        const old_len = self.items.len;
        const new_len = old_len + items.len;
        std.debug.assert(new_len <= self.capacity);
        self.items.len = new_len;
        @memcpy(self.items[old_len..][0..items.len], items);
    }

    pub fn print(self: *GrowableString, gpa: Allocator, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        try self.ensureUnusedCapacity(gpa, fmt.len);
        var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, self);
        defer self.* = aw.toArrayList();
        return aw.writer.print(fmt, args) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
    }

    pub fn printAssumeCapacity(self: *GrowableString, comptime fmt: []const u8, args: anytype) void {
        var w: std.Io.Writer = .fixed(self.unusedCapacitySlice());
        w.print(fmt, args) catch unreachable;
        self.items.len += w.end;
    }

    /// Append a value to the list `n` times.
    /// Allocates more memory as necessary.
    /// Invalidates element pointers if additional memory is needed.
    /// The function is inline so that a comptime-known `value` parameter will
    /// have a more optimal memset codegen in case it has a repeated byte pattern.
    pub inline fn appendNTimes(self: *GrowableString, gpa: Allocator, value: u8, n: usize) Allocator.Error!void {
        const old_len = self.items.len;
        try self.resize(gpa, try addOrOom(old_len, n));
        @memset(self.items[old_len..self.items.len], value);
    }

    /// Append a value to the list `n` times.
    ///
    /// Never invalidates element pointers.
    ///
    /// The function is inline so that a comptime-known `value` parameter will
    /// have better memset codegen in case it has a repeated byte pattern.
    ///
    /// Asserts that the list can hold the additional items.
    pub inline fn appendNTimesAssumeCapacity(self: *GrowableString, value: u8, n: usize) void {
        const new_len = self.items.len + n;
        std.debug.assert(new_len <= self.capacity);
        @memset(self.items.ptr[self.items.len..new_len], value);
        self.items.len = new_len;
    }

    /// Adjust the list length to `new_len`.
    /// Additional elements contain the value `undefined`.
    /// Invalidates element pointers if additional memory is needed.
    pub fn resize(self: *GrowableString, gpa: Allocator, new_len: usize) Allocator.Error!void {
        try self.ensureTotalCapacity(gpa, new_len);
        self.items.len = new_len;
    }

    /// Reduce allocated capacity to `new_len`.
    /// May invalidate element pointers.
    /// Asserts that the new length is less than or equal to the previous length.
    pub fn shrinkAndFree(self: *GrowableString, gpa: Allocator, new_len: usize) void {
        self.shrinkAndFreePrecise(gpa, new_len) catch |e| switch (e) {
            error.OutOfMemory => {
                // No problem, capacity is still correct then.
                self.items.len = new_len;
                return;
            },
        };
    }

    /// Reduce allocated capacity to `new_len`.
    /// May invalidate element pointers.
    /// Asserts that the new length is less than or equal to the previous length.
    /// If succeds capacity is guaranteed to be equal to the length.
    pub fn shrinkAndFreePrecise(self: *GrowableString, gpa: Allocator, new_len: usize) Allocator.Error!void {
        std.debug.assert(new_len <= self.items.len);

        if (self.is_readonly) {
            const new_memory = try gpa.alignedAlloc(u8, alignment, new_len);

            @memcpy(new_memory, self.items[0..new_len]);
            self.items = new_memory;
            self.capacity = new_memory.len;
            self.is_readonly = false;
        }

        const old_memory = self.allocatedSlice();
        if (gpa.remap(old_memory, new_len)) |new_items| {
            self.capacity = new_items.len;
            self.items = new_items;
            return;
        }

        const new_memory = try gpa.alignedAlloc(u8, alignment, new_len);

        @memcpy(new_memory, self.items[0..new_len]);
        gpa.free(old_memory);
        self.items = new_memory;
        self.capacity = new_memory.len;
    }

    /// Shrinks capacity to match length.
    /// May invalidate element pointers.
    /// If succeds it is safe to call toOwnedSliceAssert().
    pub fn shrinkToLen(self: *GrowableString, gpa: Allocator) Allocator.Error!void {
        try self.shrinkAndFreePrecise(gpa, self.items.len);
    }

    /// Shrinks or expands capacity to match length + 1.
    /// May invalidate element pointers.
    /// If succeds it is safe to call toOwnedSliceSentinelAssert().
    pub fn shrinkToLenSentinel(self: *GrowableString, gpa: Allocator) Allocator.Error!void {
        std.debug.assert(self.items.len <= self.capacity);
        const required_len = self.items.len + 1;
        switch (std.math.order(required_len, self.capacity)) {
            .eq => return,
            .gt => {
                try self.ensureTotalCapacityPrecise(gpa, required_len);
            },
            .lt => {
                self.items.len += 1;
                defer self.items.len -= 1;
                try self.shrinkToLen(gpa);
            },
        }
    }

    /// Reduce length to `new_len`.
    /// Invalidates pointers to elements `items[new_len..]`.
    /// Keeps capacity the same.
    /// Asserts that the new length is less than or equal to the previous length.
    pub fn shrinkRetainingCapacity(self: *GrowableString, new_len: usize) void {
        std.debug.assert(new_len <= self.items.len);
        @memset(self.items[new_len..], undefined);
        self.items.len = new_len;
    }

    /// Reduce length to 0.
    /// Invalidates all element pointers.
    pub fn clearRetainingCapacity(self: *GrowableString) void {
        @memset(self.items, undefined);
        self.items.len = 0;
    }

    /// Invalidates all element pointers.
    pub fn clearAndFree(self: *GrowableString, gpa: Allocator) void {
        if (self.is_readonly) gpa.free(self.allocatedSlice());
        self.items.len = 0;
        self.capacity = 0;
    }

    /// Modify the array so that it can hold at least `new_capacity` items.
    /// Implements super-linear growth to achieve amortized O(1) append operations.
    /// Invalidates element pointers if additional memory is needed.
    pub fn ensureTotalCapacity(self: *GrowableString, gpa: Allocator, new_capacity: usize) Allocator.Error!void {
        if (self.capacity >= new_capacity) return;
        return self.ensureTotalCapacityPrecise(gpa, growCapacity(new_capacity));
    }

    /// If the current capacity is less than `new_capacity`, this function will
    /// modify the array so that it can hold exactly `new_capacity` items.
    /// Invalidates element pointers if additional memory is needed.
    pub fn ensureTotalCapacityPrecise(self: *GrowableString, gpa: Allocator, new_capacity: usize) Allocator.Error!void {
        if (self.capacity >= new_capacity) return;

        // Here we avoid copying allocated but unused bytes by
        // attempting a resize in place, and falling back to allocating
        // a new buffer and doing our own copy. With a realloc() call,
        // the allocator implementation would pointlessly copy our
        // extra capacity.
        const old_memory = self.allocatedSlice();
        if (self.is_readonly) {
            const new_memory = try gpa.alignedAlloc(u8, alignment, new_capacity);
            @memcpy(new_memory[0..self.items.len], self.items);
            self.items.ptr = new_memory.ptr;
            self.capacity = new_memory.len;
            self.is_readonly = false;
        } else {
            if (gpa.remap(old_memory, new_capacity)) |new_memory| {
                self.items.ptr = new_memory.ptr;
                self.capacity = new_memory.len;
            } else {
                const new_memory = try gpa.alignedAlloc(u8, alignment, new_capacity);
                @memcpy(new_memory[0..self.items.len], self.items);
                gpa.free(old_memory);
                self.items.ptr = new_memory.ptr;
                self.capacity = new_memory.len;
            }
        }
    }

    /// Modify the array so that it can hold at least `additional_count` **more** items.
    /// Invalidates element pointers if additional memory is needed.
    pub fn ensureUnusedCapacity(
        self: *GrowableString,
        gpa: Allocator,
        additional_count: usize,
    ) Allocator.Error!void {
        return self.ensureTotalCapacity(gpa, try addOrOom(self.items.len, additional_count));
    }

    /// Increases the array's length to match the full capacity that is already allocated.
    /// The new elements have `undefined` values.
    /// Never invalidates element pointers.
    pub fn expandToCapacity(self: *GrowableString) void {
        self.items.len = self.capacity;
    }

    /// Increase length by 1, returning pointer to the new item.
    /// The returned element pointer becomes invalid when the list is resized.
    pub fn addOne(self: *GrowableString, gpa: Allocator) Allocator.Error!*u8 {
        // This can never overflow because `self.items` can never occupy the whole address space
        const newlen = self.items.len + 1;
        try self.ensureTotalCapacity(gpa, newlen);
        return self.addOneAssumeCapacity();
    }

    /// Increase length by 1, returning pointer to the new item.
    ///
    /// Never invalidates element pointers.
    ///
    /// The returned element pointer becomes invalid when the list is resized.
    ///
    /// Asserts that the list can hold one additional item.
    pub fn addOneAssumeCapacity(self: *GrowableString) *u8 {
        std.debug.assert(self.items.len < self.capacity);

        self.items.len += 1;
        return &self.items[self.items.len - 1];
    }

    /// Resize the array, adding `n` new elements, which have `undefined` values.
    /// The return value is an array pointing to the newly allocated elements.
    /// The returned pointer becomes invalid when the list is resized.
    pub fn addManyAsArray(self: *GrowableString, gpa: Allocator, comptime n: usize) Allocator.Error!*[n]u8 {
        const prev_len = self.items.len;
        try self.resize(gpa, try addOrOom(self.items.len, n));
        return self.items[prev_len..][0..n];
    }

    /// Resize the array, adding `n` new elements, which have `undefined` values.
    ///
    /// The return value is an array pointing to the newly allocated elements.
    ///
    /// Never invalidates element pointers.
    ///
    /// The returned pointer becomes invalid when the list is resized.
    ///
    /// Asserts that the list can hold the additional items.
    pub fn addManyAsArrayAssumeCapacity(self: *GrowableString, comptime n: usize) *[n]u8 {
        std.debug.assert(self.items.len + n <= self.capacity);
        const prev_len = self.items.len;
        self.items.len += n;
        return self.items[prev_len..][0..n];
    }

    /// Resize the array, adding `n` new elements, which have `undefined` values.
    /// The return value is a slice pointing to the newly allocated elements.
    /// The returned pointer becomes invalid when the list is resized.
    /// Resizes list if `self.capacity` is not large enough.
    pub fn addManyAsSlice(self: *GrowableString, gpa: Allocator, n: usize) Allocator.Error![]u8 {
        const prev_len = self.items.len;
        try self.resize(gpa, try addOrOom(self.items.len, n));
        return self.items[prev_len..][0..n];
    }

    /// Resizes the array, adding `n` new elements, which have `undefined`
    /// values, returning a slice pointing to the newly allocated elements.
    ///
    /// Never invalidates element pointers. The returned pointer becomes
    /// invalid when the list is resized.
    ///
    /// Asserts that the list can hold the additional items.
    pub fn addManyAsSliceAssumeCapacity(self: *GrowableString, n: usize) []u8 {
        std.debug.assert(self.items.len + n <= self.capacity);
        const prev_len = self.items.len;
        self.items.len += n;
        return self.items[prev_len..][0..n];
    }

    /// Remove and return the last element from the list.
    /// If the list is empty, returns `null`.
    /// Invalidates pointers to last element.
    pub fn pop(self: *GrowableString) ?u8 {
        if (self.items.len == 0) return null;
        const val = self.items[self.items.len - 1];
        self.items[self.items.len - 1] = undefined;
        self.items.len -= 1;
        return val;
    }

    /// Returns a slice of all the items plus the extra capacity, whose memory
    /// contents are `undefined`.
    pub fn allocatedSlice(self: GrowableString) Slice {
        return self.items.ptr[0..self.capacity];
    }

    /// Returns a slice of only the extra capacity after items.
    /// This can be useful for writing directly into an ArrayList.
    /// Note that such an operation must be followed up with a direct
    /// modification of `self.items.len`.
    pub fn unusedCapacitySlice(self: GrowableString) []u8 {
        return self.allocatedSlice()[self.items.len..];
    }

    /// Return the last element from the list.
    /// Asserts that the list is not empty.
    pub fn getLast(self: GrowableString) u8 {
        return self.items[self.items.len - 1];
    }

    /// Return the last element from the list, or
    /// return `null` if list is empty.
    pub fn getLastOrNull(self: GrowableString) ?u8 {
        if (self.items.len == 0) return null;
        return self.getLast();
    }

    /// Called when memory growth is necessary. Returns a capacity larger than
    /// minimum that grows super-linearly.
    pub fn growCapacity(minimum: usize) usize {
        const init_capacity: comptime_int = @max(1, std.atomic.cache_line / @sizeOf(u8));
        return minimum +| (minimum / 2 + init_capacity);
    }
};

pub const Node = struct {
    pub const String = GrowableString;

    id: usize,
    string: String,
    total_length: usize,
    parent: ?*Node = null,
    left: ?*Node = null,
    right: ?*Node = null,

    var next_id: usize = 0;

    pub inline fn init(node: *Node, left: ?*Node, right: ?*Node) *Node {
        if (left) |l| l.parent = node;
        if (right) |r| r.parent = node;
        defer next_id += 1;
        node.* = .{
            .id = next_id,
            .string = .empty,
            .total_length = (if (left) |l| l.total_length else 0) + if (right) |r| r.total_length else 0,
            .left = left,
            .right = right,
        };
        return node;
    }

    pub inline fn isLeaf(self: *const Node) bool {
        // this commented code doesn't work, as we can have nodes with empty strings
        // if (builtin.mode == .Debug) {
        //     if (self.string.items.len == 0)
        //         std.debug.assert(self.left != null or self.right != null)
        //     else
        //         std.debug.assert(self.left == null and self.right == null);
        // }
        // return self.string.items.len != 0;

        if (builtin.mode == .Debug) {
            if (self.string.items.len > 0)
                std.debug.assert(self.left == null and self.right == null);
        }
        return self.left == null and self.right == null;
    }

    pub fn nextLeaf(self: *Node) ?*Node {
        var current = self;
        var gone_right = false;
        while (current.parent) |parent| {
            if (parent.left == current) {
                current = parent.right.?; // TODO: support null nodes
                gone_right = true;
                break;
            }
            std.debug.assert(parent.right == current);
            current = parent;
        }
        if (gone_right) {
            while (!current.isLeaf()) {
                current = current.left.?;
            }
            return current;
        }
        return null;
    }

    pub fn previousLeaf(self: *Node) ?*Node {
        var current = self;
        var gone_left = false;
        while (current.parent) |parent| {
            if (parent.right == current) {
                current = parent.left.?; // TODO: support null nodes
                gone_left = true;
                break;
            }
            std.debug.assert(parent.left == current);
            current = parent;
        }
        if (gone_left) {
            while (!current.isLeaf()) {
                current = current.right.?;
            }
            return current;
        }
        return null;
    }

    /// Get the next character and its node, relative to the given node, and character offset of that node.
    /// node must be a leaf node.
    /// node_offset must be a valid offset into the string of node.
    pub fn nextNodeChar(node: *Node, node_offset: usize) ?struct { *Node, usize } {
        std.debug.assert(node.isLeaf());
        var current = node;
        const utf8_len = std.unicode.utf8ByteSequenceLength(node.string.items[node_offset]) catch @panic("invalid utf8");
        var current_node_offset = node_offset + utf8_len;
        while (current_node_offset >= current.string.items.len) {
            current_node_offset -= current.string.items.len;
            current = current.nextLeaf() orelse return null;
        }
        return .{ current, current_node_offset };
    }

    /// Get the next character and its node, relative to the given node, and character offset of that node.
    /// node must be a leaf node.
    /// node_offset must be a valid offset into the string of node.
    pub fn nthNextNodeChar(node: *Node, node_offset: usize, n: usize) ?struct { *Node, usize } {
        std.debug.assert(node.isLeaf());
        var current = node;
        var offset = node_offset;

        for (0..n) |_| {
            current, offset = node.nextNodeChar(offset) orelse return null;
        }
        return .{ current, offset };
    }

    /// Get the previous character and its node, relative to the given node, and character offset of that node.
    /// node must be a leaf node.
    /// node_offset must be a valid offset into the string of node.
    pub fn previousNodeChar(node: *Node, node_offset: usize) ?struct { *Node, usize } {
        std.debug.assert(node.isLeaf());
        var current = node;

        // const utf8_len = std.unicode.utf8ByteSequenceLength(node.string.items[node_offset]) catch @panic("invalid utf8");
        var current_node_offset = node_offset;

        // Handles the case we start at the beginning of a rope node. We got the previous node, if it exists.
        while (current_node_offset == 0) {
            current = current.previousLeaf() orelse return null;
            std.debug.assert(current != node);
            current_node_offset += current.string.items.len;
        }
        std.debug.assert(current_node_offset > 0);

        current_node_offset -= 1;
        // Handles the case where we're in the middle of a rope node, and we're not the start of a utf8 char.
        // @NOTE: multi char utf8 characters should not span across node boundries.
        while ((current.string.items[current_node_offset] & 0b11000000) == 0b10000000) {
            // This loop implies an invalid utf8 sequence, because of the note above, but whatever, just go to the previous node.
            while (current_node_offset == 0) {
                current = current.previousLeaf() orelse return null;
                current_node_offset += current.string.items.len;
            }
            current_node_offset -= 1;
        }

        return .{ current, current_node_offset };
    }

    pub fn getNonLeafs(self: *Node, scratch: std.mem.Allocator) std.ArrayList(*Node) {
        var list = std.ArrayList(*Node).empty;
        self.getNonLeafsImpl(&list, scratch);
        return list;
    }

    pub fn getNonLeafsImpl(self: *Node, list: *std.ArrayList(*Node), scratch: std.mem.Allocator) void {
        if (!self.isLeaf()) {
            list.append(scratch, self) catch @panic("OOM");
            if (self.left) |left| {
                left.getNonLeafsImpl(list, scratch);
            }
            if (self.right) |right| {
                right.getNonLeafsImpl(list, scratch);
            }
        }
    }

    fn setLen(self: *Node, old_len: usize, len: usize) void {
        var current: ?*Node = self;
        if (old_len > len) {
            const inc = old_len - len;
            while (current != null) {
                current.?.total_length -= inc;
                current = current.?.parent;
            }
        } else {
            const inc = len - old_len;
            while (current != null) {
                current.?.total_length += inc;
                current = current.?.parent;
            }
        }
    }

    /// Insert `item` at index `i`. Moves `list[i .. list.len]` to higher indices to make room.
    /// If `i` is equal to the length of the list this operation is equivalent to append.
    /// This operation is O(N).
    /// Invalidates element pointers if additional memory is needed.
    /// Asserts that the index is in bounds or equal to the length.
    pub inline fn insert(self: *Node, gpa: Allocator, i: usize, item: u8) Allocator.Error!void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.insert(gpa, i, item);
    }

    /// Insert `item` at index `i`. Moves `list[i .. list.len]` to higher indices to make room.
    ///
    /// If `i` is equal to the length of the list this operation is equivalent to append.
    ///
    /// This operation is O(N).
    ///
    /// Asserts that the list has capacity for one additional item.
    ///
    /// Asserts that the index is in bounds or equal to the length.
    pub inline fn insertAssumeCapacity(self: *Node, i: usize, item: u8) void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.insertAssumeCapacity(i, item);
    }

    /// Add `count` new elements at position `index`, which have
    /// `undefined` values. Returns a slice pointing to the newly allocated
    /// elements, which becomes invalid after various `ArrayList`
    /// operations.
    /// Invalidates pre-existing pointers to elements at and after `index`.
    /// Invalidates all pre-existing element pointers if capacity must be
    /// increased to accommodate the new elements.
    /// Asserts that the index is in bounds or equal to the length.
    pub inline fn addManyAt(self: *Node, index: usize, count: usize) Allocator.Error![]u8 {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.addManyAt(index, count);
    }

    /// Add `count` new elements at position `index`, which have
    /// `undefined` values. Returns a slice pointing to the newly allocated
    /// elements, which becomes invalid after various `ArrayList`
    /// operations.
    /// Invalidates pre-existing pointers to elements at and after `index`, but
    /// does not invalidate any before that.
    /// Asserts that the list has capacity for the additional items.
    /// Asserts that the index is in bounds or equal to the length.
    pub inline fn addManyAtAssumeCapacity(self: *Node, index: usize, count: usize) []u8 {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.addManyAtAssumeCapacity(index, count);
    }

    /// Insert slice `items` at index `i` by moving `list[i .. list.len]` to make room.
    /// This operation is O(N).
    /// Invalidates pre-existing pointers to elements at and after `index`.
    /// Invalidates all pre-existing element pointers if capacity must be
    /// increased to accommodate the new elements.
    /// Asserts that the index is in bounds or equal to the length.
    pub inline fn insertSlice(self: *Node, gpa: Allocator, index: usize, items: []const u8) Allocator.Error!void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.insertSlice(gpa, index, items);
    }

    /// Insert slice `items` at index `i` by moving `list[i .. list.len]` to make room.
    /// This operation is O(N).
    /// Invalidates pre-existing pointers to elements at and after `index`.
    /// Asserts that the list has capacity for the additional items.
    /// Asserts that the index is in bounds or equal to the length.
    pub inline fn insertSliceAssumeCapacity(self: *Node, index: usize, items: []const u8) void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.insertSliceAssumeCapacity(index, items);
    }

    /// Grows or shrinks the list as necessary.
    /// Invalidates element pointers if additional capacity is allocated.
    /// Asserts that the range is in bounds.
    pub inline fn replaceRange(self: *Node, gpa: Allocator, start: usize, len: usize, new_items: []const u8) Allocator.Error!void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.replaceRange(gpa, start, len, new_items);
    }

    /// Grows or shrinks the list as necessary.
    ///
    /// Never invalidates element pointers.
    ///
    /// Asserts the capacity is enough for additional items.
    pub inline fn replaceRangeAssumeCapacity(self: *Node, start: usize, len: usize, new_items: []const u8) void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.replaceRangeAssumeCapacity(start, len, new_items);
    }

    /// Extend the list by 1 element. Allocates more memory as necessary.
    /// Invalidates element pointers if additional memory is needed.
    pub inline fn append(self: *Node, gpa: Allocator, item: u8) Allocator.Error!void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.append(gpa, item);
    }

    /// Extend the list by 1 element.
    ///
    /// Never invalidates element pointers.
    ///
    /// Asserts that the list can hold one additional item.
    pub inline fn appendAssumeCapacity(self: *Node, item: u8) void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.append(item);
    }

    /// Remove the element at index `i` from the list and return its value.
    /// Invalidates pointers to the last element.
    /// This operation is O(N).
    /// Asserts that the index is in bounds.
    pub inline fn orderedRemove(self: *Node, i: usize) u8 {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.orderedRemove(i);
    }

    /// Remove the elements indexed by `sorted_indexes`. The indexes to be
    /// removed correspond to the array list before deletion.
    ///
    /// Asserts:
    /// * Each index to be removed is in bounds.
    /// * The indexes to be removed are sorted ascending.
    ///
    /// Duplicates in `sorted_indexes` are allowed.
    ///
    /// This operation is O(N).
    ///
    /// Invalidates element pointers beyond the first deleted index.
    pub inline fn orderedRemoveMany(self: *Node, sorted_indexes: []const usize) void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.orderedRemoveMany(sorted_indexes);
    }

    /// Removes the element at the specified index and returns it.
    /// The empty slot is filled from the end of the list.
    /// Invalidates pointers to last element.
    /// This operation is O(1).
    /// Asserts that the index is in bounds.
    pub inline fn swapRemove(self: *Node, i: usize) u8 {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.swapRemove(i);
    }

    /// Append the slice of items to the list. Allocates more
    /// memory as necessary.
    /// Invalidates element pointers if additional memory is needed.
    pub inline fn appendSlice(self: *Node, gpa: Allocator, items: []const u8) Allocator.Error!void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.appendSlice(gpa, items);
    }

    /// Append the slice of items to the list.
    ///
    /// Asserts that the list can hold the additional items.
    pub inline fn appendSliceAssumeCapacity(self: *Node, items: []const u8) void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.appendSliceAssumeCapacity(items);
    }

    pub inline fn print(self: *Node, gpa: Allocator, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.print(gpa, fmt, args);
    }

    pub inline fn printAssumeCapacity(self: *Node, comptime fmt: []const u8, args: anytype) void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.printAssumeCapacity(fmt, args);
    }

    /// Append a value to the list `n` times.
    /// Allocates more memory as necessary.
    /// Invalidates element pointers if additional memory is needed.
    /// The function is inline so that a comptime-known `value` parameter will
    /// have a more optimal memset codegen in case it has a repeated byte pattern.
    pub inline fn appendNTimes(self: *Node, gpa: Allocator, value: u8, n: usize) Allocator.Error!void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.appendNTimes(gpa, value, n);
    }

    /// Append a value to the list `n` times.
    ///
    /// Never invalidates element pointers.
    ///
    /// The function is inline so that a comptime-known `value` parameter will
    /// have better memset codegen in case it has a repeated byte pattern.
    ///
    /// Asserts that the list can hold the additional items.
    pub inline fn appendNTimesAssumeCapacity(self: *Node, value: u8, n: usize) void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.appendNTimesAssumeCapacity(value, n);
    }

    /// Adjust the list length to `new_len`.
    /// Additional elements contain the value `undefined`.
    /// Invalidates element pointers if additional memory is needed.
    pub inline fn resize(self: *Node, gpa: Allocator, new_len: usize) Allocator.Error!void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.resize(gpa, new_len);
    }

    /// Reduce allocated capacity to `new_len`.
    /// May invalidate element pointers.
    /// Asserts that the new length is less than or equal to the previous length.
    pub inline fn shrinkAndFree(self: *Node, gpa: Allocator, new_len: usize) void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.shrinkAndFree(gpa, new_len);
    }

    /// Reduce allocated capacity to `new_len`.
    /// May invalidate element pointers.
    /// Asserts that the new length is less than or equal to the previous length.
    /// If succeds capacity is guaranteed to be equal to the length.
    pub inline fn shrinkAndFreePrecise(self: *Node, gpa: Allocator, new_len: usize) Allocator.Error!void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.shrinkAndFreePrecise(gpa, new_len);
    }

    /// Shrinks capacity to match length.
    /// May invalidate element pointers.
    /// If succeds it is safe to call toOwnedSliceAssert().
    pub inline fn shrinkToLen(self: *Node, gpa: Allocator) Allocator.Error!void {
        std.debug.assert(self.isLeaf());
        return self.string.shrinkToLen(gpa);
    }

    /// Shrinks or expands capacity to match length + 1.
    /// May invalidate element pointers.
    /// If succeds it is safe to call toOwnedSliceSentinelAssert().
    pub inline fn shrinkToLenSentinel(self: *Node, gpa: Allocator) Allocator.Error!void {
        std.debug.assert(self.isLeaf());
        return self.string.shrinkToLenSentinel(gpa);
    }

    /// Reduce length to `new_len`.
    /// Invalidates pointers to elements `items[new_len..]`.
    /// Keeps capacity the same.
    /// Asserts that the new length is less than or equal to the previous length.
    pub inline fn shrinkRetainingCapacity(self: *Node, new_len: usize) void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.shrinkRetainingCapacity(new_len);
    }

    /// Reduce length to 0.
    /// Invalidates all element pointers.
    pub inline fn clearRetainingCapacity(self: *Node) void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.clearRetainingCapacity();
    }

    /// Invalidates all element pointers.
    pub inline fn clearAndFree(self: *Node, gpa: Allocator) void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.clearAndFree(gpa);
    }

    /// Modify the array so that it can hold at least `new_capacity` items.
    /// Implements super-linear growth to achieve amortized O(1) append operations.
    /// Invalidates element pointers if additional memory is needed.
    pub inline fn ensureTotalCapacity(self: *Node, gpa: Allocator, new_capacity: usize) Allocator.Error!void {
        std.debug.assert(self.isLeaf());
        return self.string.ensureTotalCapacity(gpa, new_capacity);
    }

    /// If the current capacity is less than `new_capacity`, this function will
    /// modify the array so that it can hold exactly `new_capacity` items.
    /// Invalidates element pointers if additional memory is needed.
    pub inline fn ensureTotalCapacityPrecise(self: *Node, gpa: Allocator, new_capacity: usize) Allocator.Error!void {
        std.debug.assert(self.isLeaf());
        return self.string.ensureTotalCapacityPrecise(gpa, new_capacity);
    }

    /// Modify the array so that it can hold at least `additional_count` **more** items.
    /// Invalidates element pointers if additional memory is needed.
    pub inline fn ensureUnusedCapacity(self: *Node, gpa: Allocator, additional_count: usize) Allocator.Error!void {
        return self.string.ensureUnusedCapacity(gpa, additional_count);
    }

    /// Increases the array's length to match the full capacity that is already allocated.
    /// The new elements have `undefined` values.
    /// Never invalidates element pointers.
    pub inline fn expandToCapacity(self: *Node) void {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.expandToCapacity();
    }

    /// Increase length by 1, returning pointer to the new item.
    /// The returned element pointer becomes invalid when the list is resized.
    pub inline fn addOne(self: *Node, gpa: Allocator) Allocator.Error!*u8 {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.addOne(gpa);
    }

    /// Increase length by 1, returning pointer to the new item.
    ///
    /// Never invalidates element pointers.
    ///
    /// The returned element pointer becomes invalid when the list is resized.
    ///
    /// Asserts that the list can hold one additional item.
    pub inline fn addOneAssumeCapacity(self: *Node) *u8 {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.addOneAssumeCapacity();
    }

    /// Resize the array, adding `n` new elements, which have `undefined` values.
    /// The return value is an array pointing to the newly allocated elements.
    /// The returned pointer becomes invalid when the list is resized.
    pub inline fn addManyAsArray(self: *Node, gpa: Allocator, comptime n: usize) Allocator.Error!*[n]u8 {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.addManyAsArray(gpa, n);
    }

    /// Resize the array, adding `n` new elements, which have `undefined` values.
    ///
    /// The return value is an array pointing to the newly allocated elements.
    ///
    /// Never invalidates element pointers.
    ///
    /// The returned pointer becomes invalid when the list is resized.
    ///
    /// Asserts that the list can hold the additional items.
    pub inline fn addManyAsArrayAssumeCapacity(self: *Node, comptime n: usize) *[n]u8 {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.addManyAsArrayAssumeCapacity(n);
    }

    /// Resize the array, adding `n` new elements, which have `undefined` values.
    /// The return value is a slice pointing to the newly allocated elements.
    /// The returned pointer becomes invalid when the list is resized.
    /// Resizes list if `self.capacity` is not large enough.
    pub inline fn addManyAsSlice(self: *Node, gpa: Allocator, n: usize) Allocator.Error![]u8 {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.addManyAsSlice(gpa, n);
    }

    /// Resizes the array, adding `n` new elements, which have `undefined`
    /// values, returning a slice pointing to the newly allocated elements.
    ///
    /// Never invalidates element pointers. The returned pointer becomes
    /// invalid when the list is resized.
    ///
    /// Asserts that the list can hold the additional items.
    pub inline fn addManyAsSliceAssumeCapacity(self: *Node, n: usize) []u8 {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.addManyAsSliceAssumeCapacity(n);
    }

    /// Remove and return the last element from the list.
    /// If the list is empty, returns `null`.
    /// Invalidates pointers to last element.
    pub inline fn pop(self: *Node) ?u8 {
        std.debug.assert(self.isLeaf());
        const old_len = self.string.items.len;
        defer self.setLen(old_len, self.string.items.len);
        return self.string.pop();
    }

    /// Returns a slice of all the items plus the extra capacity, whose memory
    /// contents are `undefined`.
    pub inline fn allocatedSlice(self: *Node) []u8 {
        std.debug.assert(self.isLeaf());
        return self.string.allocatedSlice();
    }

    /// Returns a slice of only the extra capacity after items.
    /// This can be useful for writing directly into an ArrayList.
    /// Note that such an operation must be followed up with a direct
    /// modification of `self.items.len`.
    pub inline fn unusedCapacitySlice(self: *Node) []u8 {
        std.debug.assert(self.isLeaf());
        return self.string.unusedCapacitySlice();
    }

    /// Return the last element from the list.
    /// Asserts that the list is not empty.
    pub inline fn getLast(self: *Node) u8 {
        std.debug.assert(self.isLeaf());
        return self.items[self.items.len - 1];
    }

    /// Return the last element from the list, or
    /// return `null` if list is empty.
    pub inline fn getLastOrNull(self: *Node) ?u8 {
        std.debug.assert(self.isLeaf());
        if (self.items.len == 0) return null;
        return self.getLast();
    }
};

allocator: std.mem.Allocator,
node_pool: std.heap.MemoryPool(Node),
root: ?*Node,
len: usize = 0,
balance_state: usize = 0,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .node_pool = .empty,
        .root = null,
    };
}

pub fn loadEmpty(self: *Self) void {
    const node = self.node_pool.create(self.allocator) catch @panic("OOM");
    node.* = .{
        .string = .empty,
        .total_length = 0,
    };
    self.root = node;
    self.len = 0;
}

pub fn loadString(self: *Self, string: []const u8) void {
    const node = self.node_pool.create(self.allocator) catch @panic("OOM");
    defer Node.next_id += 1;
    node.* = .{
        .id = Node.next_id,
        .string = .initReadonly(string),
        .total_length = string.len,
    };
    self.root = node;
    self.len = string.len;
}

pub fn createNode(self: *Self, left: ?*Node, right: ?*Node) *Node {
    const node = self.node_pool.create(self.allocator) catch @panic("OOM");
    _ = node.init(left, right);
    return node;
}

pub fn createLeafNode(self: *Self, string: Node.String) *Node {
    const node = self.node_pool.create(self.allocator) catch @panic("OOM");
    defer Node.next_id += 1;
    node.* = .{ .id = Node.next_id, .string = string, .total_length = string.items.len };
    return node;
}

pub fn rebalance(self: *Self, scratch: std.mem.Allocator) void {
    if (self.root) |root| {
        const result, _ = self.rebalanceNode(root, scratch);
        self.root = result;
    }
}

pub fn rebalanceNode(self: *Self, node: *Node, scratch: std.mem.Allocator) struct { *Node, usize } {
    var list = std.ArrayList(*Node).empty;
    var iterator = self.nodeIterNode(node);
    while (iterator.next()) |current_node| {
        list.append(scratch, current_node) catch @panic("OOM");
    }
    const non_leafs = node.getNonLeafs(scratch);

    var non_leafs_slice: []const *Node = non_leafs.items;
    const result, const len = self.rebalanceImpl(&non_leafs_slice, list.items);
    std.debug.assert(non_leafs_slice.len == 0); // I'm not sure if this is true, so if it breaks we know it's not

    return .{ result, len };
}

/// reuse_non_leafs is a pool of nodes to be reused before allocating new nodes
/// nodes is the list of leafs nodes to rebuild
pub fn rebalanceImpl(self: *Self, reuse_non_leafs: *[]const *Node, nodes: []const *Node) struct { *Node, usize } {
    const result = switch (nodes.len) {
        1 => .{ nodes[0], nodes[0].total_length },
        2 => .{
            if (reuse_non_leafs.len != 0) node_blk: {
                defer reuse_non_leafs.len -= 1;
                break :node_blk reuse_non_leafs.*[reuse_non_leafs.len - 1].init(nodes[0], nodes[1]);
            } else self.createNode(nodes[0], nodes[1]),
            nodes[0].total_length,
        },
        else => blk: {
            const left, const left_len = self.rebalanceImpl(reuse_non_leafs, nodes[0 .. nodes.len / 2]);
            const right, const right_len = self.rebalanceImpl(reuse_non_leafs, nodes[nodes.len / 2 ..]);

            const result = if (reuse_non_leafs.len != 0) node_blk: {
                defer reuse_non_leafs.len -= 1;
                break :node_blk reuse_non_leafs.*[reuse_non_leafs.len - 1].init(left, right);
            } else self.createNode(left, right);
            result.total_length = left_len;

            break :blk .{ result, left_len + right_len };
        },
    };

    std.debug.print("Rebalance {}\n", .{result[1]});
    return result;
}

pub fn split(self: *Self, node: *Node, index: usize) struct { *Node, *Node } {
    if (node.isLeaf()) {
        // We reuse the the current node's allocated for the lhs, and create a new allocated for rhs
        var allocated_list = GrowableString.empty;
        allocated_list.appendSlice(self.allocator, node.string.items[index..]) catch @panic("OOM");

        const new_right = self.createLeafNode(allocated_list);
        node.string.items.len = index;
        node.total_length = index;
        return .{ node, new_right };
    }

    const midpoint = if (node.left) |left| left.total_length else 0;

    if (index < midpoint) {
        const new_left, const new_right = self.split(node.left.?, index);
        const right = self.createNode(new_right, node.right);

        return .{ new_left, right };
    } else if (index > midpoint) {
        const new_left, const new_right = self.split(node.right.?, index - midpoint);
        const left = self.createNode(node.left, new_left);

        return .{ left, new_right };
    } else {
        return .{ node.left.?, node.right.? };
    }
}

/// Inserts the given string at the given index.
/// String is copied, and an allocated node is inserted.
///
/// The root node must not be empty.
pub fn insertString(self: *Self, index: usize, string: []const u8) *Node {
    std.debug.assert(self.root != null);
    const current = self.root.?;

    const allocated_string = Node.String.initReadonly(string);

    defer self.len += string.len;
    if (index == 0) {
        return self.prependString(allocated_string);
    } else if (index == self.len) {
        return self.appendString(allocated_string);
    }

    var lhs, var rhs = self.split(current, index);
    const leaf_node = self.createLeafNode(allocated_string);
    if (self.balance_state % 2 == 0) {
        lhs = self.createNode(lhs, leaf_node);
    } else {
        rhs = self.createNode(leaf_node, rhs);
    }
    self.balance_state += 1;
    self.root = self.createNode(lhs, rhs);

    return leaf_node;
}

/// Inserts the given string at the given index.
/// String is copied, and an allocated node is inserted.
///
/// The root node must not be empty.
pub fn insertGrowableString(self: *Self, index: usize, string: GrowableString) *Node {
    std.debug.assert(self.root != null);
    const current = self.root.?;

    defer self.len += string.items.len;
    if (index == 0) {
        return self.prependString(string);
    } else if (index == self.len) {
        return self.appendString(string);
    }

    var lhs, var rhs = self.split(current, index);
    const leaf_node = self.createLeafNode(string);
    if (self.balance_state % 2 == 0) {
        lhs = self.createNode(lhs, leaf_node);
    } else {
        rhs = self.createNode(leaf_node, rhs);
    }
    self.balance_state += 1;
    self.root = self.createNode(lhs, rhs);

    return leaf_node;
}

/// Inserts the given string at the given index.
/// String is copied, and an allocated node is inserted.
///
/// The root node must not be empty.
pub fn insertSplat(self: *Self, index: usize, char: u8, count: usize) *Node {
    std.debug.assert(self.root != null);
    const current = self.root.?;

    // const allocated_string = Node.String.initReadonly(string);
    var allocated_string = Node.String.initCapacity(self.allocator, count) catch @panic("OOM");
    for (allocated_string.addManyAsSliceAssumeCapacity(count)) |*a| {
        a.* = char;
    }

    defer self.len += count;
    if (index == 0) {
        return self.prependString(allocated_string);
    } else if (index == self.len) {
        return self.appendString(allocated_string);
    }

    var lhs, var rhs = self.split(current, index);
    const leaf_node = self.createLeafNode(allocated_string);
    if (self.balance_state % 2 == 0) {
        lhs = self.createNode(lhs, leaf_node);
    } else {
        rhs = self.createNode(leaf_node, rhs);
    }
    self.balance_state += 1;
    self.root = self.createNode(lhs, rhs);

    return leaf_node;
}

fn prependString(self: *Self, string: Node.String) *Node {
    var current = self.root;
    var parent: ?*Node = null;
    while (current != null and !current.?.isLeaf()) {
        parent = current;
        current.?.total_length += string.items.len;
        current = current.?.left;
    }

    const new_left = self.createLeafNode(string);
    if (parent) |p| {
        if (p.left) |left| {
            const new_parent = self.createNode(new_left, left);
            p.left = new_parent;
        } else {
            p.left = new_left;
        }
    } else {
        std.debug.assert(current != null);
        const new_parent = self.createNode(new_left, current.?);
        self.root = new_parent;
    }

    return new_left;
}

fn appendString(self: *Self, string: Node.String) *Node {
    var current = self.root;
    var parent: ?*Node = null;
    while (current != null and !current.?.isLeaf()) {
        parent = current;
        current = current.?.right;
    }

    const new_right = self.createLeafNode(string);
    if (parent) |p| {
        if (p.right) |right| {
            const new_parent = self.createNode(right, new_right);
            p.right = new_parent;
        } else {
            p.right = new_right;
        }
    } else {
        std.debug.assert(current != null);
        const new_parent = self.createNode(current.?, new_right);
        self.root = new_parent;
    }

    return new_right;
}

/// start is inclusive, end is exclusive
pub fn deleteRange(self: *Self, start: usize, end: usize) ?struct { *Node, *Node, *Node } {
    if (self.root == null) return null;
    const lhs = self.split(self.root.?, start);
    const rhs = self.split(lhs[1], end - start);

    lhs[1].parent = null;
    rhs[0].parent = null;
    var iter_ = self.nodeIterNode(lhs[1]);

    while (iter_.next()) |leaf| {
        std.debug.print("leaf: '{s}'\n", .{leaf.string.items});
    }

    self.recycleNodes(rhs[0], true);

    self.root = self.createNode(lhs[0], rhs[1]);
    var current = rhs[1];
    while (!current.isLeaf()) {
        current = current.left.?;
    }

    self.len -= end - start;
    return .{ lhs[1], rhs[0], current };
}

pub fn recycleNodes(self: *Self, root: *Node, comptime include_leafs: bool) void {
    if (root.left) |l| self.recycleNodes(l, include_leafs);
    if (root.right) |r| self.recycleNodes(r, include_leafs);

    if (include_leafs) {
        self.node_pool.destroy(root);
    } else {
        if (!root.isLeaf()) {
            self.node_pool.destroy(root);
        }
    }
}

pub fn dumpNodeToFile(node: *Node, filename: []const u8) !void {
    var io = std.Io.Threaded.init(std.heap.page_allocator, .{});

    var file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io.io(), filename, .{});
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io.io(), &buffer);

    try writer.interface.print("digraph {{\n", .{});
    _ = try dumpGraphImpl(node, 0, &writer.interface);
    try writer.interface.print("}}\n", .{});

    try writer.interface.flush();
    file.close(io.io());
}

pub fn dumpGraphToFile(self: *Self, filename: []const u8) !void {
    var io = std.Io.Threaded.init(std.heap.page_allocator, .{});

    var file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io.io(), filename, .{});
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io.io(), &buffer);

    try writer.interface.print("digraph {{\n", .{});
    var next_id = try dumpGraphImpl(self.root.?, 0, &writer.interface);

    var current = self.node_pool.free_list.first;
    while (current) |node| {
        try writer.interface.print("node_{} [label=\"recycled {*}\"];\n", .{ next_id, node });
        next_id += 1;
        current = current.?.next;
    }
    try writer.interface.print("}}\n", .{});

    try writer.interface.flush();
    file.close(io.io());
}

pub fn dumpGraph(self: *Self, writer: *std.Io.Writer) !void {
    try writer.print("digraph {{\n", .{});
    _ = try dumpGraphImpl(self.root.?, 0, writer);
    try writer.print("}}\n", .{});
}

pub fn dumpGraphImpl(node: *Node, id: usize, writer: *std.Io.Writer) !usize {
    const my_id = id;
    if (node.isLeaf()) {
        try writer.print("node{} [label=\"[{}]\\n{}\\n", .{ my_id, node.id, node.total_length });
        for (node.string.items) |c| {
            switch (c) {
                '\n' => try writer.writeAll("\\l"),
                '"' => try writer.writeAll("\\\\"),
                else => try writer.writeByte(c),
            }
        }
        try writer.print("\"];\n", .{});

        return id + 1;
    } else {
        var next_id = id;

        try writer.print("node{} [label=\"[{}]\n{}\"];\n", .{ my_id, node.id, node.total_length });

        if (node.left) |left| {
            next_id = try dumpGraphImpl(left, id + 1, writer);
            try writer.print("node{} -> node{}\n", .{ my_id, id + 1 });
        }
        if (node.right) |right| {
            const this_id = next_id;
            next_id = try dumpGraphImpl(right, this_id, writer);
            try writer.print("node{} -> node{}\n", .{ my_id, this_id });
        }

        return next_id;
    }
}

pub const Iterator = struct {
    node_iter: NodeIterator = .{},
    index: usize = 0,

    pub inline fn save(self: Iterator) Iterator {
        return self;
    }

    pub inline fn restore(self: *Iterator, saved: Iterator) void {
        self.* = saved;
    }

    pub fn nextByte(self: *Iterator) ?u8 {
        var current_node = self.node_iter.current();
        while (current_node != null and self.index >= current_node.?.string.items.len) {
            current_node = self.node_iter.next();
            self.index = 0;
        }
        const current = current_node orelse return null;

        defer self.index += 1;

        return current.string.items[self.index];
    }

    pub fn prevByte(self: *Iterator) ?u8 {
        var current_node = self.node_iter.current();
        while (current_node != null and self.index == 0) {
            current_node = self.node_iter.prev();
            if (current_node) |cn| self.index = cn.string.items.len - 1;
        }
        const current = current_node orelse return null;

        self.index -= 1;
        return current.string.items[self.index];
    }

    pub fn next(self: *Iterator) ?u32 {
        var current_node = self.node_iter.current();
        while (current_node != null and self.index >= current_node.?.string.items.len) {
            current_node = self.node_iter.next();
            self.index = 0;
        }
        const current = current_node orelse return null;

        const length = std.unicode.utf8ByteSequenceLength(current.string.items[self.index]) catch @panic("invlaid utf8");
        const codepoint = std.unicode.utf8Decode(current.string.items[self.index .. self.index + length]) catch @panic("invalid utf8");
        defer self.index += length;

        return @as(u32, codepoint);
    }

    pub fn prev(self: *Iterator) ?u32 {
        const current = self.node_iter.current() orelse return null;
        const new_node, const new_index = current.previousNodeChar(self.index) orelse .{ null, 0 };

        const length = std.unicode.utf8ByteSequenceLength(current.string.items[self.index]) catch @panic("invlaid utf8");
        const codepoint = std.unicode.utf8Decode(current.string.items[self.index .. self.index + length]) catch @panic("invalid utf8");
        defer {
            self.node_iter.current_ = new_node;
            self.index = new_index;
        }

        return @as(u32, codepoint);
    }
};

pub inline fn iter(self: *Self) Iterator {
    return self.iterNode(self.root);
}

pub fn iterNode(self: *Self, node: ?*Node) Iterator {
    const node_iter = self.nodeIterNode(node);
    return .{
        .node_iter = node_iter,
    };
}

pub fn iterStartingFrom(self: *Self, position: Position) Iterator {
    const start_node, const start_offset = self.indexNode(position) orelse return .{
        .node_iter = .{ .root = null, .current_ = null },
    };
    return .{
        .node_iter = self.nodeIterLeafNode(start_node),
        .index = start_offset,
    };
}

pub const Utf16Iterator = struct {
    node_iter: NodeIterator,
    index: usize = 0,
    current_node: ?*Node,
    output_buffer: *[2]u16,

    pub fn next(self: *Utf16Iterator) ?struct { []u16, usize } {
        while (self.current_node != null and self.index >= self.current_node.?.string.items.len) {
            self.current_node = self.node_iter.next();
            self.index = 0;
        }
        const current = self.current_node orelse return null;

        const codepoint_length = std.unicode.utf8ByteSequenceLength(current.string.items[self.index]) catch @panic("invlaid utf8");
        const length = std.unicode.utf8ToUtf16Le(self.output_buffer.*[0..], current.string.items[self.index .. self.index + codepoint_length]) catch @panic("invalid utf8");
        defer self.index += length;

        return .{ self.output_buffer.*[0..length], codepoint_length };
    }
};

pub fn iterUtf16(self: *Self, output_buffer: *[2]u16) Utf16Iterator {
    var node_iter = self.nodeIter();
    const start_node = node_iter.next();
    return .{
        .node_iter = node_iter,
        .current_node = start_node,
        .output_buffer = output_buffer,
    };
}

pub fn iterUtf16StartingFrom(self: *Self, output_buffer: *[2]u16, position: Position) Utf16Iterator {
    const start_node, const start_offset = self.indexNode(position) orelse return .{
        .node_iter = .{ .root = null, .current_ = null },
        .current_node = null,
        .output_buffer = output_buffer,
    };

    return .{
        .node_iter = self.nodeIterLeafNode(start_node.nextLeaf()),
        .current_node = start_node,
        .output_buffer = output_buffer,
        .index = start_offset,
    };
}

pub const NodeIterator = struct {
    root: ?*Node = null,
    start_node: ?*Node = null,
    current_: ?*Node = null,

    pub fn current(self: *NodeIterator) ?*Node {
        if (self.current_ == null) {
            self.current_ = self.start_node;
            self.start_node = null;
        }
        return self.current_;
    }

    pub fn next(self: *NodeIterator) ?*Node {
        if (self.current_) |c| {
            self.current_ = c.nextLeaf();
        } else {
            self.current_ = self.start_node;
            self.start_node = null;
        }
        return self.current_;
    }

    pub fn prev(self: *NodeIterator) ?*Node {
        if (self.current_) |c| {
            self.current_ = c.previousLeaf();
        } else {
            self.current_ = self.start_node;
            self.start_node = null;
        }
        return self.current_;
    }
};

pub inline fn nodeIter(self: *Self) NodeIterator {
    return self.nodeIterNode(self.root);
}

pub inline fn nodeIterLeafNode(self: *Self, leaf: ?*Node) NodeIterator {
    std.debug.assert(leaf == null or leaf.?.isLeaf());
    return .{
        .root = self.root,
        .start_node = leaf,
    };
}

pub fn nodeIterNode(self: *Self, root_node: ?*Node) NodeIterator {
    // _ = self;
    var current: ?*Node = root_node;
    while (current) |c| {
        if (c.isLeaf()) break;
        current = c.left;
    }
    return .{ .root = self.root, .start_node = current };
}

pub const RangeIterator = struct {
    node_iter: NodeIterator,
    node_offset: usize, // @Cleanup: This is only possibly non zero for the first node...
    position: usize,
    end_position: usize,

    pub fn next(self: *RangeIterator) ?[]const u8 {
        const current = self.node_iter.next() orelse return null;
        if (self.position >= self.end_position) return null;

        const end = @min(self.node_offset + self.end_position - self.position, current.string.items.len);
        const result = current.string.items[self.node_offset..end];
        self.position += end - self.node_offset;
        self.node_offset = 0;
        return result;
    }
};

pub fn rangeIter(self: *Self, start: usize, end: usize) RangeIterator {
    const start_node, const start_offset = self.indexNode(start) orelse return .{
        .node_iter = .{},
        .node_offset = 0,
        .position = 0,
        .end_position = 0,
    };

    return .{
        .node_iter = self.nodeIterLeafNode(start_node),
        .node_offset = start_offset,
        .position = start,
        .end_position = end,
    };
}

pub fn toOwnedSlice(self: *Self, start: usize, end: usize, allocator: std.mem.Allocator) []const u8 {
    var buffer = std.Io.Writer.Allocating.initCapacity(allocator, end - start) catch @panic("OOM");
    var range_iter = self.rangeIter(start, end);
    while (range_iter.next()) |slice| {
        buffer.writer.writeAll(slice) catch @panic("OOM");
    }
    return buffer.writer.buffer;
}

/// Returns the node, and the relative string offset into the node
pub fn indexNode(self: *Self, index: usize) ?struct { *Node, usize } {
    if (index >= self.len) return null;

    var current_index = index;
    var current: ?*Node = self.root orelse return null;

    while (current != null and !current.?.isLeaf()) {
        const midpoint = if (current.?.left) |left| left.total_length else 0;
        if (current_index < midpoint) {
            current = current.?.left;
        } else {
            current_index -= midpoint;
            current = current.?.right;
        }
    }

    std.debug.assert(current != null and current.?.isLeaf());

    return if (current) |c| .{ c, current_index } else null;
}

/// Anchor must be at the start of a line
/// Get the line and column at position
pub fn lineColumnFromRelativePosition(self: *Self, anchor: usize, position: usize) ?Coordinate {
    var current_node, var current_node_offset = self.indexNode(anchor) orelse return null;

    var current_offset = anchor;
    var line: u32 = 0;
    var column: u32 = 0;

    while (current_offset < position) : (current_offset += 1) {
        switch (current_node.string.items[current_node_offset]) {
            '\r' => {},
            '\n' => {
                column = 0;
                line += 1;
            },
            else => {
                column += 1;
            },
        }
        current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse break;
    }

    return .{ .line = line, .column = column };
}

/// Position should be start of line
pub fn addLineOffsetToPosition(self: *Self, position: usize, line_offset: u32) void {
    var current_node, var current_node_offset = self.indexNode(position).?;

    var current_offset = position;
    var line: u32 = 0;
    var column: u32 = 0;

    while (current_offset < self.len and line < line_offset) : (current_offset += 1) {
        switch (current_node.string.items[current_node_offset]) {
            '\r' => {},
            '\n' => {
                column = 0;
                line += 1;
            },
            else => {
                column += 1;
            },
        }
        current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse break;
    }

    return .{ column, line };
}

pub const Position = usize;
pub const Coordinate = struct { line: u32, column: u32 };

pub fn add(self: *Self, a: anytype, b: anytype, comptime T: type) T {
    const Ta = if (@TypeOf(a) == comptime_int) Position else @TypeOf(a);
    const Tb = if (@TypeOf(b) == comptime_int) Position else @TypeOf(b);
    if (Ta == Position and Tb == Position) {
        if (T == Position) {
            return a + b;
        } else if (T == Coordinate) {
            var current_node, var current_node_offset = self.indexNode(0).?;

            var current_offset: usize = 0;
            var line: u32 = 0;
            var column: u32 = 0;

            while (current_offset < a + b) : (current_offset += 1) {
                switch (current_node.string.items[current_node_offset]) {
                    '\r' => {},
                    '\n' => {
                        column = 0;
                        line += 1;
                    },
                    else => {
                        column += 1;
                    },
                }
                current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse break;
            }

            return .{ .line = line, .column = column };
        } else {
            @compileError("Invalid result type");
        }
    } else if (Ta == Coordinate and Tb == Position) {
        var current_node, var current_node_offset = self.indexNode(0).?;

        var current_offset: usize = 0;
        var line: u32 = 0;
        var column: u32 = 0;

        while (current_offset < self.len) : (current_offset += 1) {
            if (line == a.line and column == a.column) {
                break;
            }
            switch (current_node.string.items[current_node_offset]) {
                '\r' => {},
                '\n' => {
                    if (line == a.line) {
                        break;
                    }

                    column = 0;
                    line += 1;
                },
                else => {
                    column += 1;
                },
            }
            current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse break;
        }

        while (current_offset < b and current_offset < self.len) : (current_offset += 1) {
            switch (current_node.string.items[current_node_offset]) {
                '\r' => {},
                '\n' => {
                    column = 0;
                    line += 1;
                },
                else => {
                    column += 1;
                },
            }
            current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse break;
        }

        if (T == Position) {
            return current_offset;
        } else if (T == Coordinate) {
            return .{ .line = line, .column = column };
        } else @compileError("Unsupported result type");
    } else if (Ta == Position and Tb == Coordinate) {
        var current_node, var current_node_offset = self.indexNode(a).?;

        var current_offset = a;
        var line: u32 = 0;
        var column: u32 = 0;

        while (current_offset < self.len) : (current_offset += 1) {
            if (line == b.line and column == b.column) {
                break;
            }
            switch (current_node.string.items[current_node_offset]) {
                '\r' => {},
                '\n' => {
                    if (line == b.line) {
                        break;
                    }
                    column = 0;
                    line += 1;
                },
                else => {
                    column += 1;
                },
            }
            current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse break;
        }

        if (current_offset + 1 >= self.len and line != b.line) {
            const line_range = self.getLineRange(current_offset).?;
            current_offset = @min(line_range[0] + b.column, line_range[1]);
        }

        if (T == Position) {
            return current_offset;
        } else if (T == Coordinate) {
            return .{ .line = line, .column = column };
        } else @compileError("Unsupported result type");
    } else @compileError(std.fmt.comptimePrint("Unsupported input types {} and {}", .{ Ta, Tb }));
}

pub fn sub(self: *Self, a: anytype, b: anytype, comptime T: type) T {
    const Ta = if (@TypeOf(a) == comptime_int) Position else @TypeOf(a);
    const Tb = if (@TypeOf(b) == comptime_int) Position else @TypeOf(b);
    if (Ta == Position and Tb == Position) {
        if (T == Position) {
            return a -| b;
        } else if (T == Coordinate) {
            var current_node, var current_node_offset = self.indexNode(0).?;

            var current_offset: usize = 0;
            var line: u32 = 0;
            var column: u32 = 0;

            while (current_offset < a -| b) : (current_offset += 1) {
                switch (current_node.string.items[current_node_offset]) {
                    '\r' => {},
                    '\n' => {
                        column = 0;
                        line += 1;
                    },
                    else => {
                        column += 1;
                    },
                }
                current_node, current_node_offset = current_node.previousNodeChar(current_node_offset) orelse break;
            }

            return .{ .line = line, .column = column };
        } else {
            @compileError("Invalid result type");
        }
    } else if (Ta == Coordinate and Tb == Position) {
        var current_node, var current_node_offset = self.indexNode(0).?;

        var current_offset: usize = 0;
        var line: u32 = a.line;
        var column: u32 = b.column;

        while (current_offset > b) : (current_offset -= 1) {
            switch (current_node.string.items[current_node_offset]) {
                '\r' => {},
                '\n' => {
                    column = 0;
                    line -= 1;
                },
                else => {
                    column -= 1;
                },
            }
            current_node, current_node_offset = current_node.previousNodeChar(current_node_offset) orelse break;
        }

        if (T == Position) {
            return current_offset;
        } else if (T == Coordinate) {
            return .{ .line = line, .column = column };
        } else @compileError("Unsupported result type");
    } else if (Ta == Position and Tb == Coordinate) {
        var current_node, var current_node_offset = self.indexNode(a).?;
        // std.debug.assert(b.column == 0); // @Cleanup: Not sure how to handle this yet

        var current_offset = a;
        var line: u32 = 0;

        while (current_offset > 0) : (current_offset -= 1) {
            if (line == b.line) {
                current_offset += 1;
                break;
            }
            switch (current_node.string.items[current_node_offset]) {
                '\r' => {},
                '\n' => {
                    line += 1;
                    if (line == b.line) {
                        const line_range = self.getLineRange(current_offset).?;
                        current_offset = @min(line_range[0] + b.column, line_range[1]);
                        break;
                    }
                },
                else => {},
            }
            current_node, current_node_offset = current_node.previousNodeChar(current_node_offset) orelse break;
        }

        if (T == Position) {
            return current_offset;
        } else if (T == Coordinate) {
            // return .{ .line = line, .column = column };
            unreachable;
        } else @compileError("Unsupported result type");
    } else @compileError(std.fmt.comptimePrint("Unsupported input types {} and {}", .{ Ta, Tb }));
}

/// Returns the line start (inclusive), and the line end (inclusive; includes the newline)
pub fn getLineRange(self: *Self, position: usize) ?struct { usize, usize } {
    var current_node, var current_node_offset = self.indexNode(position).?;

    var line_start: usize = position;
    var line_end: usize = position;

    // handles the case we start on newline
    if (current_node.string.items[current_node_offset] == '\n') {
        line_start -|= 1;
        current_node, current_node_offset = current_node.previousNodeChar(current_node_offset) orelse .{ current_node, 0 };
    }

    while (line_start > 0) : (line_start -= 1) {
        switch (current_node.string.items[current_node_offset]) {
            '\n' => {
                line_start += 1;
                break;
            },
            else => {},
        }

        current_node, current_node_offset = current_node.previousNodeChar(current_node_offset) orelse break;
    }

    current_node, current_node_offset = self.indexNode(position).?;

    while (line_end < self.len) : (line_end += 1) {
        switch (current_node.string.items[current_node_offset]) {
            '\n' => {
                break;
            },
            else => {},
        }
        current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse break;
    }

    return .{ line_start, line_end + 1 };
}

pub fn getNextLineRange(self: *Self, position: usize) ?struct { usize, usize } {
    var current_node, var current_node_offset = self.indexNode(position).?;

    var current_offset = position;
    var remaining_lines: u32 = 2;
    var last_line_start: usize = position;

    while (current_offset < self.len) : (current_offset += 1) {
        switch (current_node.string.items[current_node_offset]) {
            '\r' => {},
            '\n' => {
                remaining_lines -= 1;
                if (remaining_lines == 0) {
                    break;
                }
                if (current_offset + 1 >= self.len) return null; // prevents jumping to eol at eof
                last_line_start = current_offset + 1;
            },
            else => {},
        }
        // We shouldn't be in the middle of a utf8 multi byte sequence, in theory.
        std.debug.assert((current_node.string.items[current_node_offset] & 0b11000000) != 0b10000000);
        // return null if reached beginning of file, since there is no more lines.
        current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse break;
    }

    return .{ last_line_start, current_offset + 1 };
}

pub fn getPreviousLineRange(self: *Self, position: usize) ?struct { usize, usize } {
    // We do subtract 1 to handle the case of starting on newline.
    var current_node, var current_node_offset = self.indexNode(position -| 1).?;

    var current_offset = position -| 1;
    var remaining_lines: u32 = 2;
    var last_line_end: usize = position;

    while (current_offset > 0) : (current_offset -= 1) {
        switch (current_node.string.items[current_node_offset]) {
            '\r' => {},
            '\n' => {
                remaining_lines -= 1;
                if (remaining_lines == 0) {
                    current_offset += 1;
                    break;
                }
                last_line_end = current_offset;
            },
            else => {},
        }
        // We shouldn't be in the middle of a utf8 multi byte sequence, in theory.
        std.debug.assert((current_node.string.items[current_node_offset] & 0b11000000) != 0b10000000);
        // return null if reached beginning of file, since there is no more lines.
        current_node, current_node_offset = current_node.previousNodeChar(current_node_offset) orelse break;
    }

    return .{ current_offset, last_line_end + 1 };
}

pub fn getNextWord(self: *Self, position: usize) usize {
    var current_node, var current_node_offset = self.indexNode(position).?;
    var current_offset = position;

    var has_done_whitespace = false;
    var has_done_word = false;
    var has_done_other = false;

    while (current_offset < self.len) : (current_offset += 1) {
        switch (current_node.string.items[current_node_offset]) {
            ' ', '\n', '\r', '\t' => {
                has_done_whitespace = true;
            },
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {
                if (has_done_other or has_done_whitespace) break;
                has_done_word = true;
            },
            else => {
                if (has_done_word or has_done_whitespace) break;
                has_done_other = true;
            },
        }

        current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse break;
    }

    return current_offset - position;
}

pub fn getNextWordEnd(self: *Self, position: usize) usize {
    var current_node, var current_node_offset = self.indexNode(position + 1) orelse return 0;
    var current_offset = position + 1;

    var has_done_whitespace = false;
    var has_done_word = false;
    var has_done_other = false;

    while (current_offset < self.len) : (current_offset += 1) {
        switch (current_node.string.items[current_node_offset]) {
            ' ', '\n', '\r', '\t' => {
                if (has_done_word or has_done_other) {
                    current_offset -|= 1;
                    break;
                }
                has_done_whitespace = true;
            },
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {
                if (has_done_other) {
                    current_offset -|= 1;
                    break;
                }
                has_done_word = true;
            },
            else => {
                if (has_done_word) {
                    current_offset -|= 1;
                    break;
                }
                has_done_other = true;
            },
        }

        current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse break;
    }

    return current_offset - position;
}

pub fn getPreviousWord(self: *Self, position: usize) usize {
    var current_node, var current_node_offset = self.indexNode(position -| 1).?;
    var current_offset = position -| 1;

    var has_done_whitespace = false;
    var has_done_word = false;
    var has_done_other = false;

    while (current_offset > 0) : (current_offset -= 1) {
        switch (current_node.string.items[current_node_offset]) {
            ' ', '\n', '\r', '\t' => {
                if (has_done_word or has_done_other) {
                    current_offset += 1;
                    break;
                }
                has_done_whitespace = true;
            },
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {
                if (has_done_other) {
                    current_offset += 1;
                    break;
                }
                has_done_word = true;
            },
            else => {
                if (has_done_word) {
                    current_offset += 1;
                    break;
                }
                has_done_other = true;
            },
        }

        current_node, current_node_offset = current_node.previousNodeChar(current_node_offset) orelse break;
    }

    return position - current_offset;
}

pub fn getTextObject(self: *Self, textobject: ed.TextObject, outer: bool, position: usize) struct { usize, usize } {
    _ = outer;
    var current_offset = position;
    const start_node, const start_node_offset = self.indexNode(current_offset).?;
    var has_been_valid = false;
    var has_been_invalid = false;

    switch (textobject) {
        inline .word, .WORD, .double_quote, .single_quote, .backtick => |obj| {
            var current_node, var current_node_offset = .{ start_node, start_node_offset };

            while (current_offset > 0) : (current_offset -= 1) {
                const char = current_node.string.items[current_node_offset];
                if (ed.TextObject.isValid(obj, char)) {
                    if (has_been_invalid) {
                        current_offset += 1;
                        break;
                    }
                    has_been_valid = true;
                } else {
                    if (has_been_valid) {
                        current_offset += 1;
                        break;
                    }
                    has_been_invalid = true;
                }
                current_node, current_node_offset = current_node.previousNodeChar(current_node_offset) orelse break;
            }
            const start = current_offset;

            current_offset = position;
            current_node, current_node_offset = .{ start_node, start_node_offset };
            while (current_offset < self.len) : (current_offset += 1) {
                if (ed.TextObject.isValid(obj, current_node.string.items[current_node_offset])) {
                    if (!has_been_valid) {
                        break;
                    }
                } else {
                    if (has_been_valid) {
                        break;
                    }
                }
                current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse break;
            }
            const end = current_offset;

            return .{ start, end };
        },
        inline .paren, .bracket, .brace => |obj| {
            var current_node, var current_node_offset = .{ start_node, start_node_offset };
            var level: i32 = 0;

            var char = current_node.string.items[current_node_offset];
            if (char == obj.getClose()) blk: {
                // Do this, so we don't increment level in .scan_open_backward state
                current_node, current_node_offset = current_node.previousNodeChar(current_node_offset) orelse break :blk;
                current_offset -= 1;
            }

            var start = position;
            var end = position;
            // The idea here is, we first scan backwards to find the first unmatched bracket.
            //   if there is no unmatched bracket, then we start scanning forward (from the starting position)
            //   to find first open bracket. Next we scan forward to find the matching closing bracket
            sw: switch (@as(enum { scan_open_backward, scan_open_forward, scan_close_forward }, .scan_open_backward)) {
                .scan_open_backward => {
                    while (current_offset > 0) : (current_offset -= 1) {
                        char = current_node.string.items[current_node_offset];
                        switch (char) {
                            obj.getOpen() => {
                                if (level == 0) {
                                    current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse unreachable;
                                    current_offset += 1;
                                    if (current_node.string.items[current_node_offset] != obj.getClose()) {
                                        // this is sus, but works
                                    }
                                    break;
                                }
                                level -= 1;
                            },
                            obj.getClose() => {
                                level += 1;
                            },
                            else => {},
                        }
                        current_node, current_node_offset = current_node.previousNodeChar(current_node_offset) orelse unreachable;
                    } else {
                        // If we didn't break, we never reached an unmatched bracket, so start scanning forward.
                        current_node, current_node_offset = .{ start_node, start_node_offset };
                        current_offset = position;
                        continue :sw .scan_open_forward;
                    }

                    if (current_node.string.items[current_node_offset] == '\n') {
                        start = current_offset + 1;
                    } else {
                        start = current_offset;
                    }

                    continue :sw .scan_close_forward;
                },
                .scan_open_forward => {
                    level = 0;
                    while (current_offset < self.len) : (current_offset += 1) {
                        char = current_node.string.items[current_node_offset];
                        switch (char) {
                            obj.getOpen() => {
                                if (level == 0) {
                                    current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse return .{ position, position };
                                    current_offset += 1;
                                    if (current_node.string.items[current_node_offset] != obj.getClose()) {}
                                    break;
                                }

                                level += 1;
                            },
                            obj.getClose() => {
                                level -= 1;
                            },
                            else => {},
                        }
                        current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse return .{ position, position };
                    } else {
                        // If we didn't break, we never reached a valid open bracket.
                        return .{ position, position };
                    }
                    // start = current_offset;
                    if (current_node.string.items[current_node_offset] == '\n') {
                        start = current_offset + 1;
                    } else {
                        start = current_offset;
                    }

                    continue :sw .scan_close_forward;
                },
                .scan_close_forward => {
                    level = 0;
                    while (current_offset < self.len) : (current_offset += 1) {
                        char = current_node.string.items[current_node_offset];
                        switch (char) {
                            obj.getOpen() => {
                                level += 1;
                            },
                            obj.getClose() => {
                                if (level == 0) {
                                    // current_offset -= 1;
                                    break;
                                }
                                level -= 1;
                            },
                            else => {},
                        }
                        current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse break;
                    } else {
                        return .{ position, position };
                    }
                    end = current_offset;
                },
            }

            return .{ start, end };
        },
    }
}

pub const Matcher = struct {
    iterator: Iterator = .{},
    saved_iterator: Iterator = .{},
    pattern: *const ed.Pattern = undefined,
    start: usize = 0,
    end: usize = 0,
    // position: usize = 0,
    // position_opposite: usize = 0,
    dir: enum { next, prev } = .next,

    pub const empty = Matcher{};

    pub fn setCurrent(self: *Matcher, rope: *Self, position: usize) void {
        self.iterator = rope.iterStartingFrom(position);
        self.start = position;
        self.end = position;
    }

    pub fn wrapNext(self: *Matcher, rope: *Self) void {
        self.iterator = rope.iter();
        self.start = 0;
        self.end = 0;
    }

    pub fn wrapPrev(self: *Matcher, rope: *Self) void {
        self.iterator = rope.iterStartingFrom(rope.len -| 1);
        self.start = rope.len -| 1;
        self.end = rope.len -| 1;
    }

    pub fn next(self: *Matcher) ?ed.View.Selection {
        if (self.dir != .next) {
            for (self.start..self.end) |_| {
                _ = self.iterator.nextByte();
            }
        }
        self.dir = .next;

        self.start = self.end;

        var matched, var match_length = self.pattern.matchesWithIterator(Iterator.nextByte, &self.iterator);
        {
            defer self.end = self.start + match_length;
            while (!matched) {
                const t = self.iterator.next();
                if (t == null) return null;
                self.start += std.unicode.utf8CodepointSequenceLength(@truncate(t.?)) catch @panic("Invalid utf8");
                matched, match_length = self.pattern.matchesWithIterator(Iterator.nextByte, &self.iterator);
            }
        }

        return .{ .head = self.end -| 1, .tail = self.start };
    }

    pub fn prev(self: *Matcher) ?ed.View.Selection {
        if (self.dir != .prev) {
            for (self.start..self.end) |_| {
                _ = self.iterator.prevByte();
            }
        }
        self.dir = .prev;

        if (self.start == 0) {
            self.end = 0;
            return null;
        }

        self.start -= 1;
        self.end -= 1;
        _ = self.iterator.prevByte();

        var saved = self.iterator.save();
        var matched, var match_length = self.pattern.matchesWithIterator(Iterator.nextByte, &self.iterator);
        self.iterator.restore(saved);

        {
            defer self.end = self.start + match_length;
            while (!matched) {
                const t = self.iterator.prev();
                if (t == null) return null;
                self.start -= std.unicode.utf8CodepointSequenceLength(@truncate(t.?)) catch @panic("Invalid utf8");

                saved = self.iterator.save();
                matched, match_length = self.pattern.matchesWithIterator(Iterator.nextByte, &self.iterator);
                self.iterator.restore(saved);
            }
        }

        return .{ .head = self.end -| 1, .tail = self.start };
    }
};

pub fn match(self: *Self, pattern: *const ed.Pattern) Matcher {
    return .{
        .iterator = self.iter(),
        .pattern = pattern,
    };
}

pub fn matchStartingFrom(self: *Self, pattern: *const ed.Pattern, position: usize) Matcher {
    return .{
        .iterator = self.iterStartingFrom(position),
        .pattern = pattern,
        .start = position,
        .end = position,
    };
}

// test "rope test" {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();

//     var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer scratch.deinit();

//     var rope = Self.init(arena.allocator());
//     rope.loadString("what the hell are you doing");
//     rope.insertString(7, "1234", scratch.allocator());
//     rope.insertString(15, "bruhv", scratch.allocator());

//     std.debug.print("ffooba\n", .{});
//     var i = rope.iter(std.testing.allocator);
//     while (i.next()) |f| {
//         std.debug.print("char: {u}\n", .{@as(u21, @truncate(f))});
//     }
//     i.deinit();

//     // var file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), std.testing.io, "output.dot", .{});
//     // var buffer: [4096]u8 = undefined;
//     // var writer = file.writer(std.testing.io, &buffer);

//     // try rope.dumpGraph(&writer.interface);
//     // try writer.flush();
//     // file.close(std.testing.io);
// }
