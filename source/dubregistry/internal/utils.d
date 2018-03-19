module dubregistry.internal.utils;

import vibe.core.core;
import vibe.core.concurrency;
import vibe.core.file;
import vibe.core.log;
import vibe.core.task;
import vibe.data.bson;
import vibe.inet.url;
import vibe.inet.path;

import core.time;
import std.algorithm : any, among;
import std.file : tempDir;
import std.format;
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
 * Returns: the PNG stream of the icon or empty on failure
 * Throws: Exception if input is invalid format, invalid dimension or times out
 */
bdata_t generateLogo(NativePath file) @safe
{
	static assert (isWeaklyIsolated!(typeof(&generateLogoUnsafe)));
	static assert (isWeaklyIsolated!NativePath);
	static assert (isWeaklyIsolated!LogoGenerateResponse);
	auto res = (() @trusted => async(&generateLogoUnsafe, file).getResult())();
	if (res.error.length)
		throw new Exception("Failed to generate logo: " ~ res.error);
	return res.data;
}

private struct LogoGenerateResponse
{
	bdata_t data;
	string error;
}

// need to return * here because stack returned values get destroyed for some reason...
private LogoGenerateResponse* generateLogoUnsafe(NativePath file) @safe
{
	import std.array : appender;

	// TODO: replace imagemagick command line tools with something like imageformats on dub

	// use [0] to only get first frame in gifs, has no effect on static images.
	string firstFrame = file.toNativeString ~ "[0]";

	auto sizeInfo = execute(["identify", "-format", "%w %h %m", firstFrame]);
	if (sizeInfo.status != 0)
		return new LogoGenerateResponse(null, "Malformed image.");
	int width, height;
	string format;
	uint filled = formattedRead(sizeInfo.output, "%d %d %s", width, height, format);
	if (filled < 3)
		return new LogoGenerateResponse(null, "Malformed metadata.");
	if (!format.among("PNG", "JPEG", "GIF", "BMP"))
		return new LogoGenerateResponse(null, "Invalid image format, only supporting png, jpeg, gif and bmp.");
	if (width < 2 || height < 2 || width > 2048 || height > 2048)
		return new LogoGenerateResponse(null, "Invalid image dimenstions, must be between 2x2 and 2048x2048.");

	auto png = pipeProcess(["timeout", "3", "convert", firstFrame, "-resize", "512x512>", "png:-"]);

	auto a = appender!(immutable(ubyte)[])();

	(() @trusted {
		foreach (chunk; png.stdout.byChunk(4096))
			a.put(chunk);
	})();

	auto result = png.pid.wait;
	if (result != 0)
	{
		if (result == 126)
			return new LogoGenerateResponse(null, "Conversion timed out");
		(() @trusted {
			foreach (error; png.stderr.byLine)
				logDiagnostic("convert error: %s", error);
		})();
		return new LogoGenerateResponse(null, "An unexpected error occured");
	}

	return new LogoGenerateResponse(a.data);
}
