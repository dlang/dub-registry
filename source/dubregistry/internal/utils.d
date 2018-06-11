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
import std.algorithm : any, among, splitter;
import std.file : tempDir;
import std.format;
import std.path;
import std.process;
import std.string : indexOf, startsWith;
import std.typecons;

URL black(URL url)
@safe {
	if (url.username.length > 0) url.username = "***";
	if (url.password.length > 0) url.password = "***";
	if (url.queryString.length > 0) {
		size_t i;
		char[] replace;
		foreach (part; url.queryString.splitter('&')) {
			if (part.startsWith("secret", "private")) {
				if (!replace)
					replace = url.queryString.dup;
				auto eq = replace.indexOf('=', i) + 1;
				if (eq < i + part.length) { // only replace value if possible (key=value)
					replace = replace[0 .. eq] ~ "***" ~ replace[i + part.length .. $];
					i = eq + 3;
				} else { // otherwise replace the whole pair
					replace = replace[0 .. i] ~ "***" ~ replace[i + part.length .. $];
					i += 3;
				}
			} else {
				i += part.length;
			}
			i++; // '&'
		}
		if (replace)
			url.queryString = (() @trusted => cast(string) replace)();
	}
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
bdata_t generateLogo(NativePath file) @trusted
{
	import std.concurrency : send, receiveOnly, Tid;
	static assert (isWeaklyIsolated!(typeof(&generateLogoUnsafe)));
	static assert (isWeaklyIsolated!NativePath);
	static assert (isWeaklyIsolated!LogoGenerateResponse);

	runWorkerTask((NativePath file, Tid par) { par.send(generateLogoUnsafe(file)); }, file, thisTid);
	auto res = receiveOnly!LogoGenerateResponse();
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
private LogoGenerateResponse generateLogoUnsafe(NativePath file) @safe nothrow
{
	import std.array : appender;

	// TODO: replace imagemagick command line tools with something like imageformats on dub

	// use [0] to only get first frame in gifs, has no effect on static images.
	string firstFrame = file.toNativeString ~ "[0]";

	try {
		auto sizeInfo = execute(["identify", "-format", "%w %h %m", firstFrame]);
		if (sizeInfo.status != 0)
			return LogoGenerateResponse(null, "Malformed image.");
		int width, height;
		string format;
		uint filled = formattedRead(sizeInfo.output, "%d %d %s", width, height, format);
		if (filled < 3)
			return LogoGenerateResponse(null, "Malformed metadata.");
		if (!format.among("PNG", "JPEG", "GIF", "BMP"))
			return LogoGenerateResponse(null, "Invalid image format, only supporting png, jpeg, gif and bmp.");
		if (width < 2 || height < 2 || width > 2048 || height > 2048)
			return LogoGenerateResponse(null, "Invalid image dimenstions, must be between 2x2 and 2048x2048.");

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
				return LogoGenerateResponse(null, "Conversion timed out");
			(() @trusted {
				foreach (error; png.stderr.byLine)
					logDiagnostic("convert error: %s", error);
			})();
			return LogoGenerateResponse(null, "An unexpected error occured");
		}

		return LogoGenerateResponse(a.data);
	} catch (Exception e) {
		return LogoGenerateResponse(null, "Failed to invoke the logo conversion process.");
	}
}


/** Performs deduplication and compact re-allocation of individual strings.

	Strings are allocated out of 64KB blocks of memory.
*/
struct PackedStringAllocator {
	private {
		char[] memory;
		string[string] map;
	}

	@disable this(this);

	string alloc(in char[] chars)
	@safe {
		import std.algorithm.comparison : max;

		if (auto pr = chars in map)
			return *pr;

		if (memory.length < chars.length) memory = new char[](max(chars.length, 64*1024));
		auto str = memory[0 .. chars.length];
		memory = memory[chars.length .. $];
		str[] = chars[];
		auto istr = () @trusted { return cast(string)str; } ();
		map[istr] = istr;
		return istr;
	}
}
