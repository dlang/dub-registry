module dubregistry.internal.utils;

import vibe.core.core;
import vibe.core.concurrency;
import vibe.core.file;
import vibe.core.log;
import vibe.core.task;
import vibe.data.bson;
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

/**
 * Params:
 *   file = the file to convert
 *   deleteFinish = if true, delete the input file after a successful conversion
 * Returns: the PNG stream of the icon or empty on failure
 * Throws: Exception if name is empty or logo already exists and deleteExisting is not true
 */
bdata_t generateLogo(NativePath file) @safe
{
	static assert (isWeaklyIsolated!(typeof(&generateLogoUnsafe)));
	static assert (isWeaklyIsolated!NativePath);
	return (() @trusted => async(&generateLogoUnsafe, file).getResult())();
}

private bdata_t generateLogoUnsafe(NativePath file) @safe
{
	import std.array : appender;

	auto png = pipeProcess(["convert", file.toNativeString, "-resize", "512x512>", "-"]);

	if (png.pid.wait != 0)
	{
		(() @trusted {
			foreach (error; png.stderr.byLine)
				logDebug("convert error: %s", error);
		})();
		return bdata_t.init;
	}

	auto a = appender!(ubyte[])();

	(() @trusted {
		foreach (chunk; png.stdout.byChunk(4096))
			a.put(chunk);
	})();

	return cast(bdata_t)a.data.idup;
}
