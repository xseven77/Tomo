use gateway_ir::{
    CanonicalRequest, ContentBlock, InputItem, Message, ModelSelector, ReasoningBlock, Role,
    ToolCall, ToolChoice, ToolDefinition, ToolResult, TranslationResult,
};
use crate::schema::{OpenAiResponsesRequest, ResponsesInputItem};

pub fn decode_responses_request(
    raw: OpenAiResponsesRequest,
    request_id: impl Into<String>,
) -> TranslationResult<CanonicalRequest> {
    let model = if raw.model.contains('/') {
        let parts: Vec<&str> = raw.model.splitn(2, '/').collect();
        ModelSelector::exact(parts[0], parts[1])
    } else {
        ModelSelector::alias(raw.model)
    };

    let mut canonical = CanonicalRequest::new(request_id, model);
    canonical.stream = raw.stream.unwrap_or(false);

    if let Some(instructions) = raw.instructions {
        canonical.instructions.push(instructions);
    }

    canonical.generation.temperature = raw.temperature;
    canonical.generation.max_output_tokens = raw.max_output_tokens;

    // Tools
    if let Some(tools) = raw.tools {
        for tool in tools {
            let mut def = ToolDefinition::new(tool.name, tool.parameters);
            if let Some(desc) = tool.description {
                def = def.with_description(desc);
            }
            if let Some(strict) = tool.strict {
                def = def.with_strict(strict);
            }
            canonical.tools.push(def);
        }
    }

    // Tool Choice
    if let Some(tc) = raw.tool_choice {
        canonical.tool_choice = match tc {
            serde_json::Value::String(ref s) if s == "none" => ToolChoice::None,
            serde_json::Value::String(ref s) if s == "required" => ToolChoice::Required,
            serde_json::Value::String(ref s) if s == "auto" => ToolChoice::Auto,
            serde_json::Value::Object(ref obj) => {
                if let Some(name) = obj.get("name").and_then(|n| n.as_str()) {
                    ToolChoice::Specific(name.to_string())
                } else {
                    ToolChoice::Auto
                }
            }
            _ => ToolChoice::Auto,
        };
    }

    // Input items
    for item in raw.input {
        match item {
            ResponsesInputItem::Message(msg) => {
                let role = match msg.role.as_str() {
                    "user" => Role::User,
                    "assistant" => Role::Assistant,
                    "system" => Role::System,
                    "developer" => Role::Developer,
                    _ => Role::User,
                };
                let content: Vec<ContentBlock> = msg
                    .content
                    .into_iter()
                    .map(|p| ContentBlock::text(p.text().to_string()))
                    .collect();
                let mut message = Message::new(role, content);
                if let Some(id) = msg.id {
                    message = message.with_id(id);
                }
                canonical.items.push(InputItem::from_message(message));
            }
            ResponsesInputItem::FunctionCall(fc) => {
                let mut msg = Message::new(
                    Role::Assistant,
                    vec![ContentBlock::tool_call(ToolCall::new(
                        fc.call_id,
                        fc.name,
                        fc.arguments,
                    ))],
                );
                if let Some(id) = fc.id {
                    msg = msg.with_id(id);
                }
                canonical.items.push(InputItem::from_message(msg));
            }
            ResponsesInputItem::FunctionCallOutput(fco) => {
                canonical
                    .items
                    .push(InputItem::ToolResult(ToolResult::success(fco.call_id, fco.output)));
            }
            ResponsesInputItem::Reasoning(r) => {
                let mut block = ReasoningBlock::new(r.summary.unwrap_or_default());
                if let Some(sig) = r.signature {
                    block = block.with_signature(sig);
                }
                let mut msg = Message::new(Role::Assistant, vec![ContentBlock::reasoning(block)]);
                if let Some(id) = r.id {
                    msg = msg.with_id(id);
                }
                canonical.items.push(InputItem::from_message(msg));
            }
            ResponsesInputItem::AdditionalTools(_) | ResponsesInputItem::Unknown => {
                // Ignore or handle additional_tools and other auxiliary input items gracefully
            }
        }
    }

    TranslationResult::native(canonical)
}
