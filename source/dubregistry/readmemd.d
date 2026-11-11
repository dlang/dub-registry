/**
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
*/
module dubregistry.readmemd;

import std.array : appender, Appender;
import std.string : indexOf, startsWith, toLower;

/// Markdown ready for the package page, which does not render inline HTML.
struct PreparedReadme {
	string text;
	/// True when HTML tags were recognized and left out.
	bool htmlOmitted;
}

/**
	Prepare a readme for the package page.

	The page renders Markdown with inline HTML disabled. `<br>` and
	autolinks still render, so those stay. Known HTML tags are left out,
	and `htmlOmitted` is set so the page can say so. Text inside ordinary
	tags stays. A name that is not an HTML tag stays, including a line that
	starts with `<T>`. Fenced code and inline code stay as written.

	`img` tags are not shown. Their alt text is kept, because that is the
	label a reader would have seen.
*/
PreparedReadme prepareReadmeMarkdown(string source) @safe pure
{
	auto app = appender!string();
	bool omitted;
	bool inFence;
	char fenceChar;
	size_t fenceLen;
	bool onlyWs = true;
	size_t i;

	while (i < source.length) {
		if (!inFence && onlyWs && isOpeningFence(source, i, fenceChar, fenceLen)) {
			copyThroughNewline(app, source, i);
			inFence = true;
			onlyWs = true;
			continue;
		}
		if (inFence) {
			if (onlyWs && isClosingFence(source, i, fenceChar, fenceLen)) {
				copyThroughNewline(app, source, i);
				inFence = false;
				onlyWs = true;
				continue;
			}
			char c = source[i++];
			app.put(c);
			onlyWs = advanceWs(onlyWs, c);
			continue;
		}
		if (source[i] == '`') {
			size_t n = runLength(source, i, '`');
			auto close = findRun(source, i + n, '`', n);
			if (close != size_t.max) {
				app.put(source[i .. close + n]);
				i = close + n;
				onlyWs = false;
				continue;
			}
		}
		if (source[i] == '<') {
			bool wrote;
			if (consumeHtml(source, i, app, omitted, wrote)) {
				if (wrote) onlyWs = false;
				continue;
			}
		}
		char c = source[i++];
		app.put(c);
		onlyWs = advanceWs(onlyWs, c);
	}

	return PreparedReadme(app.data, omitted);
}

private bool advanceWs(bool onlyWs, char c) @safe pure
{
	if (c == '\n') return true;
	if (c == ' ' || c == '\t' || c == '\r') return onlyWs;
	return false;
}

private void copyThroughNewline(ref Appender!string app, string s, ref size_t i) @safe pure
{
	while (i < s.length) {
		char c = s[i++];
		app.put(c);
		if (c == '\n') break;
	}
}

private size_t runLength(string s, size_t i, char ch) @safe pure
{
	size_t n;
	while (i + n < s.length && s[i + n] == ch) n++;
	return n;
}

private size_t findRun(string s, size_t from, char ch, size_t n) @safe pure
{
	if (n == 0) return size_t.max;
	for (size_t i = from; i + n <= s.length; ) {
		if (s[i] != ch) {
			i++;
			continue;
		}
		size_t k = runLength(s, i, ch);
		if (k == n) return i;
		i += k;
	}
	return size_t.max;
}

private bool isOpeningFence(string s, size_t i, out char ch, out size_t len) @safe pure
{
	if (i >= s.length) return false;
	ch = s[i];
	if (ch != '`' && ch != '~') return false;
	len = runLength(s, i, ch);
	if (len < 3) return false;
	size_t j = i + len;
	while (j < s.length && s[j] != '\n') {
		if (s[j] == ch) return false;
		j++;
	}
	return true;
}

private bool isClosingFence(string s, size_t i, char ch, size_t len) @safe pure
{
	if (runLength(s, i, ch) < len) return false;
	size_t j = i + runLength(s, i, ch);
	while (j < s.length && s[j] != '\n') {
		if (s[j] != ' ' && s[j] != '\t' && s[j] != '\r') return false;
		j++;
	}
	return true;
}

private bool consumeHtml(string s, ref size_t i, ref Appender!string app, ref bool omitted, out bool wrote)
	@safe pure
{
	wrote = false;
	if (i >= s.length || s[i] != '<') return false;
	size_t j = i + 1;
	if (j >= s.length) return false;

	if (s[j .. $].startsWith("!--")) {
		auto end = indexOf(s[j + 3 .. $], "-->");
		omitted = true;
		if (end < 0) {
			while (i < s.length && s[i] != '\n') i++;
			return true;
		}
		i = j + 3 + end + 3;
		return true;
	}
	if (s[j] == '!') {
		auto gt = findTagEnd(s, j);
		if (gt == size_t.max) return false;
		omitted = true;
		i = gt + 1;
		return true;
	}
	if (s[j] == '?') {
		auto end = indexOf(s[j .. $], "?>");
		if (end < 0) return false;
		omitted = true;
		i = j + end + 2;
		return true;
	}

	bool closing;
	if (s[j] == '/') {
		closing = true;
		j++;
	}
	size_t nameStart = j;
	if (j >= s.length || !isAlpha(s[j])) return false;
	j++;
	while (j < s.length && isTagChar(s[j])) j++;
	if (j >= s.length) return false;
	char next = s[j];
	if (next != ' ' && next != '\t' && next != '\n' && next != '\r' && next != '/' && next != '>')
		return false;

	string name = s[nameStart .. j].toLower;
	if (!isKnownHtmlTag(name)) return false;
	auto gt = findTagEnd(s, j);
	if (gt == size_t.max) return false;

	bool selfClosing = gt > j && s[gt - 1] == '/';
	if (name == "br" && !closing) {
		app.put("<br/>");
		wrote = true;
		i = gt + 1;
		return true;
	}
	if ((name == "script" || name == "style") && !closing && !selfClosing) {
		i = skipUntilClose(s, gt + 1, name);
		omitted = true;
		return true;
	}
	if (name == "img" && !closing) {
		auto alt = attributeValue(s[j .. gt], "alt");
		if (alt.length) {
			if (app.data.length && !isSpace(app.data[$ - 1]) && !isSpace(alt[0]))
				app.put(' ');
			app.put(alt);
			if (gt + 1 < s.length && isTagChar(s[gt + 1]))
				app.put(' ');
			wrote = true;
		}
	}
	omitted = true;
	i = gt + 1;
	return true;
}

private size_t findTagEnd(string s, size_t j) @safe pure
{
	bool inDq, inSq;
	for (size_t k = j; k < s.length; k++) {
		char c = s[k];
		if (inDq) {
			if (c == '"') inDq = false;
			continue;
		}
		if (inSq) {
			if (c == '\'') inSq = false;
			continue;
		}
		if (c == '"') { inDq = true; continue; }
		if (c == '\'') { inSq = true; continue; }
		if (c == '>') return k;
	}
	return size_t.max;
}

private size_t skipUntilClose(string s, size_t from, string name) @safe pure
{
	string closer = "</" ~ name;
	size_t i = from;
	while (i + closer.length <= s.length) {
		if (s[i .. i + closer.length].toLower == closer) {
			auto gt = findTagEnd(s, i + closer.length);
			if (gt != size_t.max) return gt + 1;
		}
		i++;
	}
	return s.length;
}

private string attributeValue(string attrs, string key) @safe pure
{
	string low = attrs.toLower;
	string needle = key ~ "=";
	size_t from;
	while (from < low.length) {
		auto idx = indexOf(low, needle, from);
		if (idx < 0) return null;
		bool boundary = idx == 0 || isSpace(low[idx - 1]) || low[idx - 1] == '/';
		if (boundary) {
			size_t v = idx + needle.length;
			if (v < attrs.length && (attrs[v] == '"' || attrs[v] == '\'')) {
				char q = attrs[v];
				auto end = indexOf(attrs, q, v + 1);
				if (end < 0) return null;
				return attrs[v + 1 .. end];
			}
			size_t e = v;
			while (e < attrs.length && !isSpace(attrs[e]) && attrs[e] != '/' && attrs[e] != '>')
				e++;
			return attrs[v .. e];
		}
		from = idx + needle.length;
	}
	return null;
}

private bool isKnownHtmlTag(string name) @safe pure
{
	switch (name) {
		case "a", "abbr", "address", "area", "article", "aside", "audio":
		case "b", "base", "bdi", "bdo", "blockquote", "body", "br", "button":
		case "canvas", "caption", "center", "cite", "code", "col", "colgroup":
		case "data", "datalist", "dd", "del", "details", "dfn", "dialog", "div":
		case "dl", "dt", "em", "embed", "fieldset", "figcaption", "figure":
		case "font", "footer", "form":
		case "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr":
		case "html", "i", "iframe", "img", "input", "ins", "kbd", "label":
		case "legend", "li", "link", "main", "map", "mark", "meta", "meter":
		case "nav", "nobr", "noscript", "object", "ol", "optgroup", "option":
		case "output", "p", "param", "picture", "pre", "progress", "q":
		case "rp", "rt", "ruby", "s", "samp", "script", "section", "select":
		case "small", "source", "span", "strong", "style", "sub", "summary":
		case "sup", "svg", "table", "tbody", "td", "template", "textarea":
		case "tfoot", "th", "thead", "time", "title", "tr", "track", "tt":
		case "u", "ul", "var", "video", "wbr":
		case "path", "g", "use", "rect", "circle", "line", "polyline":
		case "polygon", "text", "tspan", "defs", "symbol":
			return true;
		default:
			return false;
	}
}

private bool isAlpha(char c) @safe pure
{
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

private bool isTagChar(char c) @safe pure
{
	return isAlpha(c) || (c >= '0' && c <= '9') || c == '-';
}

private bool isSpace(char c) @safe pure
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

@safe unittest
{
	auto plain = prepareReadmeMarkdown("# Hello\n\nA paragraph.\n");
	assert(!plain.htmlOmitted);
	assert(plain.text == "# Hello\n\nA paragraph.\n");

	auto link = prepareReadmeMarkdown("See <https://example.com> and <user@example.com>.\n");
	assert(!link.htmlOmitted);
	assert(link.text == "See <https://example.com> and <user@example.com>.\n");

	auto br = prepareReadmeMarkdown("One<br>two<br/>three<br />four\n");
	assert(!br.htmlOmitted);
	assert(br.text == "One<br/>two<br/>three<br/>four\n");

	auto block = prepareReadmeMarkdown("<div align=\"center\">\nHello\n</div>\n\n# Title\n");
	assert(block.htmlOmitted);
	assert(block.text == "\nHello\n\n\n# Title\n");

	auto img = prepareReadmeMarkdown("<a href=\"https://example.com\"><img src=\"x\" alt=\"License\"></a>\n");
	assert(img.htmlOmitted);
	assert(img.text == "License\n");

	auto code = prepareReadmeMarkdown("```html\n<div>keep</div>\n```\n`<div>` too\n");
	assert(!code.htmlOmitted);
	assert(code.text == "```html\n<div>keep</div>\n```\n`<div>` too\n");

	auto script = prepareReadmeMarkdown("<script>alert(1)</script>\n# Title\n");
	assert(script.htmlOmitted);
	assert(script.text == "\n# Title\n");

	auto note = prepareReadmeMarkdown("Before <!-- badge --> after\n");
	assert(note.htmlOmitted);
	assert(note.text == "Before  after\n");

	auto generic = prepareReadmeMarkdown("Use Foo<T> here.\n");
	assert(!generic.htmlOmitted);
	assert(generic.text == "Use Foo<T> here.\n");

	auto widget = prepareReadmeMarkdown("<widget>\ninner\n</widget>\n");
	assert(!widget.htmlOmitted);
	assert(widget.text == "<widget>\ninner\n</widget>\n");

	auto genericLine = prepareReadmeMarkdown("<T>\nnext\n");
	assert(!genericLine.htmlOmitted);
	assert(genericLine.text == "<T>\nnext\n");

	char[] filler;
	filler.length = 9000;
	filler[] = 'x';
	auto longComment = prepareReadmeMarkdown("A <!--" ~ filler.idup ~ "--> B\n");
	assert(longComment.htmlOmitted);
	assert(longComment.text == "A  B\n");
}

/** Markdown is the only readme this scanner should rewrite. */
bool readmeOmitsUnreadHtml(string format) @safe pure
{
	import std.uni : toLower;
	auto f = format.toLower;
	return f.length == 0 || f == "markdown" || f == "md";
}

@safe unittest
{
	assert(readmeOmitsUnreadHtml(""));
	assert(readmeOmitsUnreadHtml("markdown"));
	assert(readmeOmitsUnreadHtml("MD"));
	assert(!readmeOmitsUnreadHtml("asciidoc"));
	assert(!readmeOmitsUnreadHtml("plain"));
}
