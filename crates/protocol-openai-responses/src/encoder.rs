use gateway_ir::{CanonicalResponse, ContentBlock};
use gateway_stream::StreamEvent;
use crate::schema::{
    OpenAiResponsesPayload, ResponsesContentPart, ResponsesOutputItem, ResponsesUsage,
};

pub fn encode_responses_payload(resp: &CanonicalResponse) -> OpenAiResponsesPayload {
    let mut output = Vec::new();

    for (index, item) in resp.items.iter().enumerate() {
        match item {
            ContentBlock::Text(t) => {
                output.push(ResponsesOutputItem::Message {
                    id: format!("msg_{}_{index}", resp.response_id.trim_start_matches("resp_")),
                    role: "assistant".into(),
                    content: vec![ResponsesContentPart::OutputText {
                        text: t.text.clone(),
                    }],
                });
            }
            ContentBlock::ToolCall(tc) => {
                output.push(ResponsesOutputItem::FunctionCall {
                    id: format!("fc_{}_{index}", resp.response_id.trim_start_matches("resp_")),
                    call_id: tc.id.clone(),
                    name: tc.name.clone(),
                    arguments: tc.arguments.clone(),
                });
            }
            _ => {}
        }
    }

    let usage = resp.usage.map(|u| ResponsesUsage {
        input_tokens: u.input_tokens,
        output_tokens: u.output_tokens,
        total_tokens: u.input_tokens + u.output_tokens,
    });

    OpenAiResponsesPayload {
        id: resp.response_id.clone(),
        object: "response".into(),
        status: "completed".into(),
        model: resp.model.clone(),
        output,
        usage,
    }
}

/// Formats a canonical StreamEvent into OpenAI Responses wire API SSE events.
pub fn encode_responses_stream_event(
    event: &StreamEvent,
    response_id: &str,
    model: &str,
) -> Vec<String> {
    let mut chunks = Vec::new();

    match event {
        StreamEvent::ResponseStarted(e) => {
            let payload = serde_json::json!({
                "response": {
                    "id": response_id,
                    "object": "response",
                    "status": "in_progress",
                    "model": model,
                    "created_at": e.created_at
                }
            });
            chunks.push(format!("event: response.created\ndata: {payload}\n\n"));
        }
        StreamEvent::ItemStarted(e) => {
            let role_str = match e.role {
                Some(gateway_ir::Role::Assistant) => "assistant",
                Some(gateway_ir::Role::User) => "user",
                Some(gateway_ir::Role::System) => "system",
                Some(gateway_ir::Role::Developer) => "developer",
                _ => "assistant",
            };
            let payload = serde_json::json!({
                "response_id": response_id,
                "output_index": e.index,
                "item": {
                    "id": e.item_id,
                    "type": "message",
                    "status": "in_progress",
                    "role": role_str,
                    "content": []
                }
            });
            chunks.push(format!("event: response.output_item.added\ndata: {payload}\n\n"));

            let part = serde_json::json!({
                "response_id": response_id,
                "item_id": e.item_id,
                "output_index": e.index,
                "content_index": 0,
                "part": {
                    "type": "output_text",
                    "text": ""
                }
            });
            chunks.push(format!("event: response.content_part.added\ndata: {part}\n\n"));
        }
        StreamEvent::TextDelta(t) => {
            let payload = serde_json::json!({
                "response_id": response_id,
                "item_id": t.item_id,
                "output_index": 0,
                "content_index": 0,
                "delta": t.text
            });
            chunks.push(format!("event: response.output_text.delta\ndata: {payload}\n\n"));
        }
        StreamEvent::ToolCallStarted(tc) => {
            let payload = serde_json::json!({
                "response_id": response_id,
                "output_index": tc.index,
                "item": {
                    "id": tc.item_id,
                    "type": "function_call",
                    "status": "in_progress",
                    "call_id": tc.call_id,
                    "name": tc.name,
                    "arguments": ""
                }
            });
            chunks.push(format!("event: response.output_item.added\ndata: {payload}\n\n"));
        }
        StreamEvent::ToolArgumentsDelta(args) => {
            let payload = serde_json::json!({
                "response_id": response_id,
                "call_id": args.call_id,
                "delta": args.delta
            });
            chunks.push(format!("event: response.function_call_arguments.delta\ndata: {payload}\n\n"));
        }
        StreamEvent::ToolCallCompleted(tc) => {
            let payload = serde_json::json!({
                "response_id": response_id,
                "call_id": tc.call_id,
                "item": {
                    "status": "completed",
                    "name": tc.name,
                    "arguments": tc.arguments
                }
            });
            chunks.push(format!("event: response.output_item.done\ndata: {payload}\n\n"));
        }
        StreamEvent::ItemCompleted(e) => {
            let payload = serde_json::json!({
                "response_id": response_id,
                "item": {
                    "id": e.item_id,
                    "status": "completed"
                }
            });
            chunks.push(format!("event: response.output_item.done\ndata: {payload}\n\n"));
        }
        StreamEvent::ResponseCompleted(_) => {
            let payload = serde_json::json!({
                "response": {
                    "id": response_id,
                    "status": "completed"
                }
            });
            chunks.push(format!("event: response.completed\ndata: {payload}\n\n"));
        }
        StreamEvent::ResponseFailed(err) => {
            let payload = serde_json::json!({
                "response": {
                    "id": response_id,
                    "status": "failed",
                    "error": {
                        "code": err.code,
                        "message": err.message
                    }
                }
            });
            chunks.push(format!("event: response.failed\ndata: {payload}\n\n"));
        }
        _ => {}
    }

    chunks
}
