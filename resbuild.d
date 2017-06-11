#!/usr/bin/env dub
/+
dub.json:
{
	"name": "resbuild",
	"description": "Resource builder for dub-registry"
}
+/

import std.stdio;
import std.file : exists, copy, mkdirRecurse, FileException;
import std.path : dirName;
import std.datetime : SysTime;

interface Command {
	void run(string i, string o);
}

class CopyCommand : Command {
	this() {}

	void run(string i, string o) {
		if(!o.exists || (i.hashOf != o.hashOf)) {
			try {
				if(!o.dirName.exists)
					o.dirName.mkdirRecurse;
				copy(i, o);
			} catch (FileException e) {
				throw new Exception("Error while copying " ~ i ~ " -> " ~ o, e);
			}
		}
	}
}

ubyte[4] hashOf(string i) {
	if(!i.exists)
		throw new Exception("File "~ i ~" does not exists");
	import std.digest.crc;
	CRC32 hash;
	hash.start;
	foreach(ref b; File(i, "rb").byChunk(8192))
		hash.put(b);
	return hash.finish;
}

struct Rule {
	string Source;
	string Target;
	Command Cmd;

	this(string name) {
		this(name, new CopyCommand());
	}

	this(string name, Command cmd) {
		this.Source = "assets/" ~ name;
		this.Target = "public/" ~ name;
		this.Cmd = cmd;
	}
}

struct RuleGroup {
	string Name;
	Rule[] Rules;
}

RuleGroup[] Rules = [
	RuleGroup("fonts", [
		Rule("fonts/fontello.woff")
	]),
	RuleGroup("images", [
		Rule("images/clippy.svg"),
		Rule("images/dub-header.png"),
		Rule("images/dub-logo.png"),
		Rule("images/logo-small.png"),
		Rule("images/categories/application.desktop.development.png"),
		Rule("images/categories/application.desktop.editor.png"),
		Rule("images/categories/application.desktop.game.png"),
		Rule("images/categories/application.desktop.graphics.png"),
		Rule("images/categories/application.desktop.network.png"),
		Rule("images/categories/application.desktop.photo.png"),
		Rule("images/categories/application.desktop.productivity.png"),
		Rule("images/categories/application.desktop.web.png"),
		Rule("images/categories/application.png"),
		Rule("images/categories/application.server.png"),
		Rule("images/categories/application.web.png"),
		Rule("images/categories/library.audio.png"),
		Rule("images/categories/library.binding.png"),
		Rule("images/categories/library.crypto.png"),
		Rule("images/categories/library.development.png"),
		Rule("images/categories/library.graphics.png"),
		Rule("images/categories/library.png"),
		Rule("images/categories/library.web.png"),
		Rule("images/categories/unknown.png"),
	]),
	RuleGroup("scripts", [
		Rule("scripts/clipboard.min.js"),
		Rule("scripts/home.js"),
		Rule("scripts/menu.js"),
	]),
	RuleGroup("styles", [
		Rule("styles/common.css"),
		Rule("styles/markdown.css"),
		Rule("styles/top.css"),
		Rule("styles/top_p.css"),
	]),
	RuleGroup("favicon", [
		Rule("favicon.ico")
	])
];

int main(string[] args) {
	foreach(ref rg; Rules) {
		foreach(ref rule; rg.Rules) {
			rule.Cmd.run(rule.Source, rule.Target);
		}
	}
	return 0;
}
