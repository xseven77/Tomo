use serde::{Deserialize, Serialize};

/// Request format for POST /v1/responses
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OpenAiResponsesRequest {
    pub model: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub instructions: Option<String>,
    #[serde(default)]
    pub input: Vec<ResponsesInputItem>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Vec<ResponsesToolDefinition>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_choice: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stream: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ResponsesInputItem {
    #[serde(rename = "message")]
    Message(ResponsesMessageItem),
    #[serde(rename = "function_call")]
    FunctionCall(ResponsesFunctionCallItem),
    #[serde(rename = "function_call_output")]
    FunctionCallOutput(ResponsesFunctionCallOutputItem),
    #[serde(rename = "reasoning")]
    Reasoning(ResponsesReasoningItem),
    #[serde(rename = "additional_tools")]
    AdditionalTools(ResponsesAdditionalToolsItem),
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResponsesAdditionalToolsItem {
    #[serde(default)]
    pub tools: Vec<serde_json::Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResponsesMessageItem {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub role: String,
    pub content: Vec<ResponsesContentPart>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ResponsesContentPart {
    #[serde(rename = "input_text")]
    InputText { text: String },
    #[serde(rename = "output_text")]
    OutputText { text: String },
    #[serde(rename = "text")]
    Text { text: String },
}

impl ResponsesContentPart {
    pub fn text(&self) -> &str {
        match self {
            Self::InputText { text } | Self::OutputText { text } | Self::Text { text } => text,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResponsesFunctionCallItem {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub call_id: String,
    pub name: String,
    pub arguments: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResponsesFunctionCallOutputItem {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub call_id: String,
    pub output: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResponsesReasoningItem {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub summary: Option<String>,
    pub signature: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResponsesToolDefinition {
    #[serde(rename = "type")]
    pub kind: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    pub parameters: serde_json::Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub strict: Option<bool>,
}

/// Non-streaming response payload
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OpenAiResponsesPayload {
    pub id: String,
    pub object: String,
    pub status: String,
    pub model: String,
    pub output: Vec<ResponsesOutputItem>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage: Option<ResponsesUsage>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ResponsesOutputItem {
    #[serde(rename = "message")]
    Message {
        id: String,
        role: String,
        content: Vec<ResponsesContentPart>,
    },
    #[serde(rename = "function_call")]
    FunctionCall {
        id: String,
        call_id: String,
        name: String,
        arguments: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResponsesUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub total_tokens: u64,
}
