pub mod decoder;
pub mod encoder;
pub mod schema;

pub use decoder::decode_anthropic_request;
pub use encoder::encode_anthropic_stream_event;
pub use schema::{AnthropicMessagesRequest, AnthropicMessage, AnthropicTool};

#[cfg(test)]
mod tests {
    use super::*;
    use gateway_ir::{ContentBlock, FinishReason, InputItem, Role};
    use gateway_stream::event::{ResponseCompleted, ResponseStarted, TextDelta};
    use gateway_stream::StreamEvent;

    #[test]
    fn test_decode_anthropic_messages_request() {
        let json = r#"{
            "model": "coding-smart",
            "system": "You are Claude acting as Tomo assistant.",
            "max_tokens": 2048,
            "messages": [
                {
                    "role": "user",
                    "content": "Please inspect main.rs"
                },
                {
                    "role": "assistant",
                    "content": [
                        {
                            "type": "tool_use",
                            "id": "toolu_01",
                            "name": "view_file",
                            "input": {"path": "src/main.rs"}
                        }
                    ]
                },
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "tool_result",
                            "tool_use_id": "toolu_01",
                            "content": "fn main() {}"
                        }
                    ]
                }
            ],
            "tools": [
                {
                    "name": "view_file",
                    "description": "View file content",
                    "input_schema": {
                        "type": "object",
                        "properties": {"path": {"type": "string"}}
                    }
                }
            ],
            "stream": true
        }"#;

        let raw: AnthropicMessagesRequest = serde_json::from_str(json).unwrap();
        let res = decode_anthropic_request(raw, "req_claude_01");

        assert_eq!(res.fidelity, gateway_ir::Fidelity::Native);
        let req = res.value;
        assert_eq!(req.request_id, "req_claude_01");
        assert_eq!(req.model.raw_name(), "coding-smart");
        assert_eq!(req.instructions.len(), 1);
        assert_eq!(req.instructions[0], "You are Claude acting as Tomo assistant.");
        assert_eq!(req.generation.max_output_tokens, Some(2048));
        assert_eq!(req.stream, true);
        assert_eq!(req.tools.len(), 1);
        assert_eq!(req.tools[0].name, "view_file");

        // Verify items
        assert_eq!(req.items.len(), 3);
        match &req.items[0] {
            InputItem::Message(m) => {
                assert_eq!(m.role, Role::User);
                match &m.content[0] {
                    ContentBlock::Text(t) => assert_eq!(t.text, "Please inspect main.rs"),
                    _ => panic!("Expected text block"),
                }
            }
            _ => panic!("Expected message"),
        }

        match &req.items[1] {
            InputItem::Message(m) => {
                assert_eq!(m.role, Role::Assistant);
                match &m.content[0] {
                    ContentBlock::ToolCall(tc) => {
                        assert_eq!(tc.id, "toolu_01");
                        assert_eq!(tc.name, "view_file");
                        assert!(tc.arguments.contains("src/main.rs"));
                    }
                    _ => panic!("Expected tool call block"),
                }
            }
            _ => panic!("Expected message"),
        }

        match &req.items[2] {
            InputItem::ToolResult(tr) => {
                assert_eq!(tr.call_id, "toolu_01");
                assert_eq!(tr.output, "fn main() {}");
            }
            _ => panic!("Expected tool result"),
        }
    }

    #[test]
    fn test_encode_anthropic_sse_stream() {
        let resp_id = "msg_01";
        let model = "claude-3-7-sonnet";

        let ev1 = StreamEvent::ResponseStarted(ResponseStarted {
            sequence: 1,
            response_id: resp_id.into(),
            model: model.into(),
            created_at: 1724900000,
        });
        let chunks1 = encode_anthropic_stream_event(&ev1, resp_id, model);
        assert_eq!(chunks1.len(), 2);
        assert!(chunks1[0].starts_with("event: message_start\n"));
        assert!(chunks1[1].starts_with("event: content_block_start\n"));

        let ev2 = StreamEvent::TextDelta(TextDelta {
            sequence: 2,
            item_id: "block_0".into(),
            text: "Hello Claude Code".into(),
        });
        let chunks2 = encode_anthropic_stream_event(&ev2, resp_id, model);
        assert_eq!(chunks2.len(), 1);
        assert!(chunks2[0].starts_with("event: content_block_delta\n"));
        assert!(chunks2[0].contains("Hello Claude Code"));

        let ev3 = StreamEvent::ResponseCompleted(ResponseCompleted {
            sequence: 3,
            finish_reason: FinishReason::Stop,
        });
        let chunks3 = encode_anthropic_stream_event(&ev3, resp_id, model);
        assert_eq!(chunks3.len(), 3);
        assert!(chunks3[0].starts_with("event: content_block_stop\n"));
        assert!(chunks3[1].starts_with("event: message_delta\n"));
        assert!(chunks3[2].starts_with("event: message_stop\n"));
    }

    #[test]
    fn test_decode_anthropic_thinking() {
        let json_disabled = r#"{
            "model": "claude-3-7-sonnet",
            "max_tokens": 1024,
            "messages": [{"role": "user", "content": "hi"}],
            "thinking": {"type": "disabled"}
        }"#;
        let raw1: AnthropicMessagesRequest = serde_json::from_str(json_disabled).unwrap();
        let res1 = decode_anthropic_request(raw1, "req1");
        assert_eq!(res1.value.generation.reasoning_effort.as_deref(), Some("none"));

        let json_enabled = r#"{
            "model": "claude-3-7-sonnet",
            "max_tokens": 4096,
            "messages": [{"role": "user", "content": "hi"}],
            "thinking": {"type": "enabled", "budget_tokens": 2048}
        }"#;
        let raw2: AnthropicMessagesRequest = serde_json::from_str(json_enabled).unwrap();
        let res2 = decode_anthropic_request(raw2, "req2");
        assert_eq!(res2.value.generation.reasoning_effort.as_deref(), Some("2048"));
    }
}

