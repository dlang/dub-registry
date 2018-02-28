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
import std.typecons;

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
static immutable string logoFormat = ".png";

/// throw an exception if the files already exist
alias DeleteExisting = Flag!"deleteExisting";
/// delete the input file after a successful conversion
alias DeleteFinish = Flag!"deleteFinish";

/**
 * Params:
 *   file = the file to convert
 *   name = the logo name to put in uploads/logos
 *   deleteExisting = if false, throw an exception if the files already exist
 *   deleteFinish = if true, delete the input file after a successful conversion
 * Returns: true on success, false otherwise
 * Throws: Exception if name is empty or logo already exists and deleteExisting is not true
 */
bool generateLogo(NativePath file, string name, DeleteExisting deleteExisting = DeleteExisting.no, DeleteFinish deleteFinish = DeleteFinish.yes) @safe
{
	if (!name.length)
		throw new Exception("name may not be empty");
	if (existsFile(buildPath(logoOutputFolder, name ~ logoFormat)))
	{
		if (deleteExisting)
			removeFile(buildPath(logoOutputFolder, name ~ logoFormat));
		else
			throw new Exception("logo " ~ logoFormat ~ " already exists");
	}
	static assert (isWeaklyIsolated!(typeof(&generateLogoUnsafe)));
	static assert (isWeaklyIsolated!NativePath);
	static assert (isWeaklyIsolated!string);
	auto success = (() @trusted => async(&generateLogoUnsafe, file, name).getResult())();
	if (existsFile(buildPath(logoOutputFolder, name ~ logoFormat)) && !success)
		removeFile(buildPath(logoOutputFolder, name ~ logoFormat));
	if (deleteFinish && success)
		removeFile(file);
	return success;
}

private bool generateLogoUnsafe(NativePath file, string name) @safe
{
	bool success;

	string base = buildPath(logoOutputFolder, name);
	string pngOutput = base ~ ".png";
	auto png = spawnProcess(["convert", file.toNativeString, "-resize", "512x512>", pngOutput]);

	if (png.wait == 0)
		success = true;

	return success;
}
