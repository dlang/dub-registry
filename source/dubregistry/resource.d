module dubregistry.resource;

import vibe.data.json;
import std.digest.crc : crc32Of;
import std.file : readText;

alias HASH = ubyte[4];

private string[HASH] Resources;

shared static this() {
	loadResources();
}

void loadResources() {
	try {
		auto j = "public/manifest.json".readText.parseJsonString;
		foreach(k,v; j.byKeyValue) {
			Resources[k.crc32Of] = v.to!string;
		}
	} catch(Exception e) {
		throw new Exception("Error while reading manifest.json", e);
	}
}

string getResource(HASH h) {
	if(h !in Resources)
		return "";

	return Resources[h];
}

string getResource(string s) {
	return s.crc32Of.getResource;
}
