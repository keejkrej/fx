const gateway_provider = @import("../gateway/gateway_provider.zig");

/// Agent traffic is OpenAI-compatible Chat Completions only. Vercel remains on
/// the composed provider for leftover OAuth/login surfaces, not for models.
pub const Context = struct {
    vercel: gateway_provider.Provider,
    openai_compatible: gateway_provider.Provider,
};

pub fn provider(context: *const Context) gateway_provider.Provider {
    return .{
        .agent_stream = context.openai_compatible.agent_stream,
        .oauth_transport = context.vercel.oauth_transport,
        .chat_url = context.openai_compatible.chat_url,
        .cli_model_catalog = context.openai_compatible.cli_model_catalog,
        .credits = context.openai_compatible.credits,
        .generation_usage = context.openai_compatible.generation_usage,
        .web_search = context.openai_compatible.web_search,
        .model_catalog = context.openai_compatible.model_catalog,
    };
}
