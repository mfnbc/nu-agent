use std::collections::BTreeSet;
use std::path::Path;

use blake3::Hasher;
use pulldown_cmark::{CodeBlockKind, CowStr, Event, HeadingLevel, Options, Parser, Tag, TagEnd};

use crate::types::{ChunkType, CodeBlock, Complexity, Data, Hierarchy, Identity, NuDocChunk, Taxonomy};

#[derive(Debug, Clone)]
pub struct SplitterConfig {
    pub source: String,
    pub path: String,
    pub checksum: String,
    pub attach_code_blocks: bool,
}

#[derive(Debug)]
struct HeadingCapture {
    level: usize,
    text: String,
}

#[derive(Debug)]
struct CodeCapture {
    language: String,
    code: String,
}

#[derive(Debug)]
pub struct SplitterState {
    config: SplitterConfig,
    document_title: String,
    heading_stack: Vec<String>,
    current_content: String,
    current_code_blocks: Vec<CodeBlock>,
    current_commands: BTreeSet<String>,
    current_links: BTreeSet<String>,
    chunk_order: usize,
    heading_capture: Option<HeadingCapture>,
    code_capture: Option<CodeCapture>,
    chunks: Vec<NuDocChunk>,
}

impl SplitterState {
    pub fn new(config: SplitterConfig) -> Self {
        let document_title = Path::new(&config.path)
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("document")
            .to_string();

        Self {
            config,
            document_title,
            heading_stack: Vec::new(),
            current_content: String::new(),
            current_code_blocks: Vec::new(),
            current_commands: BTreeSet::new(),
            current_links: BTreeSet::new(),
            chunk_order: 1,
            heading_capture: None,
            code_capture: None,
            chunks: Vec::new(),
        }
    }

    pub fn finish(mut self) -> Vec<NuDocChunk> {
        self.flush_section_chunk();
        self.chunks
    }

    pub fn handle_event(&mut self, event: Event<'_>) {
        match event {
            Event::Start(Tag::Heading { level, .. }) => {
                self.flush_section_chunk();
                self.heading_capture = Some(HeadingCapture {
                    level: heading_level_to_usize(level),
                    text: String::new(),
                });
            }
            Event::End(TagEnd::Heading(_)) => {
                if let Some(capture) = self.heading_capture.take() {
                    let title = capture.text.trim().to_string();
                    if !title.is_empty() {
                        self.update_heading_stack(capture.level, title);
                    }
                }
            }
            Event::Start(Tag::Paragraph) => {
                if self.heading_capture.is_none() && self.code_capture.is_none() && !self.current_content.is_empty() {
                    self.current_content.push('\n');
                }
            }
            Event::End(TagEnd::Paragraph) => {
                if self.heading_capture.is_none() && self.code_capture.is_none() {
                    self.current_content.push('\n');
                }
            }
            Event::Start(Tag::Item) => {
                if self.heading_capture.is_none() && self.code_capture.is_none() {
                    if !self.current_content.is_empty() {
                        self.current_content.push('\n');
                    }
                }
            }
            Event::End(TagEnd::Item) => {
                if self.heading_capture.is_none() && self.code_capture.is_none() {
                    self.current_content.push('\n');
                }
            }
            Event::Start(Tag::CodeBlock(kind)) => {
                if !self.config.attach_code_blocks {
                    self.flush_section_chunk();
                }

                self.code_capture = Some(CodeCapture {
                    language: code_block_language(&kind),
                    code: String::new(),
                });
            }
            Event::End(TagEnd::CodeBlock) => {
                if let Some(capture) = self.code_capture.take() {
                    let code_block = CodeBlock {
                        code: capture.code.clone(),
                        language: capture.language.clone(),
                        description: None,
                        is_idiomatic: false,
                    };

                    self.add_commands_from_code(&capture.code);

                    if self.config.attach_code_blocks {
                        self.current_code_blocks.push(code_block);
                    } else {
                        self.emit_code_chunk(code_block);
                    }
                }
            }
            Event::Text(text) => {
                self.push_text(&text);
            }
            Event::Code(text) => {
                self.push_inline_code(&text);
            }
            Event::SoftBreak | Event::HardBreak => {
                self.push_newline();
            }
            Event::Html(html) => {
                self.push_raw(&html);
            }
            Event::Rule => {
                self.push_newline();
            }
            _ => {}
        }
    }

    fn update_heading_stack(&mut self, level: usize, title: String) {
        while self.heading_stack.len() >= level {
            self.heading_stack.pop();
        }
        self.heading_stack.push(title);
    }

    fn push_text(&mut self, text: &CowStr<'_>) {
        let text = text.to_string();

        if self.heading_capture.is_some() {
            if let Some(capture) = self.heading_capture.as_mut() {
                capture.text.push_str(&text);
            }
            return;
        }

        if let Some(code_capture) = self.code_capture.as_mut() {
            code_capture.code.push_str(&text);
            return;
        }

        self.current_content.push_str(&text);
        self.add_commands_from_text(&text);
    }

    fn push_inline_code(&mut self, text: &CowStr<'_>) {
        let snippet = text.to_string();

        if self.heading_capture.is_some() {
            if let Some(capture) = self.heading_capture.as_mut() {
                capture.text.push_str(&snippet);
            }
            return;
        }

        if let Some(code_capture) = self.code_capture.as_mut() {
            code_capture.code.push_str(&snippet);
            return;
        }

        self.current_content.push('`');
        self.current_content.push_str(&snippet);
        self.current_content.push('`');
        self.add_commands_from_text(&snippet);
    }

    fn push_newline(&mut self) {
        if self.heading_capture.is_some() {
            if let Some(capture) = self.heading_capture.as_mut() {
                capture.text.push(' ');
            }
            return;
        }

        if let Some(code_capture) = self.code_capture.as_mut() {
            code_capture.code.push('\n');
            return;
        }

        self.current_content.push('\n');
    }

    fn push_raw(&mut self, raw: &CowStr<'_>) {
        let raw = raw.to_string();

        if self.heading_capture.is_some() {
            if let Some(capture) = self.heading_capture.as_mut() {
                capture.text.push_str(&raw);
            }
            return;
        }

        if let Some(code_capture) = self.code_capture.as_mut() {
            code_capture.code.push_str(&raw);
            return;
        }

        self.current_content.push_str(&raw);
    }

    fn flush_section_chunk(&mut self) {
        let content = self.current_content.trim().to_string();
        let has_code = !self.current_code_blocks.is_empty();
        let has_commands = !self.current_commands.is_empty();
        let has_links = !self.current_links.is_empty();

        if content.is_empty() && !has_code && !has_commands && !has_links {
            self.current_content.clear();
            self.current_commands.clear();
            self.current_links.clear();
            return;
        }

        let heading_path = self.current_heading_path();
        let title = self.current_title();
        let commands = self.current_commands.iter().cloned().collect::<Vec<_>>();
        let links = self.current_links.iter().cloned().collect::<Vec<_>>();
        let code_blocks = std::mem::take(&mut self.current_code_blocks);
        let chunk_type = classify_section_chunk(&title, &heading_path, &content, &code_blocks, &commands);
        let tags = build_tags(&self.config.source, &title, &heading_path, &commands, &code_blocks, &chunk_type);
        let complexity = infer_complexity(&title, &heading_path, &chunk_type);
        let id = stable_chunk_id(&self.config.path, &heading_path, self.chunk_order);
        let embedding_input = build_embedding_input(&title, &heading_path, &content, &commands, &code_blocks);

        self.chunks.push(NuDocChunk {
            id,
            identity: Identity {
                source: self.config.source.clone(),
                path: self.config.path.clone(),
                checksum: self.config.checksum.clone(),
            },
            hierarchy: Hierarchy {
                title,
                heading_path,
                order: self.chunk_order,
                parent_id: None,
            },
            taxonomy: Taxonomy {
                chunk_type,
                commands,
                tags,
                complexity,
            },
            data: Data {
                content,
                code_blocks,
                links,
            },
            embedding_input,
        });

        self.chunk_order += 1;
        self.current_content.clear();
        self.current_commands.clear();
        self.current_links.clear();
    }

    fn emit_code_chunk(&mut self, code_block: CodeBlock) {
        let heading_path = self.current_heading_path();
        let title = self.current_title();
        let content = code_block.code.clone();
        let commands = extract_commands_from_code(&code_block.code)
            .into_iter()
            .collect::<Vec<_>>();
        let tags = build_tags(
            &self.config.source,
            &title,
            &heading_path,
            &commands,
            std::slice::from_ref(&code_block),
            &ChunkType::Example,
        );
        let complexity = infer_complexity(&title, &heading_path, &ChunkType::Example);
        let id = stable_chunk_id(&self.config.path, &heading_path, self.chunk_order);
        let embedding_input = build_embedding_input(&title, &heading_path, &content, &commands, std::slice::from_ref(&code_block));

        self.chunks.push(NuDocChunk {
            id,
            identity: Identity {
                source: self.config.source.clone(),
                path: self.config.path.clone(),
                checksum: self.config.checksum.clone(),
            },
            hierarchy: Hierarchy {
                title,
                heading_path,
                order: self.chunk_order,
                parent_id: None,
            },
            taxonomy: Taxonomy {
                chunk_type: ChunkType::Example,
                commands,
                tags,
                complexity,
            },
            data: Data {
                content,
                code_blocks: vec![code_block],
                links: Vec::new(),
            },
            embedding_input,
        });

        self.chunk_order += 1;
    }

    fn current_heading_path(&self) -> Vec<String> {
        if self.heading_stack.is_empty() {
            vec![self.document_title.clone()]
        } else {
            self.heading_stack.clone()
        }
    }

    fn current_title(&self) -> String {
        self.heading_stack
            .last()
            .cloned()
            .unwrap_or_else(|| self.document_title.clone())
    }

    fn add_commands_from_text(&mut self, text: &str) {
        for candidate in extract_backtick_tokens(text) {
            if is_commandish(&candidate) {
                self.current_commands.insert(candidate);
            }
        }
    }

    fn add_commands_from_code(&mut self, code: &str) {
        for candidate in extract_commands_from_code(code) {
            self.current_commands.insert(candidate);
        }
    }
}

pub fn split_markdown(markdown: &str, config: SplitterConfig) -> Vec<NuDocChunk> {
    let mut state = SplitterState::new(config);
    let parser = Parser::new_ext(markdown, Options::all());

    for event in parser {
        state.handle_event(event);
    }

    state.finish()
}

fn heading_level_to_usize(level: HeadingLevel) -> usize {
    match level {
        HeadingLevel::H1 => 1,
        HeadingLevel::H2 => 2,
        HeadingLevel::H3 => 3,
        HeadingLevel::H4 => 4,
        HeadingLevel::H5 => 5,
        HeadingLevel::H6 => 6,
    }
}

fn code_block_language(kind: &CodeBlockKind) -> String {
    match kind {
        CodeBlockKind::Indented => "plain".to_string(),
        CodeBlockKind::Fenced(lang) => lang.to_string(),
    }
}

fn stable_chunk_id(path: &str, heading_path: &[String], order_index: usize) -> String {
    let key = format!("{}::{}::{}", path, heading_path.join("/"), order_index);
    let mut hasher = Hasher::new();
    hasher.update(key.as_bytes());
    hasher.finalize().to_hex().to_string()
}

fn infer_complexity(title: &str, heading_path: &[String], chunk_type: &ChunkType) -> Complexity {
    let joined = format!("{} {}", title, heading_path.join(" ")).to_lowercase();

    if joined.contains("advanced") {
        Complexity::Advanced
    } else if joined.contains("reference") || matches!(chunk_type, ChunkType::CommandRef) {
        Complexity::Intermediate
    } else {
        Complexity::Beginner
    }
}

fn classify_section_chunk(
    title: &str,
    heading_path: &[String],
    content: &str,
    code_blocks: &[CodeBlock],
    commands: &[String],
) -> ChunkType {
    let joined = format!("{} {} {}", title, heading_path.join(" "), content).to_lowercase();

    if joined.contains("troubleshoot") || joined.contains("troubleshooting") || joined.contains("error") {
        ChunkType::Troubleshooting
    } else if joined.contains("command reference")
        || joined.contains("reference")
        || joined.contains("commands")
        || (!commands.is_empty() && code_blocks.is_empty())
    {
        ChunkType::CommandRef
    } else if !code_blocks.is_empty() && content.trim().is_empty() {
        ChunkType::Example
    } else {
        ChunkType::Concept
    }
}

fn build_tags(
    source: &str,
    title: &str,
    heading_path: &[String],
    commands: &[String],
    code_blocks: &[CodeBlock],
    chunk_type: &ChunkType,
) -> Vec<String> {
    let mut tags = BTreeSet::new();
    tags.insert(source.to_string());
    tags.insert(chunk_type_to_tag(chunk_type));

    for word in split_tags(title) {
        tags.insert(word);
    }

    for heading in heading_path {
        for word in split_tags(heading) {
            tags.insert(word);
        }
    }

    for command in commands {
        tags.insert(command.clone());
    }

    for block in code_blocks {
        if !block.language.trim().is_empty() {
            tags.insert(block.language.trim().to_string());
        }
    }

    tags.into_iter().collect()
}

fn chunk_type_to_tag(chunk_type: &ChunkType) -> String {
    match chunk_type {
        ChunkType::Concept => "concept".to_string(),
        ChunkType::CommandRef => "command_ref".to_string(),
        ChunkType::Example => "example".to_string(),
        ChunkType::Troubleshooting => "troubleshooting".to_string(),
    }
}

fn split_tags(text: &str) -> Vec<String> {
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|part| !part.is_empty())
        .map(|part| part.to_lowercase())
        .filter(|part| !is_stopword(part))
        .collect()
}

fn is_stopword(word: &str) -> bool {
    matches!(
        word,
        "a" | "an" | "and" | "as" | "at" | "by" | "for" | "from" | "in" | "into" | "of" | "on" | "or" | "the" | "to" | "with"
    )
}

fn build_embedding_input(
    title: &str,
    heading_path: &[String],
    content: &str,
    commands: &[String],
    code_blocks: &[CodeBlock],
) -> String {
    let mut out = String::new();
    out.push_str("Title: ");
    out.push_str(title);
    out.push('\n');
    out.push_str("Path: ");
    out.push_str(&heading_path.join(" > "));
    out.push('\n');

    if !commands.is_empty() {
        out.push_str("Commands: ");
        out.push_str(&commands.join(", "));
        out.push('\n');
    }

    out.push_str("Content: ");
    out.push_str(content.trim());
    out.push('\n');

    if !code_blocks.is_empty() {
        out.push_str("Code: ");
        out.push_str(
            &code_blocks
                .iter()
                .map(|block| block.code.trim())
                .filter(|code| !code.is_empty())
                .collect::<Vec<_>>()
                .join("\n---\n"),
        );
        out.push('\n');
    }

    out.trim().to_string()
}

fn extract_backtick_tokens(text: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut start = 0usize;

    while let Some(open_rel) = text[start..].find('`') {
        let open = start + open_rel + 1;
        if let Some(close_rel) = text[open..].find('`') {
            let close = open + close_rel;
            let candidate = text[open..close].trim();
            if !candidate.is_empty() && candidate.split_whitespace().count() == 1 {
                result.push(candidate.to_string());
            }
            start = close + 1;
        } else {
            break;
        }
    }

    result
}

fn extract_commands_from_code(code: &str) -> Vec<String> {
    let mut result = BTreeSet::new();

    for line in code.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        for segment in line.split('|') {
            let segment = segment.trim();
            if let Some(raw) = segment.split_whitespace().next() {
                let token = clean_token(raw);
                if is_commandish(&token) {
                    result.insert(token);
                }
            }
        }
    }

    result.into_iter().collect()
}

fn clean_token(token: &str) -> String {
    token
        .trim_matches(|c: char| matches!(c, '(' | ')' | '[' | ']' | '{' | '}' | '"' | '\'' | ';' | ','))
        .to_string()
}

fn is_commandish(token: &str) -> bool {
    if token.is_empty() {
        return false;
    }

    let lowered = token.to_lowercase();
    if is_reserved_word(&lowered) {
        return false;
    }

    let mut chars = lowered.chars();
    match chars.next() {
        Some(first) if first.is_ascii_alphabetic() => {}
        _ => return false,
    }

    lowered
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn is_reserved_word(token: &str) -> bool {
    matches!(
        token,
        "let" | "if" | "else" | "for" | "match" | "where" | "each" | "def" | "export" | "use" | "do" | "try" | "mut" | "return"
    )
}
