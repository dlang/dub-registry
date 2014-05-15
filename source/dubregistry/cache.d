/**
	Copyright: © 2013-2014 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.cache;

import vibe.core.log;
import vibe.db.mongo.mongo;
import vibe.http.client;
import vibe.stream.memory;

import std.array : startsWith;
import std.exception;


class URLCache {
	private {
		MongoClient m_db;
		MongoCollection m_entries;
	}

	this()
	{
		m_db = connectMongoDB("127.0.0.1");
		m_entries = m_db.getCollection("urlcache.entries");
	}

	void clearEntry(URL url)
	{
		m_entries.remove(["url": url.toString()]);
	}

	void get(URL url, scope void delegate(scope InputStream str) callback, bool cache_priority = false)
	{
		import vibe.http.auth.basic_auth;

		auto user = url.username;
		auto password = url.password;
		url.username = null;
		url.password = null;

		auto be = m_entries.findOne(["url": url.toString()]);
		CacheEntry entry;
		if( !be.isNull() ) {
			deserializeBson(entry, be);
			if (cache_priority) {
				logDiagnostic("Cache HIT (early): %s", url.toString());
				auto data = be["data"].get!BsonBinData().rawData();
				scope result = new MemoryStream(cast(ubyte[])data, false);
				callback(result);
				return;
			}
		} else {
			entry._id = BsonObjectID.generate();
			entry.url = url.toString();
		}

		InputStream result;

		foreach (i; 0 .. 10) { // follow max 10 redirects
			requestHTTP(url,
				(scope req){
					if (entry.etag.length) req.headers["If-None-Match"] = entry.etag;
					if (user.length) addBasicAuth(req, user, password);
				},
				(scope res){
					switch (res.statusCode) {
						default:
							throw new Exception("Unexpected reply for '"~url.toString()~"': "~httpStatusText(res.statusCode));
						case HTTPStatus.notModified:
							logDiagnostic("Cache HIT: %s", url.toString());
							auto data = be["data"].get!BsonBinData().rawData();
							result = new MemoryStream(cast(ubyte[])data, false);
							break;
						case HTTPStatus.notFound:
							throw new FileNotFoundException("File '"~url.toString()~"' does not exist.");
						case HTTPStatus.movedPermanently, HTTPStatus.found, HTTPStatus.temporaryRedirect:
							auto pv = "Location" in res.headers;
							enforce(pv !is null, "Server responded with redirect but did not specify the redirect location for "~url.toString());
							logDebug("Redirect to '%s'", *pv);
							if (startsWith((*pv), "http:") || startsWith((*pv), "https:")) {
								url = URL(*pv);
							} else url.localURI = *pv;
							break;
						case HTTPStatus.ok:
							if (auto pet = "ETag" in res.headers) {
								logDiagnostic("Cache MISS: %s", url.toString());
								auto dst = new MemoryOutputStream;
								dst.write(res.bodyReader);
								auto rawdata = dst.data;
								entry.etag = *pet;
								entry.data = BsonBinData(BsonBinData.Type.Generic, cast(immutable)rawdata);
								m_entries.update(["_id": entry._id], entry, UpdateFlags.Upsert);
								result = new MemoryStream(rawdata, false);
								break;
							}

							logDebug("Response without etag.. not caching: "~url.toString());

							logDiagnostic("Cache MISS (no etag): %s", url.toString());
							callback(res.bodyReader);
							break;
					}
				}
			);

			if (result) {
				callback(result);
				return;
			}
		}

		throw new Exception("Too many redirects for "~url.toString());
	}
}

class FileNotFoundException : Exception {
	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}
}

private struct CacheEntry {
	BsonObjectID _id;
	string url;
	string etag;
	BsonBinData data;
}

private URLCache s_cache;

void downloadCached(URL url, scope void delegate(scope InputStream str) callback, bool cache_priority = false)
{
	if (!s_cache) s_cache = new URLCache;
	s_cache.get(url, callback, cache_priority);
}

void downloadCached(string url, scope void delegate(scope InputStream str) callback, bool cache_priority = false)
{
	return downloadCached(URL.parse(url), callback, cache_priority);
}

void clearCacheEntry(URL url)
{
	if (!s_cache) s_cache = new URLCache;
	s_cache.clearEntry(url);
}

void clearCacheEntry(string url)
{
	clearCacheEntry(URL(url));
}
