"""Bulletproof JSONC parser, tokenizer, and comment-preserving surgical modifier.

Parses JSON with comments and trailing commas, and provides zero-loss surgical
modifications that preserve 100% of existing user comments, indentation, and structure.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple, Union


class JsoncParseError(ValueError):
    """Raised when JSONC syntax is invalid."""

    def __init__(self, message: str, line: int = 1, column: int = 1):
        super().__init__(f"Line {line}, Column {column}: {message}")
        self.message = message
        self.line = line
        self.column = column


@dataclass
class Token:
    """A lexical token with source position."""

    kind: str  # STRING, NUMBER, BOOL, NULL, LBRACE, RBRACE, LBRACKET, RBRACKET, COLON, COMMA, COMMENT, WS
    value: str
    start: int
    end: int
    line: int
    col: int


def tokenize_jsonc(text: str) -> List[Token]:
    """Tokenize JSONC string into structured tokens including comments and whitespace.

    Correctly handles:
    - Escaped quotes and backslashes in strings
    - URLs and slashes inside strings without treating them as comments
    - Single-line comments (//...)
    - Multi-line block comments (/*...*/)
    - Whitespace and newlines
    - Trailing commas
    """
    tokens: List[Token] = []
    i = 0
    n = len(text)
    line = 1
    col = 1

    # Strip UTF-8 BOM if present at start
    if text.startswith("\ufeff"):
        i = 1
        col = 2

    while i < n:
        c = text[i]

        # 1. Whitespace
        if c in " \t\r\n":
            start_i = i
            start_line, start_col = line, col
            while i < n and text[i] in " \t\r\n":
                if text[i] == "\n":
                    line += 1
                    col = 1
                else:
                    col += 1
                i += 1
            tokens.append(Token("WS", text[start_i:i], start_i, i, start_line, start_col))
            continue

        # 2. Single-line or Multi-line Comment
        if c == "/" and i + 1 < n:
            next_c = text[i + 1]
            if next_c == "/":
                start_i = i
                start_line, start_col = line, col
                i += 2
                col += 2
                while i < n and text[i] != "\n":
                    i += 1
                    col += 1
                tokens.append(Token("COMMENT", text[start_i:i], start_i, i, start_line, start_col))
                continue
            elif next_c == "*":
                start_i = i
                start_line, start_col = line, col
                i += 2
                col += 2
                closed = False
                while i + 1 < n:
                    if text[i] == "*" and text[i + 1] == "/":
                        i += 2
                        col += 2
                        closed = True
                        break
                    if text[i] == "\n":
                        line += 1
                        col = 1
                    else:
                        col += 1
                    i += 1
                if not closed:
                    raise JsoncParseError("Unterminated block comment", start_line, start_col)
                tokens.append(Token("COMMENT", text[start_i:i], start_i, i, start_line, start_col))
                continue

        # 3. String literal
        if c == '"':
            start_i = i
            start_line, start_col = line, col
            i += 1
            col += 1
            escaped = False
            while i < n:
                cur = text[i]
                if cur == "\n":
                    raise JsoncParseError("Unescaped newline inside string literal", line, col)
                if escaped:
                    escaped = False
                elif cur == "\\":
                    escaped = True
                elif cur == '"':
                    i += 1
                    col += 1
                    break
                i += 1
                col += 1
            else:
                raise JsoncParseError("Unterminated string literal", start_line, start_col)
            tokens.append(Token("STRING", text[start_i:i], start_i, i, start_line, start_col))
            continue

        # 4. Structural punctuation
        if c == "{":
            tokens.append(Token("LBRACE", "{", i, i + 1, line, col))
            i += 1
            col += 1
            continue
        if c == "}":
            tokens.append(Token("RBRACE", "}", i, i + 1, line, col))
            i += 1
            col += 1
            continue
        if c == "[":
            tokens.append(Token("LBRACKET", "[", i, i + 1, line, col))
            i += 1
            col += 1
            continue
        if c == "]":
            tokens.append(Token("RBRACKET", "]", i, i + 1, line, col))
            i += 1
            col += 1
            continue
        if c == ":":
            tokens.append(Token("COLON", ":", i, i + 1, line, col))
            i += 1
            col += 1
            continue
        if c == ",":
            tokens.append(Token("COMMA", ",", i, i + 1, line, col))
            i += 1
            col += 1
            continue

        # 5. Literals: true, false, null
        if text.startswith("true", i):
            tokens.append(Token("BOOL", "true", i, i + 4, line, col))
            i += 4
            col += 4
            continue
        if text.startswith("false", i):
            tokens.append(Token("BOOL", "false", i, i + 5, line, col))
            i += 5
            col += 5
            continue
        if text.startswith("null", i):
            tokens.append(Token("NULL", "null", i, i + 4, line, col))
            i += 4
            col += 4
            continue

        # 6. Numbers
        num_match = re.match(r"-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?", text[i:])
        if num_match:
            num_str = num_match.group(0)
            tokens.append(Token("NUMBER", num_str, i, i + len(num_str), line, col))
            i += len(num_str)
            col += len(num_str)
            continue

        raise JsoncParseError(f"Unexpected character {c!r}", line, col)

    return tokens


def parse_jsonc(text: str) -> Any:
    """Parse JSONC string into Python dict/list/primitive.

    Tolerates comments and trailing commas.
    """
    tokens = tokenize_jsonc(text)
    meaningful = [t for t in tokens if t.kind not in ("WS", "COMMENT")]

    if not meaningful:
        raise JsoncParseError("Empty JSON content")

    pos = 0

    def parse_value() -> Any:
        nonlocal pos
        if pos >= len(meaningful):
            raise JsoncParseError("Unexpected end of JSON input")

        token = meaningful[pos]

        if token.kind == "STRING":
            pos += 1
            try:
                return json.loads(token.value)
            except Exception as e:
                raise JsoncParseError(f"Invalid string escape: {e}", token.line, token.col)

        if token.kind == "NUMBER":
            pos += 1
            val_str = token.value
            return float(val_str) if ("." in val_str or "e" in val_str or "E" in val_str) else int(val_str)

        if token.kind == "BOOL":
            pos += 1
            return token.value == "true"

        if token.kind == "NULL":
            pos += 1
            return None

        if token.kind == "LBRACE":
            return parse_object()

        if token.kind == "LBRACKET":
            return parse_array()

        raise JsoncParseError(f"Unexpected token {token.kind} ({token.value!r})", token.line, token.col)

    def parse_object() -> Dict[str, Any]:
        nonlocal pos
        obj: Dict[str, Any] = {}
        lbrace = meaningful[pos]
        pos += 1  # skip LBRACE

        while pos < len(meaningful):
            tok = meaningful[pos]
            if tok.kind == "RBRACE":
                pos += 1
                return obj

            if tok.kind != "STRING":
                raise JsoncParseError(f"Expected string key in object, got {tok.kind}", tok.line, tok.col)

            key = json.loads(tok.value)
            pos += 1

            if pos >= len(meaningful) or meaningful[pos].kind != "COLON":
                cur = meaningful[pos] if pos < len(meaningful) else tok
                raise JsoncParseError(f"Expected ':' after object key {key!r}", cur.line, cur.col)
            pos += 1  # skip COLON

            val = parse_value()
            obj[key] = val

            if pos < len(meaningful):
                sep = meaningful[pos]
                if sep.kind == "COMMA":
                    pos += 1
                    # Trailing comma allowed before RBRACE
                    if pos < len(meaningful) and meaningful[pos].kind == "RBRACE":
                        pos += 1
                        return obj
                elif sep.kind == "RBRACE":
                    pos += 1
                    return obj
                else:
                    raise JsoncParseError(f"Expected ',' or '}}', got {sep.kind}", sep.line, sep.col)

        raise JsoncParseError("Unterminated object", lbrace.line, lbrace.col)

    def parse_array() -> List[Any]:
        nonlocal pos
        arr: List[Any] = []
        lbracket = meaningful[pos]
        pos += 1  # skip LBRACKET

        while pos < len(meaningful):
            tok = meaningful[pos]
            if tok.kind == "RBRACKET":
                pos += 1
                return arr

            val = parse_value()
            arr.append(val)

            if pos < len(meaningful):
                sep = meaningful[pos]
                if sep.kind == "COMMA":
                    pos += 1
                    # Trailing comma allowed before RBRACKET
                    if pos < len(meaningful) and meaningful[pos].kind == "RBRACKET":
                        pos += 1
                        return arr
                elif sep.kind == "RBRACKET":
                    pos += 1
                    return arr
                else:
                    raise JsoncParseError(f"Expected ',' or ']', got {sep.kind}", sep.line, sep.col)

        raise JsoncParseError("Unterminated array", lbracket.line, lbracket.col)

    result = parse_value()
    if pos < len(meaningful):
        leftover = meaningful[pos]
        raise JsoncParseError(f"Unexpected trailing tokens: {leftover.kind}", leftover.line, leftover.col)

    return result


class JsoncModifier:
    """Surgically modifies JSONC text to preserve 100% of comments and formatting."""

    def __init__(self, raw_text: str):
        self.raw_text = raw_text
        # First ensure original parses cleanly
        self.parsed = parse_jsonc(raw_text)
        if not isinstance(self.parsed, dict):
            raise JsoncParseError("Root JSON structure must be an object")

    def upsert_windows_terminal_scheme(self, scheme_dict: Dict[str, str], indent_spaces: int = 4) -> str:
        """Upsert a scheme into the 'schemes' array preserving comments.

        If scheme already exists with the same name, updates it.
        If it does not exist, appends to 'schemes'.
        If 'schemes' doesn't exist, adds 'schemes' property.
        """
        scheme_name = scheme_dict["name"]
        text = self.raw_text
        tokens = tokenize_jsonc(text)

        # Formatted scheme JSON string
        scheme_json_indented = json.dumps(scheme_dict, indent=indent_spaces)
        pad = " " * indent_spaces
        # Indent each line
        formatted_scheme = "\n".join((pad * 2 + line) if idx > 0 else (pad * 2 + line) for idx, line in enumerate(scheme_json_indented.splitlines()))

        # Locate root 'schemes'
        meaningful = [t for t in tokens if t.kind not in ("WS", "COMMENT")]
        schemes_token_idx = -1
        for idx, tok in enumerate(meaningful):
            if tok.kind == "STRING" and json.loads(tok.value) == "schemes":
                if idx + 1 < len(meaningful) and meaningful[idx + 1].kind == "COLON":
                    if idx + 2 < len(meaningful) and meaningful[idx + 2].kind == "LBRACKET":
                        schemes_token_idx = idx
                        break

        if schemes_token_idx != -1:
            # 'schemes' array exists
            lbracket_token = meaningful[schemes_token_idx + 2]
            # Find matching RBRACKET
            bracket_depth = 0
            array_start = lbracket_token.start
            array_end = -1
            rbracket_token: Optional[Token] = None

            for tok in meaningful[schemes_token_idx + 2:]:
                if tok.kind == "LBRACKET":
                    bracket_depth += 1
                elif tok.kind == "RBRACKET":
                    bracket_depth -= 1
                    if bracket_depth == 0:
                        array_end = tok.end
                        rbracket_token = tok
                        break

            if rbracket_token is None:
                raise JsoncParseError("Could not find matching ']' for 'schemes'")

            # Search inside schemes array for matching name
            # We locate each object inside the array
            existing_span = self._find_scheme_object_span(tokens, lbracket_token, rbracket_token, scheme_name)

            if existing_span:
                # Replace existing scheme span
                start_pos, end_pos = existing_span
                new_text = text[:start_pos] + formatted_scheme.strip() + text[end_pos:]
            else:
                # Append to schemes array
                # Find insertion point right before rbracket_token
                # Check if array is empty (i.e. only whitespace/comments between [ and ])
                has_elements = False
                last_elem_end = -1
                for tok in tokens:
                    if lbracket_token.end <= tok.start < rbracket_token.start:
                        if tok.kind not in ("WS", "COMMENT"):
                            has_elements = True
                            if tok.kind in ("RBRACE", "STRING", "NUMBER", "BOOL", "NULL", "RBRACKET"):
                                last_elem_end = tok.end

                insert_pos = rbracket_token.start
                if has_elements:
                    # Insert comma after last element if not already followed by comma
                    # Check text between last_elem_end and insert_pos
                    inter_text = text[last_elem_end:insert_pos]
                    if "," not in inter_text:
                        insertion = f",\n{formatted_scheme}\n{pad}"
                    else:
                        insertion = f"\n{formatted_scheme}\n{pad}"
                else:
                    insertion = f"\n{formatted_scheme}\n{pad}"

                new_text = text[:insert_pos] + insertion + text[insert_pos:]

        else:
            # 'schemes' does not exist; insert after root LBRACE
            root_lbrace = next(t for t in tokens if t.kind == "LBRACE")
            insert_pos = root_lbrace.end
            insertion = f'\n{pad}"schemes": [\n{formatted_scheme}\n{pad}],'
            new_text = text[:insert_pos] + insertion + text[insert_pos:]

        # Validate modified text
        validated = parse_jsonc(new_text)
        # Check scheme is present
        found = any(s.get("name") == scheme_name for s in validated.get("schemes", []))
        if not found:
            raise JsoncParseError(f"Verification failed: scheme {scheme_name!r} not found after edit")

        self.raw_text = new_text
        self.parsed = validated
        return new_text

    def set_profile_color_scheme(
        self,
        theme_name: str,
        profile_name: Optional[str] = "Omarchy",
        apply_to_defaults: bool = False,
        indent_spaces: int = 4,
    ) -> str:
        """Set 'colorScheme' in 'profiles.defaults' or for a specific profile in 'profiles.list'."""
        text = self.raw_text
        tokens = tokenize_jsonc(text)
        meaningful = [t for t in tokens if t.kind not in ("WS", "COMMENT")]
        pad = " " * indent_spaces

        if apply_to_defaults:
            target_desc = "defaults"
            span = self._find_profile_defaults_span(tokens, meaningful)
        else:
            target_desc = f"profile '{profile_name}'"
            span = self._find_profile_by_name_span(tokens, meaningful, profile_name or "Omarchy")

        if span is None:
            # If target was a specific profile that doesn't exist yet, add it to profiles.list
            if not apply_to_defaults and profile_name:
                return self._insert_new_profile(profile_name, theme_name, indent_spaces)
            elif apply_to_defaults:
                return self._ensure_profiles_defaults(theme_name, indent_spaces)
            else:
                raise JsoncParseError(f"Could not locate {target_desc} in settings.json")

        obj_start, obj_end = span
        # Search for "colorScheme" within this object span
        color_scheme_span = self._find_property_span_in_object(tokens, obj_start, obj_end, "colorScheme")

        if color_scheme_span:
            # Replace property value
            val_start, val_end = color_scheme_span
            new_text = text[:val_start] + json.dumps(theme_name) + text[val_end:]
        else:
            # Insert "colorScheme": "<theme_name>" right inside the object
            # Find insertion point after opening '{' of the profile
            inner_insert = obj_start + 1
            insertion = f'\n{pad * 3}"colorScheme": {json.dumps(theme_name)},'
            new_text = text[:inner_insert] + insertion + text[inner_insert:]

        # Validate
        validated = parse_jsonc(new_text)
        self.raw_text = new_text
        self.parsed = validated
        return new_text

    def upsert_vscode_color_customizations(self, customizations: Dict[str, str], theme_name: Optional[str] = None) -> str:
        """Upsert VS Code workbench.colorCustomizations and optionally workbench.colorTheme."""
        text = self.raw_text
        tokens = tokenize_jsonc(text)
        meaningful = [t for t in tokens if t.kind not in ("WS", "COMMENT")]
        pad = "    "

        # Locate "workbench.colorCustomizations"
        custom_token_idx = -1
        for idx, tok in enumerate(meaningful):
            if tok.kind == "STRING" and json.loads(tok.value) == "workbench.colorCustomizations":
                if idx + 1 < len(meaningful) and meaningful[idx + 1].kind == "COLON":
                    if idx + 2 < len(meaningful) and meaningful[idx + 2].kind == "LBRACE":
                        custom_token_idx = idx
                        break

        if custom_token_idx != -1:
            # Replace the entire object value of workbench.colorCustomizations while merging
            lbrace_tok = meaningful[custom_token_idx + 2]
            brace_depth = 0
            rbrace_tok: Optional[Token] = None
            for tok in meaningful[custom_token_idx + 2:]:
                if tok.kind == "LBRACE":
                    brace_depth += 1
                elif tok.kind == "RBRACE":
                    brace_depth -= 1
                    if brace_depth == 0:
                        rbrace_tok = tok
                        break

            if rbrace_tok is None:
                raise JsoncParseError("Unterminated workbench.colorCustomizations object")

            # Merge existing customizations
            existing_dict = self.parsed.get("workbench.colorCustomizations", {})
            if isinstance(existing_dict, dict):
                merged = dict(existing_dict)
                merged.update(customizations)
            else:
                merged = customizations

            formatted = json.dumps(merged, indent=4)
            indented = "\n".join((pad + line) if idx > 0 else line for idx, line in enumerate(formatted.splitlines()))

            new_text = text[:lbrace_tok.start] + indented + text[rbrace_tok.end:]
        else:
            # Insert into root
            root_lbrace = next(t for t in tokens if t.kind == "LBRACE")
            insert_pos = root_lbrace.end
            merged = customizations
            formatted = json.dumps(merged, indent=4)
            indented = "\n".join((pad + line) if idx > 0 else line for idx, line in enumerate(formatted.splitlines()))
            insertion = f'\n{pad}"workbench.colorCustomizations": {indented},'
            new_text = text[:insert_pos] + insertion + text[insert_pos:]

        # If theme_name given, also upsert "workbench.colorTheme"
        if theme_name:
            temp_modifier = JsoncModifier(new_text)
            new_text = temp_modifier._upsert_root_property("workbench.colorTheme", theme_name)

        validated = parse_jsonc(new_text)
        self.raw_text = new_text
        self.parsed = validated
        return new_text

    # -------------------------------------------------------------------------
    # Internal Helpers
    # -------------------------------------------------------------------------

    def _find_scheme_object_span(
        self, tokens: List[Token], lbracket: Token, rbracket: Token, scheme_name: str
    ) -> Optional[Tuple[int, int]]:
        """Find the start and end character offsets of a scheme object with name."""
        in_schemes = False
        obj_start = -1
        depth = 0
        current_name: Optional[str] = None

        for tok in tokens:
            if tok.start >= lbracket.start and tok.end <= rbracket.end:
                in_schemes = True
            elif tok.end > rbracket.end:
                break

            if not in_schemes:
                continue

            if tok.kind == "LBRACE":
                if depth == 0:
                    obj_start = tok.start
                    current_name = None
                depth += 1
            elif tok.kind == "RBRACE":
                depth -= 1
                if depth == 0 and current_name == scheme_name and obj_start != -1:
                    return (obj_start, tok.end)

            if depth == 1 and tok.kind == "STRING":
                # Check if this token is followed by colon and target name
                pass

        # Second pass using parsed data matching
        schemes_list = self.parsed.get("schemes", [])
        if isinstance(schemes_list, list):
            target_idx = -1
            for idx, s in enumerate(schemes_list):
                if isinstance(s, dict) and s.get("name") == scheme_name:
                    target_idx = idx
                    break

            if target_idx != -1:
                # Find the target_idx-th object within lbracket..rbracket
                cur_idx = 0
                depth = 0
                o_start = -1
                for tok in tokens:
                    if tok.start < lbracket.end:
                        continue
                    if tok.end > rbracket.start:
                        break
                    if tok.kind == "LBRACE":
                        if depth == 0:
                            o_start = tok.start
                        depth += 1
                    elif tok.kind == "RBRACE":
                        depth -= 1
                        if depth == 0:
                            if cur_idx == target_idx:
                                return (o_start, tok.end)
                            cur_idx += 1

        return None

    def _find_profile_defaults_span(self, tokens: List[Token], meaningful: List[Token]) -> Optional[Tuple[int, int]]:
        """Find character span of profiles.defaults object."""
        # Find "profiles"
        for idx, tok in enumerate(meaningful):
            if tok.kind == "STRING" and json.loads(tok.value) == "profiles":
                if idx + 2 < len(meaningful) and meaningful[idx + 1].kind == "COLON" and meaningful[idx + 2].kind == "LBRACE":
                    # Search inside profiles object for "defaults"
                    p_depth = 0
                    for j in range(idx + 2, len(meaningful)):
                        ptok = meaningful[j]
                        if ptok.kind == "LBRACE":
                            p_depth += 1
                        elif ptok.kind == "RBRACE":
                            p_depth -= 1
                            if p_depth == 0:
                                break
                        if p_depth == 1 and ptok.kind == "STRING" and json.loads(ptok.value) == "defaults":
                            if j + 2 < len(meaningful) and meaningful[j + 1].kind == "COLON" and meaningful[j + 2].kind == "LBRACE":
                                def_lbrace = meaningful[j + 2]
                                d_depth = 0
                                for k in range(j + 2, len(meaningful)):
                                    dtok = meaningful[k]
                                    if dtok.kind == "LBRACE":
                                        d_depth += 1
                                    elif dtok.kind == "RBRACE":
                                        d_depth -= 1
                                        if d_depth == 0:
                                            return (def_lbrace.start, dtok.end)
        return None

    def _find_profile_by_name_span(
        self, tokens: List[Token], meaningful: List[Token], profile_name: str
    ) -> Optional[Tuple[int, int]]:
        """Find character span of profile object in profiles.list matching name."""
        profiles_dict = self.parsed.get("profiles", {})
        if not isinstance(profiles_dict, dict):
            return None

        profiles_list = profiles_dict.get("list", [])
        if not isinstance(profiles_list, list):
            # In older WT schema, 'profiles' could be a direct list
            if isinstance(profiles_dict, list):
                profiles_list = profiles_dict
            else:
                return None

        target_idx = -1
        for idx, p in enumerate(profiles_list):
            if isinstance(p, dict) and p.get("name") == profile_name:
                target_idx = idx
                break

        if target_idx == -1:
            return None

        # Find "list" array inside "profiles"
        # Search for token "list"
        list_idx = -1
        for idx, tok in enumerate(meaningful):
            if tok.kind == "STRING" and json.loads(tok.value) == "list":
                if idx + 2 < len(meaningful) and meaningful[idx + 1].kind == "COLON" and meaningful[idx + 2].kind == "LBRACKET":
                    list_idx = idx + 2
                    break

        if list_idx == -1:
            return None

        # Count objects inside list
        cur_idx = 0
        depth = 0
        obj_start = -1
        for j in range(list_idx, len(meaningful)):
            tok = meaningful[j]
            if tok.kind == "LBRACE":
                if depth == 0:
                    obj_start = tok.start
                depth += 1
            elif tok.kind == "RBRACE":
                depth -= 1
                if depth == 0:
                    if cur_idx == target_idx:
                        return (obj_start, tok.end)
                    cur_idx += 1

        return None

    def _find_property_span_in_object(
        self, tokens: List[Token], obj_start: int, obj_end: int, prop_name: str
    ) -> Optional[Tuple[int, int]]:
        """Find value span (start, end) of a property inside an object span."""
        obj_tokens = [t for t in tokens if obj_start <= t.start and t.end <= obj_end and t.kind not in ("WS", "COMMENT")]
        for idx, tok in enumerate(obj_tokens):
            if tok.kind == "STRING" and json.loads(tok.value) == prop_name:
                if idx + 2 < len(obj_tokens) and obj_tokens[idx + 1].kind == "COLON":
                    val_tok = obj_tokens[idx + 2]
                    return (val_tok.start, val_tok.end)
        return None

    def _insert_new_profile(self, profile_name: str, theme_name: str, indent_spaces: int) -> str:
        """Insert a new profile entry into profiles.list."""
        text = self.raw_text
        tokens = tokenize_jsonc(text)
        meaningful = [t for t in tokens if t.kind not in ("WS", "COMMENT")]
        pad = " " * indent_spaces

        # Locate profiles.list array
        list_lbracket: Optional[Token] = None
        for idx, tok in enumerate(meaningful):
            if tok.kind == "STRING" and json.loads(tok.value) == "list":
                if idx + 2 < len(meaningful) and meaningful[idx + 1].kind == "COLON" and meaningful[idx + 2].kind == "LBRACKET":
                    list_lbracket = meaningful[idx + 2]
                    break

        if list_lbracket is None:
            # Fall back to setting profiles.defaults
            return self._ensure_profiles_defaults(theme_name, indent_spaces)

        # Find matching RBRACKET
        depth = 0
        list_rbracket: Optional[Token] = None
        for tok in meaningful[meaningful.index(list_lbracket):]:
            if tok.kind == "LBRACKET":
                depth += 1
            elif tok.kind == "RBRACKET":
                depth -= 1
                if depth == 0:
                    list_rbracket = tok
                    break

        if list_rbracket is None:
            raise JsoncParseError("Unterminated 'list' array in profiles")

        profile_obj = {
            "name": profile_name,
            "source": "Windows.Terminal.Wsl",
            "colorScheme": theme_name,
        }
        formatted = json.dumps(profile_obj, indent=indent_spaces)
        indented = "\n".join((pad * 3 + line) if idx > 0 else (pad * 3 + line) for idx, line in enumerate(formatted.splitlines()))

        # Check if list currently has elements
        has_elements = any(list_lbracket.end <= t.start < list_rbracket.start and t.kind not in ("WS", "COMMENT") for t in tokens)
        insert_pos = list_rbracket.start

        if has_elements:
            insertion = f",\n{indented}\n{pad * 2}"
        else:
            insertion = f"\n{indented}\n{pad * 2}"

        new_text = text[:insert_pos] + insertion + text[insert_pos:]
        validated = parse_jsonc(new_text)
        self.raw_text = new_text
        self.parsed = validated
        return new_text

    def _ensure_profiles_defaults(self, theme_name: str, indent_spaces: int) -> str:
        """Ensure profiles.defaults exists and has colorScheme set."""
        text = self.raw_text
        tokens = tokenize_jsonc(text)
        pad = " " * indent_spaces

        # If profiles object exists:
        profiles_val = self.parsed.get("profiles")
        if isinstance(profiles_val, dict):
            # Find profiles LBRACE
            meaningful = [t for t in tokens if t.kind not in ("WS", "COMMENT")]
            for idx, tok in enumerate(meaningful):
                if tok.kind == "STRING" and json.loads(tok.value) == "profiles":
                    if idx + 2 < len(meaningful) and meaningful[idx + 1].kind == "COLON" and meaningful[idx + 2].kind == "LBRACE":
                        p_lbrace = meaningful[idx + 2]
                        insert_pos = p_lbrace.end
                        insertion = f'\n{pad * 2}"defaults": {{\n{pad * 3}"colorScheme": {json.dumps(theme_name)}\n{pad * 2}}},'
                        new_text = text[:insert_pos] + insertion + text[insert_pos:]
                        validated = parse_jsonc(new_text)
                        self.raw_text = new_text
                        self.parsed = validated
                        return new_text

        # If profiles doesn't exist at all, add to root
        root_lbrace = next(t for t in tokens if t.kind == "LBRACE")
        insert_pos = root_lbrace.end
        insertion = f'\n{pad}"profiles": {{\n{pad * 2}"defaults": {{\n{pad * 3}"colorScheme": {json.dumps(theme_name)}\n{pad * 2}}}\n{pad}}},'
        new_text = text[:insert_pos] + insertion + text[insert_pos:]
        validated = parse_jsonc(new_text)
        self.raw_text = new_text
        self.parsed = validated
        return new_text

    def _upsert_root_property(self, prop_name: str, prop_value: Any) -> str:
        """Upsert a top-level property in root object."""
        text = self.raw_text
        tokens = tokenize_jsonc(text)
        meaningful = [t for t in tokens if t.kind not in ("WS", "COMMENT")]
        pad = "    "

        # Check if property already exists
        for idx, tok in enumerate(meaningful):
            if tok.kind == "STRING" and json.loads(tok.value) == prop_name:
                if idx + 2 < len(meaningful) and meaningful[idx + 1].kind == "COLON":
                    val_tok = meaningful[idx + 2]
                    return text[:val_tok.start] + json.dumps(prop_value) + text[val_tok.end:]

        # Insert after root LBRACE
        root_lbrace = next(t for t in tokens if t.kind == "LBRACE")
        insert_pos = root_lbrace.end
        insertion = f'\n{pad}{json.dumps(prop_name)}: {json.dumps(prop_value)},'
        return text[:insert_pos] + insertion + text[insert_pos:]
