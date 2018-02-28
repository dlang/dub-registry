module dubregistry.internal.utils;

import vibe.core.core;
import vibe.core.concurrency;
import vibe.core.file;
import vibe.core.task;
import vibe.inet.url;
import vibe.inet.path;

import std.algorithm : any;
import std.file : tempDir;
import std.path;
import std.process;

URL black(URL url)
@safe {
	if (url.username.length > 0) url.username = "***";
	if (url.password.length > 0) url.password = "***";
	return url;
}

string black(string url)
@safe {
	return black(URL(url)).toString();
}

static immutable string logoOutputFolder = "uploads/logos";

static immutable string[] logoFormats = [".png"];

/// 
/// Params:
///   file = the file to convert
///   name = the logo name to put in uploads/logos
///   deleteExisting = if false, throw an exception if the files already exist
///   deleteFinish = if true, delete the input file after at least one successful conversion
auto generateLogo(NativePath file, string name, bool deleteExisting = false, bool deleteFinish = true) @safe
{
	if (!name.length)
		throw new Exception("name may not be empty");
	foreach (format; logoFormats)
		if (existsFile(buildPath(logoOutputFolder, name ~ format)))
		{
			if (deleteExisting)
				removeFile(buildPath(logoOutputFolder, name ~ format));
			else
				throw new Exception("logo " ~ format ~ " already exists");
		}
	static assert (isWeaklyIsolated!(typeof(&generateLogoUnsafe)));
	static assert (isWeaklyIsolated!NativePath);
	static assert (isWeaklyIsolated!string);
	auto success = (() @trusted => async(&generateLogoUnsafe, file, name).getResult())();
	foreach (i, format; logoFormats)
		if (existsFile(buildPath(logoOutputFolder, name ~ format)) && !success[i])
			removeFile(buildPath(logoOutputFolder, name ~ format));
	if (deleteFinish && success[].any)
		removeFile(file);
	return success;
}

private bool[logoFormats.length] generateLogoUnsafe(NativePath file, string name) @safe
{
	bool[logoFormats.length] success;

	string base = buildPath(logoOutputFolder, name);
	string pngOutput = base ~ ".png";
	auto png = spawnProcess(["convert", file.toNativeString, "-resize", "512x512>", pngOutput]);

	if (png.wait == 0)
		success[0] = true;

	return success;
}
