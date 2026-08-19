const std = @import("std");
const agent_stream_provider = @import("../../core/agent/stream_provider.zig");
const secret = @import("../../core/auth/secret.zig");
const gateway_provider = @import("../../core/gateway/gateway_provider.zig");
const model_catalog = @import("../../core/gateway/model_catalog.zig");
const output_contracts = @import("../../core/output/output_contracts.zig");
const io_mod = @import("../../core/shared/io.zig");
const providers_config = @import("../../core/providers/config.zig");
const openai_compatible = @import("../../gateway/openai_compatible.zig");
const gateway_client = @import("../../gateway/client.zig");
const oauth_transport = @import("../../core/auth/oauth_transport.zig");
const generation_usage_provider = @import("../../core/session/generation_usage_provider.zig");
const web_search_contract = @import("../../core/tooling/web_search_contract.zig");
const web_search_policy = @import("../../core/tooling/web_search_policy.zig");
const web_search_provider = @import("../../core/tooling/web_search_provider.zig");

const Allocator = std.mem.Allocator;

pub const no_gateway_balance_message = "this backend has no gateway balance";

pub const agent_stream_provider_value = agent_stream_provider.Provider{
    .build_fn = buildAgentRequest,
    .stream_fn = streamAgentCompletion,
};

pub const chat_url_provider = gateway_provider.ChatUrlProvider{
    .resolve_fn = resolveChatUrl,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

pub const credits_provider = gateway_provider.CreditsProvider{
    .fetch_fn = fetchCredits,
};

const unavailable_web_search_provider = web_search_provider.Provider{
    .policy = .{
        .preferred_backends = &.{},
        .backend_policies = &.{},
    },
    .preferred_backends_fn = preferredWebSearchBackends,
    .execute_fn = executeWebSearch,
};

pub const provider = gateway_provider.Provider{
    .agent_stream = agent_stream_provider_value,
    .oauth_transport = oauth_transport.unavailable_provider,
    .chat_url = chat_url_provider,
    .cli_model_catalog = cli_model_catalog_provider,
    .credits = credits_provider,
    .generation_usage = generation_usage_provider.unavailable_provider,
    .web_search = unavailable_web_search_provider,
    .model_catalog = .{ .fetch_fn = fetchModelCatalog },
};

fn preferredWebSearchBackends(_: ?*anyopaque) anyerror!?[]const web_search_contract.SearchBackendId {
    return null;
}

fn executeWebSearch(
    _: ?*anyopaque,
    _: Allocator,
    _: web_search_provider.Inputs,
    _: web_search_contract.ProviderRequest,
    _: ?web_search_contract.ProgressFn,
    _: ?*anyopaque,
) !web_search_contract.ProviderResponse {
    return error.WebSearchUnavailable;
}

fn currentResolved() providers_config.Resolved {
    return providers_config.resolveActive();
}

fn buildAgentRequest(
    _: ?*anyopaque,
    alloc: Allocator,
    request: agent_stream_provider.BuildRequest,
) anyerror![]u8 {
    return openai_compatible.buildChatCompletionsBody(alloc, request);
}

fn streamAgentCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: agent_stream_provider.Request,
) anyerror!agent_stream_provider.Result {
    const resolved = currentResolved();
    var owned_url: ?[]u8 = null;
    defer if (owned_url) |value| alloc.free(value);
    var owned_key: ?[]u8 = null;
    defer if (owned_key) |value| secret.zeroAndFree(alloc, value);

    const chat_url = blk: {
        if (std.mem.endsWith(u8, request.chat_url, "chat/completions")) break :blk request.chat_url;
        if (try resolved.chatCompletionsUrlAlloc(alloc)) |url| {
            owned_url = url;
            break :blk url;
        }
        break :blk request.chat_url;
    };
    const api_key = blk: {
        if (try resolved.loadApiKey(alloc)) |key| {
            owned_key = key;
            break :blk key;
        }
        break :blk request.api_key;
    };

    const result = openai_compatible.streamChatCompletions(
        alloc,
        .{
            .api_key = api_key,
            .model = request.model,
            .retry_count = request.retry_count,
            .chat_url = chat_url,
            .payload = request.payload,
            .trace_ctx = request.trace_ctx,
            .content_capture_limit = request.content_capture_limit,
            .delivery = request.delivery,
            .on_reasoning_chunk = request.on_reasoning_chunk,
            .on_tool_input_chunk = request.on_tool_input_chunk,
            .provider_attempt_owner = request.provider_attempt_owner,
        },
        request.callback_ctx,
        request.on_content_chunk,
        request.on_tool_start,
        request.cancel_flag,
    ) catch |err| {
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(
            err,
            request.delivery.load(),
        );
        return err;
    };
    return .{
        .status = result.status,
        .completion = result.completion,
        .err_body = result.err_body,
        .generation_origin = "",
        .reconcile_generation_usage = false,
        .retry_after_seconds = result.retry_after_seconds,
        .ownership = .owned,
    };
}

fn resolveChatUrl(_: ?*anyopaque, fallback: []const u8) []const u8 {
    const resolved = currentResolved();
    return resolved.openai_compatible.base_url orelse fallback;
}

fn fetchCredits(
    _: ?*anyopaque,
    alloc: Allocator,
    _: gateway_provider.CreditsLookupInput,
) output_contracts.CreditsSnapshot {
    return .{
        .notice = alloc.dupe(u8, no_gateway_balance_message) catch null,
    };
}

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    const result = model_catalog.fetchWithPublicFallback(.{ .fetch_fn = fetchModelCatalog }, alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    });
    return switch (result) {
        .loaded => |loaded| blk: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch break :blk .{
                .failure = .{
                    .access = loaded.provenance.access,
                    .anonymous_fallback_used = loaded.provenance.anonymous_fallback_used,
                    .failure = .{ .category = .resource_exhausted },
                },
            };
            break :blk .{ .loaded = .{
                .ids = ids,
                .provenance = loaded.provenance,
            } };
        },
        .failed => |failed| .{ .failure = failed },
    };
}

fn fetchModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    return fetchModelCatalogWith(alloc, currentResolved(), input);
}

fn fetchModelCatalogWith(
    alloc: Allocator,
    resolved: providers_config.Resolved,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    if (input.cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    }

    // Prefer the remembered OpenAI-compatible /v1/models URL. The leftover
    // AI Gateway path in `input.endpoint` is not a model catalog for this backend.
    const models_url = resolved.modelsUrlAlloc(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer if (models_url) |url| alloc.free(url);
    const url = models_url orelse return .{ .failure = .{ .category = .runtime } };

    const api_key = resolved.loadApiKey(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer if (api_key) |key| secret.zeroAndFree(alloc, key);
    const key = api_key orelse return .{ .failure = .{ .category = .runtime } };

    var ids = openai_compatible.fetchModelIds(alloc, key, url, &.{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = catalogRequestFailure(err) };
    };
    return .{ .catalog = try catalogFromIds(alloc, &ids) };
}

fn catalogFromIds(
    alloc: Allocator,
    ids: *std.ArrayList([]u8),
) Allocator.Error!std.ArrayList(model_catalog.ModelCatalogEntry) {
    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    var consumed: usize = 0;
    defer {
        for (ids.items[consumed..]) |id| alloc.free(id);
        ids.deinit(alloc);
        ids.* = .empty;
    }
    try catalog.ensureTotalCapacity(alloc, ids.items.len);
    for (ids.items) |id| {
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
        });
        consumed += 1;
    }
    return catalog;
}

fn catalogRequestFailure(err: anyerror) model_catalog.Failure {
    return switch (err) {
        error.Cancelled => .{ .category = .cancellation },
        error.MalformedResponse => .{ .category = .malformed_response },
        error.Unavailable => .{ .category = .runtime },
        else => .{ .category = .transport, .retryable = true },
    };
}

test "openai-compatible credits never claim a gateway balance" {
    var snapshot = fetchCredits(null, std.testing.allocator, .{ .credential = null, .tenant = null });
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(no_gateway_balance_message, snapshot.notice.?);
    try std.testing.expect(snapshot.balance == null);
    try std.testing.expect(snapshot.err_message == null);
}

test "openai-compatible catalog converts advertised ids into picker entries" {
    const alloc = std.testing.allocator;
    var ids: std.ArrayList([]u8) = .empty;
    try ids.append(alloc, try alloc.dupe(u8, "grok-4.6"));
    try ids.append(alloc, try alloc.dupe(u8, "gpt-4.1"));
    var catalog = try catalogFromIds(alloc, &ids);
    defer model_catalog.freeModelCatalog(alloc, &catalog);
    try std.testing.expectEqual(@as(usize, 0), ids.items.len);
    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqualStrings("grok-4.6", catalog.items[0].id);
    try std.testing.expectEqualStrings("language", catalog.items[0].model_type);
    try std.testing.expectEqualStrings("gpt-4.1", catalog.items[1].id);
    try std.testing.expectEqualStrings("language", catalog.items[1].model_type);
}

test "openai-compatible catalog ignores leftover AI Gateway model paths" {
    const result = try fetchModelCatalogWith(std.testing.allocator, .{}, .{
        .endpoint = "/coding-agent/v1/models",
    });
    switch (result) {
        .failure => |failure| try std.testing.expectEqual(model_catalog.FailureCategory.runtime, failure.category),
        .catalog => |catalog| {
            var owned = catalog;
            model_catalog.freeModelCatalog(std.testing.allocator, &owned);
            return error.TestExpectedEqual;
        },
    }
}

test "openai-compatible catalog reports cancellation before contacting a host" {
    var cancel_flag = std.atomic.Value(bool).init(true);
    const result = try fetchModelCatalogWith(std.testing.allocator, .{
        .openai_compatible = .{ .base_url = "http://127.0.0.1:1/v1" },
        .openai_api_key_present = true,
    }, .{
        .endpoint = "/coding-agent/v1/models",
        .cancel_flag = &cancel_flag,
    });
    switch (result) {
        .failure => |failure| try std.testing.expectEqual(model_catalog.FailureCategory.cancellation, failure.category),
        .catalog => |catalog| {
            var owned = catalog;
            model_catalog.freeModelCatalog(std.testing.allocator, &owned);
            return error.TestExpectedEqual;
        },
    }
}
