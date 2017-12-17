module dubregistry.internal.utils;

import vibe.core.core;
import vibe.core.concurrency;
import vibe.core.task;
import vibe.inet.url;
import vibe.inet.path;

import std.algorithm : any;
import std.file : tempDir;
import std.path;
import std.process;

URL black(URL url)
{
	if (url.username.length > 0)
		url.username = "***";
	if (url.password.length > 0)
		url.password = "***";
	return url;
}

string black(string url)
{
	return black(URL(url)).toString();
}

static immutable string logoOutputFolder = "uploads/logos";

static immutable string[] logoFormats = [".webp", ".png"];

/// 
/// Params:
///   file = the file to convert
///   name = the logo name to put in uploads/logos
///   deleteExisting = if false, throw an exception if the files already exist
///   deleteFinish = if true, delete the input file after at least one successful conversion
auto generateLogo(Path file, string name, bool deleteExisting = false, bool deleteFinish = true)
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
	auto t = runWorkerTaskH(&generateLogoUnsafe, Task.getThis(), file, name);
	auto success = receiveOnlyCompat!(bool[logoFormats.length]);
	foreach (i, format; logoFormats)
		if (existsFile(buildPath(logoOutputFolder, name ~ format)) && !success[i])
			removeFile(buildPath(logoOutputFolder, name ~ format));
	if (deleteFinish && success[].any)
		removeFile(file);
	return success;
}

private void generateLogoUnsafe(Task owner, Path file, string name)
{
	try
	{
		bool[logoFormats.length] success;
		scope (success)
			sendCompat(owner, success);

		string base = buildPath(logoOutputFolder, name);
		string pngOutput = base ~ ".png";
		auto png = spawnProcess(["convert", file.toNativeString, "-resize", "512x512>", pngOutput]);

		if (png.wait == 0)
			success[1] = true;

		string webpOutput = base ~ ".webp";
		auto webp = spawnProcess(["cwebp", "-q", "85", pngOutput, "-o", webpOutput]);

		if (webp.wait == 0)
			success[0] = true;
	}
	catch (Exception e)
	{
		sendCompat(owner, e);
	}
}
