/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.viewutils;

import std.datetime;
import std.string;
import std.algorithm : canFind;
import vibe.data.json;

string formatDate(Json date)
{
	return formatDate(date.opt!string);
}

string formatDate(string iso_ext_date)
{
	if (iso_ext_date.length == 0) return "---";
	return formatDate(SysTime.fromISOExtString(iso_ext_date));
}

string formatDate(SysTime st)
{
	return (cast(Date)st).toSimpleString();
}

string formatDateTime(Json dateTime)
{
	return formatDateTime(dateTime.opt!string);
}

string formatDateTime(string iso_ext_date)
{
	if (iso_ext_date.length == 0) return "---";
	return formatDateTime(SysTime.fromISOExtString(iso_ext_date));
}

string formatDateTime(SysTime st)
{
	return st.toSimpleString();
}

string formatFuzzyDate(Json dateTime)
{
	return formatFuzzyDate(dateTime.opt!string);
}

string formatFuzzyDate(string iso_ext_date)
{
	if (iso_ext_date.length == 0) return "---";
	return formatFuzzyDate(SysTime.fromISOExtString(iso_ext_date));
}

string formatFuzzyDate(SysTime st)
{
	auto now = Clock.currTime(UTC());

	// TODO: proper singular forms etc. (probably done together with l8n)
	auto tm = now - st;
	if (tm < dur!"seconds"(0)) return "still going to happen";
	else if (tm < dur!"seconds"(1)) return "just now";
	else if (tm < dur!"minutes"(1)) return "less than a minute ago";
	else if (tm < dur!"minutes"(2)) return "a minute ago";
	else if (tm < dur!"hours"(1)) return format("%s minutes ago", tm.total!"minutes"());
	else if (tm < dur!"hours"(2)) return "an hour ago";
	else if (tm < dur!"days"(1)) return format("%s hours ago", tm.total!"hours"());
	else if (tm < dur!"days"(2)) return "a day ago";
	else if (tm < dur!"weeks"(5)) return format("%s days ago", tm.total!"days"());
	else if (tm < dur!"weeks"(52)) {
		auto m1 = st.month;
		auto m2 = now.month;
		auto months = (now.year - st.year) * 12 + m2 - m1;
		if (months == 1) return "a month ago";
		else return format("%s months ago", months);
	} else if (now.year - st.year <= 1) return "a year ago";
	else return format("%s years ago", now.year - st.year);
}

string formatScore(float score)
{
	return format(`<a href="https://dub.pm/dub-guide/publishing/#package-scoring">%.1f</a>`, score);
}

string formatPackageStats(Stats)(Stats s)
{
	return format("%.1f\n\n#downloads / m: %s\n#stars: %s\n#watchers: %s\n#forks: %s\n#issues: %s\n",
				  s.score, s.downloads.monthly, s.repo.stars, s.repo.watchers, s.repo.forks, s.repo.issues);
}

/** Takes an input range of version strings and returns the index of the "best"
	version.

	"Best" version in this case means the highest released version. Numbered
	versions will be preferred over branch names.

*/
size_t getBestVersionIndex(R)(R versions)
{
	import dub.semver;

	size_t ret = size_t.max;
	string retv;
	size_t i = 0;
	foreach (vstr; versions) {
		if (ret == size_t.max) {
			ret = i;
			retv = vstr;
		} else {
			if (retv.startsWith("~")) {
				if (vstr == "~master" || !vstr.startsWith("~")) {
					ret = i;
					retv = vstr;
				}
			} else if (!vstr.startsWith("~") && compareVersions(vstr, retv) > 0) {
				ret = i;
				retv = vstr;
			}
		}
		i++;
	}
	return ret;
}

unittest {
	assert(getBestVersionIndex(["~master", "0.0.1", "1.0.0"]) == 2);
	assert(getBestVersionIndex(["~master", "0.0.1-alpha"]) == 1);
	assert(getBestVersionIndex(["~somebranch", "~master"]) == 1);
	assert(getBestVersionIndex(["~master", "~somebranch"]) == 0);
	assert(getBestVersionIndex(["1.0.0", "1.0.1-alpha"]) == 1);
}

/** Detect README markup format from a file extension (including the leading dot). */
string readmeFormatFromExtension(string ext) @safe
{
	import std.uni : sicmp;
	if (ext.sicmp(".md") == 0 || ext.sicmp(".markdown") == 0)
		return "markdown";
	if (ext.sicmp(".adoc") == 0 || ext.sicmp(".asciidoc") == 0 || ext.sicmp(".asc") == 0)
		return "asciidoc";
	return "plain";
}

unittest {
	assert(readmeFormatFromExtension(".md") == "markdown");
	assert(readmeFormatFromExtension(".ADOC") == "asciidoc");
	assert(readmeFormatFromExtension(".asciidoc") == "asciidoc");
	assert(readmeFormatFromExtension(".txt") == "plain");
	assert(readmeFormatFromExtension("") == "plain");
}

/**
	Render a package README to HTML for the Info tab.

	Markdown uses vibe-d's filter (no inline HTML). AsciiDoc uses asciidoctor-d
	in secure fragment mode. Link and image URLs are allowlisted there
	(`http`, `https`, `mailto`, fragments, relative paths). Plain text is
	HTML-escaped inside a pre block.
*/
string renderReadmeHtml(string contents, string format,
	string delegate(string, bool) urlFilter = null)
{
	import vibe.textfilter.html : htmlEscape;

	switch (format.toLower) {
		case "markdown", "md":
			import vibe.textfilter.markdown : MarkdownFlags, MarkdownSettings, filterMarkdown;
			scope msettings = new MarkdownSettings;
			msettings.flags = MarkdownFlags.backtickCodeBlocks | MarkdownFlags.noInlineHtml | MarkdownFlags.tables;
			msettings.headingBaseLevel = 2;
			if (urlFilter !is null)
				msettings.urlFilter = urlFilter;
			return filterMarkdown(contents, msettings);
		case "asciidoc", "adoc":
			return renderAsciidocReadme(contents, urlFilter);
		default:
			return `<pre class="plain-readme">` ~ htmlEscape(contents) ~ `</pre>`;
	}
}

private string renderAsciidocReadme(string contents,
	string delegate(string, bool) urlFilter)
{
	import asciidoctor : ConvertOptions, convert;

	ConvertOptions opts;
	opts.backend = "html5";
	opts.standalone = false;
	opts.secure = true;
	opts.urlFilter = urlFilter;
	return convert(contents, opts);
}

unittest {
	auto html = renderReadmeHtml("link:javascript:alert(1)[click]\n\nhttps://example.com[ok]\n", "asciidoc");
	assert(html.canFind("click"));
	assert(!html.canFind("javascript:"));
	assert(html.canFind(`href="https://example.com"`));
}

unittest {
	auto html = renderReadmeHtml("image:photo.png[Alt]\n", "asciidoc", (string url, bool isImage) {
		if (isImage)
			return "https://cdn.example/" ~ url;
		return url;
	});
	assert(html.canFind(`src="https://cdn.example/photo.png"`));
}
