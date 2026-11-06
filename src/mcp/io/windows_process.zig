const std = @import("std");
const Handle = std.os.windows.HANDLE;
extern "kernel32" fn TerminateProcess(Handle, u32) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(Handle, u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(Handle, *u32) callconv(.winapi) i32;
pub fn terminate(handle: Handle) void {
    _ = TerminateProcess(handle, 1);
}
pub fn reap(handle: Handle) void {
    _ = WaitForSingleObject(handle, 0xffffffff);
    std.os.windows.CloseHandle(handle);
}
pub fn exitCode(handle: Handle) ?u32 {
    if (WaitForSingleObject(handle, 0) != 0) return null;
    var code: u32 = 1;
    _ = GetExitCodeProcess(handle, &code);
    return code;
}

// Kept inside MCP: this engine imports no host implementation.
const w = std.os.windows;
extern "kernel32" fn CreateJobObjectW(?*anyopaque, ?[*:0]const u16) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn SetInformationJobObject(w.HANDLE, u32, *const anyopaque, u32) callconv(.winapi) i32;
extern "kernel32" fn AssignProcessToJobObject(w.HANDLE, w.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn TerminateJobObject(w.HANDLE, u32) callconv(.winapi) i32;
extern "kernel32" fn ResumeThread(w.HANDLE) callconv(.winapi) u32;

const Limits = extern struct {
    process_time: i64 = 0,
    job_time: i64 = 0,
    flags: u32 = 0x2000,
    minimum_working_set: usize = 0,
    maximum_working_set: usize = 0,
    active_processes: u32 = 0,
    affinity: usize = 0,
    priority: u32 = 0,
    scheduling: u32 = 0,
    io_counters: [6]u64 = @splat(0),
    process_memory: usize = 0,
    job_memory: usize = 0,
    peak_process_memory: usize = 0,
    peak_job_memory: usize = 0,
};

pub const Job = struct {
    handle: w.HANDLE,
    // Assign a suspended child before any of its code can launch descendants.
    pub fn attach(child: *std.process.Child) !Job {
        const handle = CreateJobObjectW(null, null) orelse return error.AccessDenied;
        errdefer w.CloseHandle(handle);
        const limits: Limits = .{};
        if (SetInformationJobObject(handle, 9, &limits, @sizeOf(Limits)) == 0 or
            AssignProcessToJobObject(handle, child.id.?) == 0) return error.AccessDenied;
        if (ResumeThread(child.thread_handle) == 0xffffffff) return error.AccessDenied;
        return .{ .handle = handle };
    }
    pub fn terminate(self: Job) void {
        _ = TerminateJobObject(self.handle, 1);
    }
    pub fn close(self: Job) void {
        w.CloseHandle(self.handle);
    }
};
