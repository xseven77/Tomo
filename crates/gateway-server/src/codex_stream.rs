//! Stateful Responses -> Chat conversion, including tool-only turns.
use serde_json::{json, Value};

#[derive(Default)]
pub(crate) struct CodexStream {
    pub text: String,
    pub calls: Vec<Value>,
    item_ids: Vec<String>,
    pub completed: bool,
    pub error: Option<String>,
    pub usage: Value,
}
impl CodexStream {
    fn call(&mut self, item: &Value) -> (usize, bool) {
        let id = item["id"]
            .as_str()
            .or_else(|| item["call_id"].as_str())
            .unwrap_or("");
        if let Some(i) = self.item_ids.iter().position(|v| v == id) {
            return (i, false);
        }
        let i = self.calls.len();
        self.item_ids.push(id.into());
        self.calls.push(json!({"index":i,"id":item["call_id"],"type":"function","function":{"name":item["name"],"arguments":""}}));
        (i, true)
    }
    fn output_item(&mut self, item: &Value, deltas: &mut Vec<Value>) {
        if item["type"] == "function_call" {
            let (i, new) = self.call(item);
            if new {
                deltas.push(json!({"tool_calls":[self.calls[i].clone()]}));
            }
            let old = self.calls[i]["function"]["arguments"]
                .as_str()
                .unwrap_or("");
            let full = item["arguments"].as_str().unwrap_or("");
            if let Some(rest) = full.strip_prefix(old).filter(|s| !s.is_empty()) {
                deltas.push(json!({"tool_calls":[{"index":i,"function":{"arguments":rest}}]}));
                self.calls[i]["function"]["arguments"] = json!(full);
            }
        }
    }
    pub fn consume(&mut self, event: &Value) -> Vec<Value> {
        let mut deltas = Vec::new();
        match event["type"].as_str().unwrap_or("") {
            "response.output_text.delta" => {
                if let Some(s) = event["delta"].as_str() {
                    self.text.push_str(s);
                    deltas.push(json!({"content":s}));
                }
            }
            "response.output_item.added" | "response.output_item.done" => {
                self.output_item(&event["item"], &mut deltas)
            }
            "response.function_call_arguments.delta" => {
                if let Some(i) = self
                    .item_ids
                    .iter()
                    .position(|id| Some(id.as_str()) == event["item_id"].as_str())
                {
                    let delta = event["delta"].as_str().unwrap_or("");
                    let old = self.calls[i]["function"]["arguments"]
                        .as_str()
                        .unwrap_or("");
                    self.calls[i]["function"]["arguments"] = json!(format!("{old}{delta}"));
                    deltas.push(json!({"tool_calls":[{"index":i,"function":{"arguments":delta}}]}));
                }
            }
            "response.completed" => {
                self.completed = true;
                self.usage = event["response"]["usage"].clone();
                if let Some(items) = event["response"]["output"].as_array() {
                    let mut full_text = String::new();
                    for item in items {
                        self.output_item(item, &mut deltas);
                        if let Some(parts) = item["content"].as_array() {
                            for p in parts {
                                if p["type"] == "output_text" {
                                    full_text.push_str(p["text"].as_str().unwrap_or(""));
                                }
                            }
                        }
                    }
                    if let Some(rest) = full_text.strip_prefix(&self.text).filter(|s| !s.is_empty())
                    {
                        deltas.push(json!({"content":rest}));
                        self.text = full_text;
                    }
                }
            }
            "response.failed" | "error" | "response.incomplete" => {
                self.error = Some(
                    event
                        .pointer("/response/error/message")
                        .or_else(|| event.pointer("/error/message"))
                        .or_else(|| event.get("message"))
                        .and_then(Value::as_str)
                        .unwrap_or("ChatGPT upstream response failed or was incomplete")
                        .into(),
                );
            }
            _ => {}
        }
        deltas
    }
    pub fn failure(&self) -> Option<String> {
        self.error.clone().or_else(|| {
            if !self.completed {
                Some("ChatGPT upstream stream closed before response.completed".into())
            } else if self.text.is_empty() && self.calls.is_empty() {
                Some("ChatGPT upstream returned no text or tool calls".into())
            } else {
                None
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn tool_only_turn_keeps_parallel_calls_and_split_arguments() {
        let mut s = CodexStream::default();
        for (i, name) in [(0, "read_file"), (1, "list_files")] {
            let chunks=s.consume(&json!({"type":"response.output_item.added","item":{"type":"function_call","id":format!("fc{i}"),"call_id":format!("call{i}"),"name":name,"arguments":""}}));
            assert_eq!(chunks[0]["tool_calls"][0]["index"], i);
            for delta in ["{\"path\":", "\"/tmp\"}"] {
                s.consume(&json!({"type":"response.function_call_arguments.delta","item_id":format!("fc{i}"),"delta":delta}));
            }
            // Final item must not duplicate arguments already emitted as deltas.
            assert!(s.consume(&json!({"type":"response.output_item.done","item":{"type":"function_call","id":format!("fc{i}"),"call_id":format!("call{i}"),"name":name,"arguments":"{\"path\":\"/tmp\"}"}})).is_empty());
        }
        s.consume(&json!({"type":"response.completed","response":{"output":[],"usage":{"input_tokens":20,"output_tokens":10}}}));
        assert_eq!(s.failure(), None);
        assert!(s.text.is_empty());
        assert_eq!(s.calls.len(), 2);
        assert_eq!(s.calls[1]["function"]["arguments"], "{\"path\":\"/tmp\"}");
    }
    #[test]
    fn terminal_output_fallback_and_failure_are_not_empty_success() {
        let mut s = CodexStream::default();
        assert!(s.failure().unwrap().contains("before response.completed"));
        let chunks=s.consume(&json!({"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"你好"}]}]}}));
        assert_eq!(chunks[0]["content"], "你好");
        assert!(s.failure().is_none());
        let mut failed = CodexStream::default();
        failed.consume(
            &json!({"type":"response.failed","response":{"error":{"message":"quota exhausted"}}}),
        );
        assert_eq!(failed.failure().as_deref(), Some("quota exhausted"));
        let mut empty = CodexStream::default();
        empty.consume(&json!({"type":"response.completed","response":{"output":[]}}));
        assert!(empty.failure().unwrap().contains("no text or tool calls"));
    }
}
