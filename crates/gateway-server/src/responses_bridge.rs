//! Responses ingress over the real upstream router. Native Responses events are
//! passed through; Chat Completions providers are translated incrementally.
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::io::{self, Write};

pub(crate) trait ProxyOutput: Write {
    fn responses_event(&mut self, _event: &Value) -> io::Result<bool> {
        Ok(false)
    }
}
impl ProxyOutput for std::net::TcpStream {}
impl ProxyOutput for Vec<u8> {}

#[derive(Clone)]
struct ToolIdentity {
    name: String,
    namespace: Option<String>,
    custom: bool,
    search: bool,
    local_kind: Option<&'static str>,
}

impl ToolIdentity {
    fn from_item(item: &Value) -> Self {
        let search = matches!(
            item["type"].as_str(),
            Some("tool_search" | "tool_search_call")
        );
        let local_kind = match item["type"].as_str() {
            Some("local_shell" | "local_shell_call") => Some("local_shell"),
            Some("shell" | "shell_call") => Some("shell"),
            Some("apply_patch" | "apply_patch_call") => Some("apply_patch"),
            _ => None,
        };
        Self {
            name: if let Some(kind) = local_kind {
                kind.into()
            } else if search {
                "tool_search".into()
            } else {
                item["name"].as_str().unwrap_or("").to_owned()
            },
            namespace: item["namespace"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(str::to_owned),
            custom: matches!(item["type"].as_str(), Some("custom" | "custom_tool_call")),
            search,
            local_kind,
        }
    }

    fn wire_name(&self) -> String {
        // Chat providers require short, flat function names. Reserve our prefix
        // so a top-level function cannot collide with a flattened namespace.
        if !self.search
            && self.local_kind.is_none()
            && self.namespace.is_none()
            && !self.name.starts_with("tomo_ns_")
            && self.name.len() <= 64
            && self
                .name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
        {
            return self.name.clone();
        }
        // Stable across requests and tool-list reordering, including replayed
        // calls whose tool definition is no longer in the current tools list.
        let mut identity = format!(
            "{}\0{}\0{}",
            self.namespace.as_deref().unwrap_or(""),
            self.name,
            self.search
        );
        if let Some(kind) = self.local_kind {
            identity.push_str(&format!("\0{kind}"));
        }
        let hash = identity.bytes().fold(0xcbf29ce484222325_u64, |hash, byte| {
            (hash ^ u64::from(byte)).wrapping_mul(0x100000001b3)
        });
        let readable: String = self
            .name
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                    c
                } else {
                    '_'
                }
            })
            .take(39)
            .collect();
        format!("tomo_ns_{hash:016x}_{readable}")
    }

    fn restore(&self, item: &mut Value) {
        item["name"] = json!(self.name);
        if let Some(namespace) = &self.namespace {
            item["namespace"] = json!(namespace);
        }
    }

    fn buffered(&self) -> bool {
        self.custom || self.search || self.local_kind.is_some()
    }
}

// These tools are executed by the Responses client, never by the gateway.
// Keep their structured payloads so the client's approvals and sandbox apply.
fn local_tool_parameters(kind: &str) -> Value {
    let (key, schema) = match kind {
        "local_shell" => (
            "action",
            json!({"type":"object","properties":{
            "type":{"type":"string","enum":["exec"]},
            "command":{"type":"array","items":{"type":"string"},"minItems":1},
            "env":{"type":"object","additionalProperties":{"type":"string"}},
            "timeout_ms":{"type":"integer"},"user":{"type":"string"},"working_directory":{"type":"string"}
        },"required":["type","command","env"],"additionalProperties":false}),
        ),
        "shell" => (
            "action",
            json!({"type":"object","properties":{
            "commands":{"type":"array","items":{"type":"string"},"minItems":1},
            "timeout_ms":{"type":"integer"},"max_output_length":{"type":"integer"}
        },"required":["commands"],"additionalProperties":false}),
        ),
        _ => (
            "operation",
            json!({"type":"object","properties":{
            "type":{"type":"string","enum":["create_file","update_file","delete_file"]},
            "path":{"type":"string"},"diff":{"type":"string","description":"Patch diff; required for create_file and update_file"}
        },"required":["type","path"],"additionalProperties":false}),
        ),
    };
    json!({"type":"object","properties":{(key):schema},"required":[key],"additionalProperties":false})
}

fn nonempty_strings(value: &Value) -> bool {
    value
        .as_array()
        .is_some_and(|items| !items.is_empty() && items.iter().all(Value::is_string))
}

#[derive(Default)]
struct ToolCatalog {
    declarations: Vec<Value>,
    identities: BTreeMap<String, ToolIdentity>,
    unavailable: BTreeSet<String>,
}

impl ToolCatalog {
    fn from_request(raw: &Value) -> Result<Self, String> {
        let mut catalog = Self::default();
        if let Some(tools) = raw["tools"].as_array() {
            catalog.add(tools, None, "", 0)?;
        }
        // Codex can load more tools in the middle of a conversation.
        for item in raw["input"].as_array().into_iter().flatten() {
            if matches!(
                item["type"].as_str(),
                Some("additional_tools" | "tool_search_output")
            ) {
                if let Some(tools) = item["tools"].as_array() {
                    catalog.add(tools, None, "", 0)?;
                }
            }
        }
        Ok(catalog)
    }

    fn add(
        &mut self,
        tools: &[Value],
        namespace: Option<&str>,
        group_description: &str,
        depth: usize,
    ) -> Result<(), String> {
        if depth > 16 {
            return Err("Tool namespace nesting is too deep".into());
        }
        for tool in tools {
            let kind = tool["type"].as_str().unwrap_or("");
            if kind == "namespace" {
                let name = tool["name"]
                    .as_str()
                    .filter(|n| !n.is_empty())
                    .ok_or("Tool namespace name is required")?;
                let path = namespace
                    .map(|parent| format!("{parent}.{name}"))
                    .unwrap_or_else(|| name.to_owned());
                let children = tool["tools"]
                    .as_array()
                    .ok_or("Tool namespace tools must be an array")?;
                self.add(
                    children,
                    Some(&path),
                    tool["description"].as_str().unwrap_or(""),
                    depth + 1,
                )?;
                continue;
            }
            // Hosted search only selects from the declarations already supplied.
            // Chat providers receive those declarations eagerly. Client search
            // remains a callable tool so Codex can load missing tools itself.
            if kind == "tool_search" && tool["execution"] != "client" {
                continue;
            }
            if kind.is_empty() {
                return Err("Tool type is required".into());
            }
            let local_tool = matches!(kind, "local_shell" | "apply_patch")
                || (kind == "shell"
                    && tool.pointer("/environment/type").and_then(Value::as_str) == Some("local"));
            if !matches!(kind, "function" | "custom" | "tool_search") && !local_tool {
                // A declaration advertises an optional capability; it is not a
                // request to execute it. Chat endpoints cannot run Responses
                // hosted tools. Omit them (including future types) without
                // rejecting ordinary turns or inventing client-side executors.
                self.unavailable.insert(kind.to_owned());
                continue;
            }
            let mut identity = ToolIdentity::from_item(tool);
            if let Some(namespace) = namespace {
                identity.namespace = Some(namespace.into());
            }
            if identity.name.is_empty() {
                return Err("Tool name is required".into());
            }
            let wire_name = identity.wire_name();
            if let Some(existing) = self.identities.get(&wire_name) {
                if existing.namespace != identity.namespace
                    || existing.name != identity.name
                    || existing.custom != identity.custom
                    || existing.search != identity.search
                    || existing.local_kind != identity.local_kind
                {
                    return Err("Conflicting tool identities after namespace conversion".into());
                }
            }
            let mut function = if let Some(kind) = identity.local_kind {
                json!({"parameters":local_tool_parameters(kind)})
            } else if identity.custom {
                json!({"parameters":{"type":"object","properties":{"input":{"type":"string","description":"The complete raw input for this tool"}},"required":["input"],"additionalProperties":false}})
            } else {
                let mut f = json!({});
                for key in ["parameters", "strict"] {
                    if let Some(value) = tool.get(key) {
                        f[key] = value.clone();
                    }
                }
                f
            };
            function["name"] = json!(wire_name);
            let description = tool["description"].as_str().unwrap_or(match identity.local_kind {
                Some("local_shell" | "shell") => "Request shell execution in the client's local environment. The client handles approval and execution.",
                Some("apply_patch") => "Request a file change in the client's workspace. Supply a patch operation; the client handles approval and execution.",
                _ => "",
            });
            function["description"] = json!(if let Some(namespace) = &identity.namespace {
                format!(
                    "Namespace: {namespace}. {group_description}\nTool: {}. {description}",
                    identity.name
                )
            } else {
                description.to_owned()
            });
            if identity.custom {
                if let Some(format) = tool.get("format").filter(|f| f["type"] == "grammar") {
                    let description = function["description"].as_str().unwrap_or("");
                    function["description"] = json!(format!(
                        "{description}\nThe raw input must follow this format: {format}"
                    ));
                }
            }
            let declaration = json!({"type":"function","function":function});
            if let Some(previous) = self
                .declarations
                .iter_mut()
                .find(|d| d["function"]["name"] == wire_name)
            {
                // A deferred tool's loaded definition supersedes its stub.
                *previous = declaration;
            } else {
                self.declarations.push(declaration);
            }
            self.identities.insert(wire_name, identity);
        }
        Ok(())
    }

    fn matching_names(&self, selector: &Value) -> Vec<String> {
        if selector["type"] == "namespace" {
            let namespace = selector["name"].as_str().unwrap_or("");
            return self
                .identities
                .iter()
                .filter(|(_, identity)| {
                    identity
                        .namespace
                        .as_deref()
                        .is_some_and(|n| n == namespace || n.starts_with(&format!("{namespace}.")))
                })
                .map(|(name, _)| name.clone())
                .collect();
        }
        if !matches!(
            selector["type"].as_str(),
            Some("function" | "custom" | "tool_search" | "local_shell" | "shell" | "apply_patch")
        ) {
            return Vec::new();
        }
        let identity = ToolIdentity::from_item(selector);
        let name = identity.wire_name();
        self.identities
            .get(&name)
            .filter(|existing| {
                existing.custom == identity.custom
                    && existing.search == identity.search
                    && existing.local_kind == identity.local_kind
            })
            .map(|_| vec![name])
            .unwrap_or_default()
    }

    fn apply_choice(&mut self, choice: Option<&Value>) -> Result<Option<Value>, String> {
        let Some(choice) = choice.filter(|v| !v.is_null()) else {
            return Ok(None);
        };
        if let Some(mode) = choice.as_str() {
            return self.choice_mode(mode);
        }
        if choice["type"] == "allowed_tools" {
            let selectors = choice["tools"]
                .as_array()
                .ok_or("allowed_tools.tools must be an array")?;
            let allowed: BTreeSet<String> = selectors
                .iter()
                .flat_map(|selector| self.matching_names(selector))
                .collect();
            self.declarations.retain(|d| {
                d["function"]["name"]
                    .as_str()
                    .is_some_and(|n| allowed.contains(n))
            });
            return self.choice_mode(choice["mode"].as_str().unwrap_or("auto"));
        }
        let names = self.matching_names(choice);
        if names.is_empty() {
            return Err(format!(
                "The selected model cannot execute the explicitly requested tool {}. Select a native Responses model or choose an available client tool.",
                choice["name"].as_str().or(choice["type"].as_str()).unwrap_or("(unspecified)")
            ));
        }
        if choice["type"] == "namespace" {
            self.declarations
                .retain(|d| names.iter().any(|n| d["function"]["name"] == *n));
            return self.choice_mode("required");
        }
        Ok(Some(
            json!({"type":"function","function":{"name":names[0]}}),
        ))
    }

    fn choice_mode(&self, mode: &str) -> Result<Option<Value>, String> {
        match mode {
            "required" if self.declarations.is_empty() => Err(
                "tool_choice requires a tool, but the selected model has no available client tools. Select a native Responses model to use hosted tools.".into()),
            "auto" | "none" if self.declarations.is_empty() => Ok(None),
            "auto" | "none" | "required" => Ok(Some(json!(mode))),
            _ => Err(format!("Unsupported tool_choice mode: {mode}")),
        }
    }
}

pub(crate) fn chat_request(raw: &Value) -> Result<Value, String> {
    if raw
        .get("previous_response_id")
        .is_some_and(|v| !v.is_null())
        || raw.get("conversation").is_some_and(|v| !v.is_null())
    {
        return Err("This model requires the full conversation in input; provider-stored conversation references cannot be resolved across models.".into());
    }
    let mut catalog = ToolCatalog::from_request(raw)?;
    let tool_choice = catalog.apply_choice(raw.get("tool_choice"))?;
    let mut messages = Vec::new();
    if let Some(s) = raw.get("instructions").and_then(Value::as_str) {
        messages.push(json!({"role":"system","content":s}));
    }
    if !catalog.unavailable.is_empty() {
        let types: Vec<_> = catalog.unavailable.iter().collect();
        messages.push(json!({"role":"system","content":format!(
            "Gateway capability notice: these Responses tool types are unavailable on the selected model: {}. Only tools in the supplied function list can be called. Do not claim to have used an unavailable tool or fabricate its results. If the task needs an unavailable capability and no available tool can perform it, explain the limitation.",
            json!(types))}));
    }
    let input = match raw.get("input") {
        Some(Value::String(s)) => vec![json!({"role":"user","content":s})],
        Some(Value::Array(items)) => items.clone(),
        _ => return Err("Responses input must be a string or an array".into()),
    };
    let local_calls: BTreeSet<String> = input
        .iter()
        .filter(|item| {
            matches!(
                item["type"].as_str(),
                Some("local_shell_call" | "apply_patch_call")
            ) || (item["type"] == "shell_call"
                && catalog
                    .identities
                    .values()
                    .any(|i| i.local_kind == Some("shell")))
        })
        .filter_map(|item| item["call_id"].as_str().map(str::to_owned))
        .collect();
    for item in input {
        match item.get("type").and_then(Value::as_str).unwrap_or("message") {
            "message" => {
                let content = match item.get("content") {
                    Some(Value::Array(parts)) => Value::Array(parts.iter().filter_map(|p| {
                        match p["type"].as_str()? {
                            "input_text" | "output_text" | "text" => Some(json!({"type":"text","text":p["text"]})),
                            "input_image" => Some(json!({"type":"image_url","image_url":{"url":p["image_url"],"detail":p.get("detail").cloned().unwrap_or(json!("auto"))}})),
                            _ => None,
                        }
                    }).collect()),
                    Some(v) => v.clone(),
                    None => json!(""),
                };
                messages.push(json!({"role":item.get("role").cloned().unwrap_or(json!("user")),"content":content}));
            }
            "function_call" => messages.push(json!({"role":"assistant","content":null,"tool_calls":[{"id":item["call_id"],"type":"function","function":{"name":ToolIdentity::from_item(&item).wire_name(),"arguments":item["arguments"]}}]})),
            "custom_tool_call" => messages.push(json!({"role":"assistant","content":null,"tool_calls":[{"id":item["call_id"],"type":"function","function":{"name":ToolIdentity::from_item(&item).wire_name(),"arguments":json!({"input":item["input"]}).to_string()}}]})),
            "custom_tool_call_output" | "function_call_output" => messages.push(json!({"role":"tool","tool_call_id":item["call_id"],"content":item["output"].as_str().map(str::to_owned).unwrap_or_else(|| item["output"].to_string())})),
            "local_shell_call" | "shell_call" | "apply_patch_call"
                if item["call_id"].as_str().is_some_and(|id| local_calls.contains(id)) => {
                let key = if item["type"] == "apply_patch_call" { "operation" } else { "action" };
                messages.push(json!({"role":"assistant","content":null,"tool_calls":[{
                    "id":item["call_id"],"type":"function","function":{
                        "name":ToolIdentity::from_item(&item).wire_name(),
                        "arguments":json!({(key):item[key]}).to_string()
                    }
                }]}));
            }
            "local_shell_call_output" | "shell_call_output" | "apply_patch_call_output"
                if item.get("call_id").or_else(|| item.get("id")).and_then(Value::as_str).is_some_and(|id| local_calls.contains(id)) => {
                messages.push(json!({"role":"tool","tool_call_id":item.get("call_id").or_else(|| item.get("id")),
                    "content":json!({"status":item["status"],"output":item["output"]}).to_string()}));
            }
            "tool_search_call" => {
                if item["execution"] == "client" {
                    messages.push(json!({"role":"assistant","content":null,"tool_calls":[{"id":item["call_id"],"type":"function","function":{"name":ToolIdentity::from_item(&item).wire_name(),"arguments":item["arguments"].to_string()}}]}));
                }
            }
            "tool_search_output" => {
                if item["execution"] == "client" && item["call_id"].is_string() {
                    messages.push(json!({"role":"tool","tool_call_id":item["call_id"],"content":json!({"tools":item["tools"]}).to_string()}));
                }
            }
            // Native Codex receives the original input, including encrypted reasoning.
            "reasoning" | "additional_tools" => {},
            // Provider-owned calls from earlier turns are historical data, not
            // executable Chat tool calls. Keeping them as user-level context
            // avoids orphan tool results after switching models. Do not promote
            // search results or remote tool content into system instructions.
            other if other.ends_with("_call") || other.ends_with("_call_output")
                || matches!(other, "mcp_list_tools" | "mcp_approval_request" | "mcp_approval_response") => {
                messages.push(json!({"role":"user","content":format!(
                    "Historical Responses tool record (context only; not a request to execute or approve a tool):\n{item}")}));
            }
            "compaction" | "item_reference" => return Err(
                "The selected model cannot read provider-owned encrypted or referenced history. Use a native Responses model or start a conversation with full text history.".into()),
            other => return Err(format!("Unsupported Responses input item: {other}")),
        }
    }
    let tools = catalog.declarations;
    // Consecutive function calls belong to one assistant turn. Keeping them
    // separate makes the shared history sanitizer orphan parallel tool results.
    let mut grouped: Vec<Value> = Vec::new();
    for message in messages {
        if message["role"] == "assistant" && message.get("tool_calls").is_some() {
            if let Some(previous) = grouped
                .last_mut()
                .filter(|m| m["role"] == "assistant" && m.get("tool_calls").is_some())
            {
                previous["tool_calls"]
                    .as_array_mut()
                    .unwrap()
                    .extend(message["tool_calls"].as_array().unwrap().iter().cloned());
                continue;
            }
        }
        grouped.push(message);
    }
    let messages = grouped;
    let mut out = json!({"model":raw["model"],"messages":messages,"stream":true});
    if !tools.is_empty() {
        out["tools"] = json!(tools);
    }
    for key in ["temperature", "top_p", "parallel_tool_calls"] {
        if let Some(v) = raw.get(key) {
            out[key] = v.clone();
        }
    }
    if let Some(v) = raw.pointer("/reasoning/effort") {
        out["reasoning_effort"] = v.clone();
    }
    if let Some(v) = raw.get("max_output_tokens") {
        out["max_tokens"] = v.clone();
    }
    if let Some(choice) = tool_choice {
        out["tool_choice"] = choice;
    }
    Ok(out)
}

pub(crate) struct ResponsesBridge<'a> {
    sink: &'a mut dyn Write,
    streaming: bool,
    model: String,
    id: String,
    pending: Vec<u8>,
    headers_read: bool,
    upstream_json: bool,
    headers_sent: bool,
    started: bool,
    terminal: bool,
    sequence: u64,
    items: Vec<Value>,
    text_index: Option<usize>,
    tools: BTreeMap<u64, usize>,
    usage: Value,
    finish_reason: Option<String>,
    tool_catalog: ToolCatalog,
}
impl<'a> ResponsesBridge<'a> {
    pub fn new(sink: &'a mut dyn Write, model: &str, streaming: bool) -> Self {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        Self {
            sink,
            streaming,
            model: model.into(),
            id: format!("resp_tomo_{now}"),
            pending: vec![],
            headers_read: false,
            upstream_json: false,
            headers_sent: false,
            started: false,
            terminal: false,
            sequence: 0,
            items: vec![],
            text_index: None,
            tools: BTreeMap::new(),
            usage: Value::Null,
            finish_reason: None,
            tool_catalog: ToolCatalog::default(),
        }
    }
    pub fn set_tools(&mut self, raw: &Value) -> Result<(), String> {
        self.tool_catalog = ToolCatalog::from_request(raw)?;
        Ok(())
    }
    fn restored_item(&self, item: &Value) -> Value {
        let mut restored = item.clone();
        if let Some(identity) = item["name"]
            .as_str()
            .and_then(|name| self.tool_catalog.identities.get(name))
        {
            identity.restore(&mut restored);
        }
        restored
    }
    fn payload(&self, status: &str) -> Value {
        json!({"id":self.id,"object":"response","created_at":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs(),"model":self.model,"status":status,"output":self.items,"usage":self.usage,"error":null})
    }
    fn headers(&mut self, failed: bool) -> io::Result<()> {
        if !self.headers_sent {
            let status = if failed && !self.streaming {
                "502 Bad Gateway"
            } else {
                "200 OK"
            };
            let ct = if self.streaming {
                "text/event-stream"
            } else {
                "application/json"
            };
            write!(self.sink,"HTTP/1.1 {status}\r\nContent-Type: {ct}\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n")?;
            self.headers_sent = true;
        }
        Ok(())
    }
    fn emit(&mut self, kind: &str, mut event: Value) -> io::Result<()> {
        event["type"] = json!(kind);
        event["sequence_number"] = json!(self.sequence);
        self.sequence += 1;
        if self.streaming {
            self.headers(false)?;
            write!(self.sink, "event: {kind}\ndata: {event}\n\n")?;
            self.sink.flush()?;
        }
        Ok(())
    }
    fn start(&mut self) -> io::Result<()> {
        if !self.started {
            self.started = true;
            self.emit(
                "response.created",
                json!({"response":self.payload("in_progress")}),
            )?;
        }
        Ok(())
    }
    fn fail(&mut self, message: &str) -> io::Result<()> {
        if self.terminal {
            return Ok(());
        }
        self.terminal = true;
        let mut response = self.payload("failed");
        response["error"] = json!({"code":"upstream_error","message":message});
        if self.streaming {
            self.emit("response.failed", json!({"response":response}))?;
        } else {
            self.headers(true)?;
            write!(self.sink, "{}", json!({"error":response["error"]}))?;
        }
        Ok(())
    }
    fn text(&mut self, delta: &str) -> io::Result<()> {
        if delta.is_empty() {
            return Ok(());
        }
        let index = if let Some(i) = self.text_index {
            i
        } else {
            let i = self.items.len();
            self.text_index = Some(i);
            let item = json!({"id":format!("{}_msg_{i}",self.id),"type":"message","role":"assistant","status":"in_progress","content":[{"type":"output_text","text":"","annotations":[]}]});
            self.items.push(item.clone());
            self.emit(
                "response.output_item.added",
                json!({"output_index":i,"item":self.restored_item(&item)}),
            )?;
            self.emit("response.content_part.added",json!({"item_id":item["id"],"output_index":i,"content_index":0,"part":item["content"][0]}))?;
            i
        };
        let mut text = self.items[index]["content"][0]["text"]
            .as_str()
            .unwrap_or("")
            .to_owned();
        text.push_str(delta);
        self.items[index]["content"][0]["text"] = json!(text);
        self.emit("response.output_text.delta",json!({"item_id":self.items[index]["id"],"output_index":index,"content_index":0,"delta":delta}))
    }
    fn chat_chunk(&mut self, chunk: Value) -> io::Result<()> {
        if self.terminal {
            return Ok(());
        }
        if let Some(error) = chunk.get("error") {
            return self.fail(
                error["message"]
                    .as_str()
                    .unwrap_or("Upstream request failed"),
            );
        }
        self.start()?;
        if let Some(u) = chunk.get("usage").filter(|u| !u.is_null()) {
            self.usage = json!({"input_tokens":u["prompt_tokens"],"output_tokens":u["completion_tokens"],"total_tokens":u["total_tokens"]});
        }
        if let Some(choice) = chunk["choices"].as_array().and_then(|a| a.first()) {
            let delta = choice
                .get("delta")
                .or_else(|| choice.get("message"))
                .unwrap_or(&Value::Null);
            if let Some(text) = delta["content"].as_str() {
                self.text(text)?;
            }
            if let Some(calls) = delta["tool_calls"].as_array() {
                for (position, call) in calls.iter().enumerate() {
                    let ci = call["index"].as_u64().unwrap_or(position as u64);
                    let index = if let Some(i) = self.tools.get(&ci) {
                        *i
                    } else {
                        let i = self.items.len();
                        self.tools.insert(ci, i);
                        let item = json!({"id":format!("{}_fc_{i}",self.id),"type":"function_call","status":"in_progress","call_id":null,"name":"","arguments":""});
                        self.items.push(item);
                        i
                    };
                    // Some providers split the name or send the call id after
                    // the first delta. Publish tool events only once the full
                    // identity is available; text still streams immediately.
                    if let Some(id) = call["id"].as_str().filter(|id| !id.is_empty()) {
                        self.items[index]["call_id"] = json!(id);
                    }
                    for (source, target) in [("name", "name"), ("arguments", "arguments")] {
                        if let Some(s) = call["function"][source].as_str() {
                            let previous = self.items[index][target].as_str().unwrap_or("");
                            if source != "name" || previous != s {
                                self.items[index][target] = json!(format!("{previous}{s}"));
                            }
                        }
                    }
                }
            }
            if let Some(reason) = choice["finish_reason"].as_str() {
                self.finish_reason = Some(reason.into());
            }
        }
        Ok(())
    }
    fn complete(&mut self) -> io::Result<()> {
        if self.terminal {
            return Ok(());
        }
        if self.finish_reason.is_none() {
            return self.fail("Upstream stream closed before its finish event");
        }
        if self.items.is_empty() {
            return self.fail("Upstream returned no text or tool calls");
        }
        for i in 0..self.items.len() {
            let is_tool = self.items[i]["type"] == "function_call";
            if is_tool
                && (self.items[i]["name"].as_str().unwrap_or("").is_empty()
                    || self.items[i]["call_id"].as_str().unwrap_or("").is_empty())
            {
                return self
                    .fail("Upstream returned a tool call without a complete name or call id");
            }
            let identity = self.items[i]["name"]
                .as_str()
                .and_then(|name| self.tool_catalog.identities.get(name))
                .cloned();
            if let Some(identity) = identity.filter(ToolIdentity::buffered) {
                let arguments = self.items[i]["arguments"].as_str().unwrap_or("");
                let parsed = serde_json::from_str::<Value>(arguments).ok();
                if let Some(kind) = identity.local_kind {
                    let key = if kind == "apply_patch" {
                        "operation"
                    } else {
                        "action"
                    };
                    let Some(payload) = parsed
                        .and_then(|v| v.get(key).cloned())
                        .filter(Value::is_object)
                    else {
                        return self.fail("Invalid structured client tool arguments from upstream");
                    };
                    // A conversion must never create a different command or
                    // patch when the upstream produces invalid arguments.
                    let valid = match kind {
                        "shell" => nonempty_strings(&payload["commands"]),
                        "local_shell" => {
                            payload["type"] == "exec"
                                && nonempty_strings(&payload["command"])
                                && payload["env"]
                                    .as_object()
                                    .is_some_and(|e| e.values().all(Value::is_string))
                        }
                        _ => {
                            payload["path"].as_str().is_some_and(|p| !p.is_empty())
                                && match payload["type"].as_str() {
                                    Some("delete_file") => true,
                                    Some("create_file" | "update_file") => {
                                        payload["diff"].is_string()
                                    }
                                    _ => false,
                                }
                        }
                    };
                    if !valid {
                        return self.fail("Invalid structured client tool action from upstream");
                    }
                    self.items[i]["type"] = json!(format!("{kind}_call"));
                    self.items[i][key] = payload;
                    let item = self.items[i].as_object_mut().unwrap();
                    item.remove("name");
                    item.remove("arguments");
                } else if identity.search {
                    let Some(arguments) = parsed.filter(Value::is_object) else {
                        return self.fail("Invalid tool search arguments from upstream");
                    };
                    self.items[i]["type"] = json!("tool_search_call");
                    self.items[i]["execution"] = json!("client");
                    self.items[i]["arguments"] = arguments;
                    self.items[i].as_object_mut().unwrap().remove("name");
                } else {
                    let Some(input) = parsed.and_then(|v| v["input"].as_str().map(str::to_owned))
                    else {
                        return self.fail("Invalid custom tool input from upstream");
                    };
                    self.items[i]["type"] = json!("custom_tool_call");
                    self.items[i]["input"] = json!(input);
                    self.items[i].as_object_mut().unwrap().remove("arguments");
                }
            }
            self.items[i] = self.restored_item(&self.items[i]);
            if is_tool {
                let mut added = self.items[i].clone();
                if added["type"] == "function_call" {
                    added["arguments"] = json!("");
                }
                if added["type"] == "custom_tool_call" {
                    added["input"] = json!("");
                }
                self.emit(
                    "response.output_item.added",
                    json!({"output_index":i,"item":added}),
                )?;
            }
            self.items[i]["status"] = json!("completed");
            let item = self.items[i].clone();
            if item["type"] == "message" {
                self.emit("response.output_text.done",json!({"item_id":item["id"],"output_index":i,"content_index":0,"text":item["content"][0]["text"]}))?;
                self.emit("response.content_part.done",json!({"item_id":item["id"],"output_index":i,"content_index":0,"part":item["content"][0]}))?;
            } else if item["type"] == "function_call" {
                self.emit(
                    "response.function_call_arguments.delta",
                    json!({"item_id":item["id"],"output_index":i,"delta":item["arguments"]}),
                )?;
                self.emit("response.function_call_arguments.done",json!({"item_id":item["id"],"output_index":i,"arguments":item["arguments"],"name":item["name"]}))?;
            } else if item["type"] == "custom_tool_call" {
                self.emit(
                    "response.custom_tool_call_input.delta",
                    json!({"item_id":item["id"],"output_index":i,"delta":item["input"]}),
                )?;
                self.emit(
                    "response.custom_tool_call_input.done",
                    json!({"item_id":item["id"],"output_index":i,"input":item["input"]}),
                )?;
            }
            self.emit(
                "response.output_item.done",
                json!({"output_index":i,"item":item}),
            )?;
        }
        let incomplete = matches!(
            self.finish_reason.as_deref(),
            Some("length" | "content_filter")
        );
        let mut response = self.payload(if incomplete {
            "incomplete"
        } else {
            "completed"
        });
        if incomplete {
            response["incomplete_details"] = json!({"reason":"max_output_tokens"});
        }
        self.terminal = true;
        if self.streaming {
            self.emit(
                if incomplete {
                    "response.incomplete"
                } else {
                    "response.completed"
                },
                json!({"response":response}),
            )?;
        } else {
            self.headers(false)?;
            write!(self.sink, "{response}")?;
        }
        Ok(())
    }
    pub fn finish(&mut self) -> io::Result<()> {
        if self.terminal {
            return self.sink.flush();
        }
        if self.upstream_json {
            match serde_json::from_slice::<Value>(&self.pending) {
                Ok(v) => {
                    self.chat_chunk(v)?;
                }
                Err(_) => return self.fail("Invalid upstream response"),
            }
            self.pending.clear();
        }
        self.complete()?;
        self.sink.flush()
    }
}
impl Write for ResponsesBridge<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.pending.extend_from_slice(bytes);
        if !self.headers_read {
            let Some(end) = self.pending.windows(4).position(|w| w == b"\r\n\r\n") else {
                return Ok(bytes.len());
            };
            let headers = String::from_utf8_lossy(&self.pending[..end]).to_lowercase();
            self.upstream_json = !headers.contains("text/event-stream");
            self.pending.drain(..end + 4);
            self.headers_read = true;
        }
        if !self.upstream_json {
            while let Some(end) = self.pending.iter().position(|b| *b == b'\n') {
                let line: Vec<_> = self.pending.drain(..=end).collect();
                let line = String::from_utf8_lossy(&line);
                if let Some(data) = line.trim().strip_prefix("data:") {
                    if data.trim() == "[DONE]" {
                        self.complete()?;
                    } else {
                        match serde_json::from_str(data.trim()) {
                            Ok(v) => self.chat_chunk(v)?,
                            Err(_) => self.fail("Invalid upstream stream event")?,
                        }
                    }
                }
            }
        }
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        self.sink.flush()
    }
}
impl ProxyOutput for ResponsesBridge<'_> {
    fn responses_event(&mut self, event: &Value) -> io::Result<bool> {
        if self.terminal {
            return Ok(true);
        }
        let kind = event["type"].as_str().unwrap_or("error");
        if matches!(
            kind,
            "response.completed" | "response.failed" | "response.incomplete" | "error"
        ) {
            self.terminal = true;
            if !self.streaming {
                self.headers(kind != "response.completed")?;
                let value = event.get("response").unwrap_or(event);
                write!(self.sink, "{value}")?;
            }
        }
        if self.streaming {
            self.headers(false)?;
            write!(self.sink, "event: {kind}\ndata: {event}\n\n")?;
            self.sink.flush()?;
        }
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn events(bytes: &[u8]) -> Vec<Value> {
        String::from_utf8_lossy(bytes)
            .lines()
            .filter_map(|s| s.strip_prefix("data: "))
            .map(|s| serde_json::from_str(s).unwrap())
            .collect()
    }
    #[test]
    fn fragmented_chat_wire_emits_complete_typed_responses() {
        let mut sink = vec![];
        let wire=concat!("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"},\"finish_reason\":null}]}\r\n\r\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2,\"total_tokens\":5}}\n\n",
            "data: [DONE]\n\n");
        let mut bridge = ResponsesBridge::new(&mut sink, "gemini-test", true);
        for byte in wire.as_bytes() {
            bridge.write_all(&[*byte]).unwrap();
        }
        bridge.finish().unwrap();
        let es = events(&sink);
        assert_eq!(es.first().unwrap()["type"], "response.created");
        let end = es.last().unwrap();
        assert_eq!(end["type"], "response.completed");
        assert_eq!(end["response"]["output"][0]["content"][0]["text"], "你好");
        assert_eq!(end["response"]["usage"]["total_tokens"], 5);
        let item = es
            .iter()
            .find(|v| v["type"] == "response.output_item.done")
            .unwrap();
        assert_eq!(item["item"]["type"], "message");
        assert_eq!(item["item"]["role"], "assistant");
        for (i, e) in es.iter().enumerate() {
            assert_eq!(e["sequence_number"], i);
        }
    }
    #[test]
    fn tool_calls_are_complete_items_and_eof_is_failure() {
        let mut sink = vec![];
        let mut b = ResponsesBridge::new(&mut sink, "model", true);
        b.chat_chunk(json!({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call1","function":{"name":"read_file","arguments":"{\"path\":"}}]}}]})).unwrap();
        b.chat_chunk(json!({"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"a\"}"}}]},"finish_reason":"tool_calls"}]})).unwrap();
        b.finish().unwrap();
        let es = events(&sink);
        assert_eq!(
            es.last().unwrap()["response"]["output"][0]["arguments"],
            "{\"path\":\"a\"}"
        );
        assert_eq!(
            es.last().unwrap()["response"]["output"][0]["call_id"],
            "call1"
        );
        let mut sink = vec![];
        let mut b = ResponsesBridge::new(&mut sink, "model", true);
        b.chat_chunk(json!({"choices":[{"delta":{"content":"partial"}}]}))
            .unwrap();
        b.finish().unwrap();
        assert_eq!(events(&sink).last().unwrap()["type"], "response.failed");
    }
    #[test]
    fn native_events_preserve_reasoning_custom_tools_and_terminal_payload() {
        let mut sink = vec![];
        let mut b = ResponsesBridge::new(&mut sink, "model", true);
        let item = json!({"type":"response.output_item.done","item":{"type":"custom_tool_call","id":"ct1","call_id":"c1","name":"apply_patch","input":"patch"}});
        b.responses_event(&item).unwrap();
        b.responses_event(&json!({"type":"response.completed","response":{"id":"native","output":[item["item"]]}})).unwrap();
        b.finish().unwrap();
        let es = events(&sink);
        assert_eq!(es.len(), 2);
        assert_eq!(es[0], item);
        assert_eq!(es[1]["response"]["id"], "native");
    }
    #[test]
    fn non_stream_response_and_upstream_errors() {
        let mut sink = vec![];
        let mut b = ResponsesBridge::new(&mut sink, "model", false);
        b.chat_chunk(json!({"choices":[{"delta":{"content":"hello"},"finish_reason":"stop"}]}))
            .unwrap();
        b.finish().unwrap();
        let wire = String::from_utf8(sink).unwrap();
        let (_, body) = wire.split_once("\r\n\r\n").unwrap();
        let v: Value = serde_json::from_str(body).unwrap();
        assert_eq!(v["object"], "response");
        assert_eq!(v["output"][0]["content"][0]["text"], "hello");
        let mut sink = vec![];
        let mut b = ResponsesBridge::new(&mut sink, "model", true);
        b.write_all(b"HTTP/1.1 502 Bad Gateway\r\nContent-Type: application/json\r\n\r\n{\"error\":{\"message\":\"quota\"}}").unwrap();
        b.finish().unwrap();
        let es = events(&sink);
        assert_eq!(es.last().unwrap()["type"], "response.failed");
        assert_eq!(es.last().unwrap()["response"]["error"]["message"], "quota");
    }
    #[test]
    fn custom_tools_and_parallel_history_round_trip() {
        let raw = json!({"model":"gemini","tools":[{"type":"custom","name":"apply_patch"}],"input":[
            {"type":"function_call","call_id":"a","name":"read_file","arguments":"{}"},
            {"type":"function_call","call_id":"b","name":"list_files","arguments":"{}"},
            {"type":"function_call_output","call_id":"a","output":"a"},
            {"type":"function_call_output","call_id":"b","output":"b"},
            {"type":"custom_tool_call","call_id":"c","name":"apply_patch","input":"patch"},
            {"type":"custom_tool_call_output","call_id":"c","output":"done"}]});
        let chat = chat_request(&raw).unwrap();
        assert_eq!(
            chat["messages"][0]["tool_calls"].as_array().unwrap().len(),
            2
        );
        assert_eq!(
            chat["messages"][3]["tool_calls"][0]["function"]["arguments"],
            r#"{"input":"patch"}"#
        );
        let mut sink = Vec::new();
        let mut b = ResponsesBridge::new(&mut sink, "model", true);
        b.set_tools(&raw).unwrap();
        b.chat_chunk(json!({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"apply_patch","arguments":r#"{"input":"patch"}"#}}]},"finish_reason":"tool_calls"}]})).unwrap();
        b.finish().unwrap();
        let es = events(&sink);
        let item = &es.last().unwrap()["response"]["output"][0];
        assert_eq!(item["type"], "custom_tool_call");
        assert_eq!(item["input"], "patch");
        assert_eq!(item["call_id"], "c");
    }

    #[test]
    fn responses_request_preserves_tools_results_images_and_reasoning() {
        let raw = json!({"model":"gemini","instructions":"help","reasoning":{"effort":"high"},"tools":[{"type":"function","name":"read_file","parameters":{"type":"object"}}],"input":[
            {"role":"user","content":[{"type":"input_text","text":"read"},{"type":"input_image","image_url":"data:image/png;base64,test"}]},
            {"type":"function_call","call_id":"c1","name":"read_file","arguments":"{}"},
            {"type":"function_call_output","call_id":"c1","output":"done"}]});
        let out = chat_request(&raw).unwrap();
        assert_eq!(out["tools"][0]["function"]["name"], "read_file");
        assert_eq!(
            out["messages"][1]["content"][1]["image_url"]["url"],
            "data:image/png;base64,test"
        );
        assert_eq!(out["messages"][2]["tool_calls"][0]["id"], "c1");
        assert_eq!(out["messages"][3]["tool_call_id"], "c1");
        assert_eq!(out["reasoning_effort"], "high");
    }

    #[test]
    fn optional_hosted_and_future_tools_do_not_block_ordinary_turns() {
        for kind in [
            "web_search",
            "web_search_preview",
            "web_search_preview_2025_03_11",
            "file_search",
            "code_interpreter",
            "image_generation",
            "mcp",
            "computer",
            "computer_use_preview",
            "shell",
            "future_hosted_tool",
        ] {
            let raw =
                json!({"model":"chat","input":"你好","tools":[{"type":kind}],"tool_choice":"auto"});
            let request = chat_request(&raw).unwrap();
            assert!(request.get("tools").is_none(), "{kind}");
            assert!(request.get("tool_choice").is_none(), "{kind}");
            assert_eq!(request["messages"][1]["content"], "你好");
            assert!(request["messages"][0]["content"]
                .as_str()
                .unwrap()
                .contains(kind));
            let mut sink = vec![];
            let mut bridge = ResponsesBridge::new(&mut sink, "chat", true);
            bridge.set_tools(&raw).unwrap();
            bridge
                .chat_chunk(
                    json!({"choices":[{"delta":{"content":"你好"},"finish_reason":"stop"}]}),
                )
                .unwrap();
            bridge.finish().unwrap();
            assert_eq!(events(&sink).last().unwrap()["type"], "response.completed");
        }
    }

    #[test]
    fn choices_keep_namespace_restrictions_and_reject_unavailable_forced_tools() {
        let mut raw = json!({"model":"chat","input":"hi","tools":[
            {"type":"web_search"},
            {"type":"namespace","name":"files","tools":[{"type":"function","name":"read","parameters":{"type":"object"}}]},
            {"type":"function","name":"other","parameters":{"type":"object"}}
        ],"tool_choice":{"type":"allowed_tools","mode":"required","tools":[{"type":"namespace","name":"files"},{"type":"web_search"}]}});
        let request = chat_request(&raw).unwrap();
        assert_eq!(request["tools"].as_array().unwrap().len(), 1);
        assert_eq!(request["tool_choice"], "required");
        let name = request["tools"][0]["function"]["name"].clone();
        raw["tool_choice"] = json!({"type":"function","namespace":"files","name":"read"});
        assert_eq!(
            chat_request(&raw).unwrap()["tool_choice"]["function"]["name"],
            name
        );
        raw["tool_choice"] = json!({"type":"web_search"});
        assert!(chat_request(&raw)
            .unwrap_err()
            .contains("explicitly requested"));
        raw["tool_choice"] =
            json!({"type":"allowed_tools","mode":"required","tools":[{"type":"web_search"}]});
        assert!(chat_request(&raw)
            .unwrap_err()
            .contains("no available client tools"));
        raw["tool_choice"]["mode"] = json!("auto");
        assert!(chat_request(&raw).unwrap().get("tools").is_none());
    }

    #[test]
    fn mixed_codex_tools_restore_namespaces_and_late_stream_identity() {
        let raw = json!({"model":"chat","input":"hi","tools":[
            {"type":"web_search"},
            {"type":"namespace","name":"functions","tools":[{"type":"function","name":"exec","parameters":{"type":"object"}}]},
            {"type":"custom","name":"apply_patch"},
            {"type":"tool_search","execution":"client","parameters":{"type":"object"}}
        ]});
        let request = chat_request(&raw).unwrap();
        assert_eq!(request["tools"].as_array().unwrap().len(), 3);
        let wire_name = request["tools"][0]["function"]["name"].as_str().unwrap();
        let mut sink = vec![];
        let mut bridge = ResponsesBridge::new(&mut sink, "chat", true);
        bridge.set_tools(&raw).unwrap();
        bridge.chat_chunk(json!({"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":&wire_name[..12],"arguments":"{"}}]}}]})).unwrap();
        bridge.chat_chunk(json!({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":&wire_name[12..],"arguments":"}"}}]},"finish_reason":"tool_calls"}]})).unwrap();
        bridge.finish().unwrap();
        let es = events(&sink);
        let item = &es.last().unwrap()["response"]["output"][0];
        assert_eq!(item["namespace"], "functions");
        assert_eq!(item["name"], "exec");
        assert_eq!(item["call_id"], "c1");
        assert_eq!(item["arguments"], "{}");
    }

    #[test]
    fn structured_client_tools_round_trip_without_gateway_execution() {
        for (tool, key, payload) in [
            (
                json!({"type":"local_shell"}),
                "action",
                json!({"type":"exec","command":["pwd"],"env":{}}),
            ),
            (
                json!({"type":"shell","environment":{"type":"local"}}),
                "action",
                json!({"commands":["pwd"]}),
            ),
            (
                json!({"type":"apply_patch"}),
                "operation",
                json!({"type":"delete_file","path":"example.txt"}),
            ),
        ] {
            let raw = json!({"model":"chat","input":"hi","tools":[tool]});
            let request = chat_request(&raw).unwrap();
            let name = &request["tools"][0]["function"]["name"];
            let mut sink = vec![];
            let mut bridge = ResponsesBridge::new(&mut sink, "chat", true);
            bridge.set_tools(&raw).unwrap();
            bridge.chat_chunk(json!({"choices":[{"delta":{"tool_calls":[{"id":"c1","function":{"name":name,"arguments":json!({(key):payload}).to_string()}}]},"finish_reason":"tool_calls"}]})).unwrap();
            bridge.finish().unwrap();
            let es = events(&sink);
            let item = &es.last().unwrap()["response"]["output"][0];
            assert_eq!(
                item["type"],
                format!("{}_call", tool["type"].as_str().unwrap())
            );
            assert_eq!(item[key], payload);
            let mut replay = raw.clone();
            replay["input"] = json!([item,{"type":format!("{}_call_output",tool["type"].as_str().unwrap()),"call_id":"c1","status":"completed","output":"done"}]);
            let chat = chat_request(&replay).unwrap();
            assert_eq!(
                chat["messages"][0]["tool_calls"][0]["function"]["name"],
                *name
            );
            assert_eq!(chat["messages"][1]["tool_call_id"], "c1");
        }
    }

    #[test]
    fn hosted_history_is_context_and_loaded_tool_replaces_stub() {
        let raw = json!({"model":"chat","tools":[{"type":"function","name":"read","defer_loading":true}],"input":[
            {"type":"web_search_call","id":"ws1","action":{"type":"search","query":"example"},"status":"completed"},
            {"type":"mcp_call","name":"lookup","output":"untrusted output"},
            {"type":"additional_tools","tools":[{"type":"function","name":"read","parameters":{"type":"object","properties":{"path":{"type":"string"}}}}]},
            {"role":"user","content":"continue"}
        ]});
        let request = chat_request(&raw).unwrap();
        assert_eq!(request["tools"].as_array().unwrap().len(), 1);
        assert_eq!(
            request["tools"][0]["function"]["parameters"]["properties"]["path"]["type"],
            "string"
        );
        assert_eq!(request["messages"][0]["role"], "user");
        assert!(request["messages"][1]["content"]
            .as_str()
            .unwrap()
            .contains("untrusted output"));
        assert_eq!(request["messages"][2]["content"], "continue");
    }
}
