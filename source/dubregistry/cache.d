/**
	Copyright: © 2013-2014 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.cache;

import vibe.core.log;
import vibe.core.stream;
import vibe.db.mongo.mongo;
import vibe.http.client;
import vibe.stream.memory;

import core.time;
import std.algorithm : startsWith;
import std.exception;
import std.typecons : tuple;


enum CacheMatchMode {
	always, // return cached data if available
	etag,   // return cached data if the server responds with "not modified"
	never   // always request fresh data
}


class URLCache {
@safe:
	private {
		MongoClient m_db;
		MongoCollection m_entries;
		Duration m_maxCacheTime = 365.days;
	}

	this()
	{
		import dubregistry.mongodb : databaseName, getMongoClient;
		m_db = getMongoClient();
		m_entries = m_db.getDatabase(databaseName)["urlcache.entries"];
		m_entries.ensureIndex([tuple("url", 1)]);
	}

	void clearEntry(URL url)
	{
		m_entries.remove(["url": url.toString()]);
	}

	void get(URL url, scope void delegate(scope InputStream str) @safe callback, bool cache_priority = false)
	{
		get(url, callback, cache_priority ? CacheMatchMode.always : CacheMatchMode.etag);
	}

	void get(URL url, scope void delegate(scope InputStream str) @safe callback, CacheMatchMode mode = CacheMatchMode.etag)
	{
		import std.datetime : Clock, UTC;
		import vibe.http.auth.basic_auth;
		import dubregistry.internal.utils : black;
		import vibe.internal.interfaceproxy : asInterface;

		auto user = url.username;
		auto password = url.password;
		url.username = null;
		url.password = null;

		InputStream result;
		bool handled_uncached = false;

		auto now = Clock.currTime(UTC());

		foreach (i; 0 .. 10) { // follow max 10 redirects
			auto be = m_entries.findOne(["url": url.toString()]);
			CacheEntry entry;
			if (!be.isNull()) {
				// invalidate out of date cache entries
				if (be["_id"].get!BsonObjectID.timeStamp < now - m_maxCacheTime)
					m_entries.remove(["_id": be["_id"]]);

				deserializeBson(entry, be);
				if (mode == CacheMatchMode.always) {
					// directly return cache result for cache_priority == true
					logDiagnostic("Cache HIT (early): %s", url.toString());
					if (entry.redirectURL.length) {
						url = URL(entry.redirectURL);
						continue;
					} else {
						auto data = be["data"].get!BsonBinData().rawData();
						auto mdata = () @trusted { return cast(ubyte[])data; } ();
						scope tmpresult = createMemoryStream(mdata, false);
						callback(tmpresult);
						return;
					}
				}
			} else {
				entry._id = BsonObjectID.generate();
				entry.url = url.toString();
			}

			requestHTTP(url,
				(scope req){
					if (entry.etag.length && mode != CacheMatchMode.never) req.headers["If-None-Match"] = entry.etag;
					if (user.length) addBasicAuth(req, user, password);
				},
				(scope res){
					switch (res.statusCode) {
						default:
							throw new Exception("Unexpected reply for '"~url.toString().black~"': "~httpStatusText(res.statusCode));
						case HTTPStatus.notModified:
							logDiagnostic("Cache HIT: %s", url.toString());
							res.dropBody();
							auto data = be["data"].get!BsonBinData().rawData();
							result = createMemoryStream(cast(ubyte[])data, false);
							break;
						case HTTPStatus.notFound:
							res.dropBody();
							throw new FileNotFoundException("File '"~url.toString().black~"' does not exist.");
						case HTTPStatus.movedPermanently, HTTPStatus.found, HTTPStatus.temporaryRedirect:
							auto pv = "Location" in res.headers;
							enforce(pv !is null, "Server responded with redirect but did not specify the redirect location for "~url.toString());
							logDebug("Redirect to '%s'", *pv);
							if (startsWith((*pv), "http:") || startsWith((*pv), "https:")) {
								url = URL(*pv);
							} else url.localURI = *pv;
							res.dropBody();

							entry.redirectURL = url.toString();
							m_entries.update(["_id": entry._id], entry, UpdateFlags.Upsert);
							break;
						case HTTPStatus.ok:
							auto pet = "ETag" in res.headers;
							if (pet || mode == CacheMatchMode.always) {
								logDiagnostic("Cache MISS: %s", url.toString());
								auto dst = createMemoryOutputStream();
								res.bodyReader.pipe(dst);
								auto rawdata = dst.data;
								if (pet) entry.etag = *pet;
								entry.data = BsonBinData(BsonBinData.Type.Generic, cast(immutable)rawdata);
								m_entries.update(["_id": entry._id], entry, UpdateFlags.Upsert);
								result = createMemoryStream(rawdata, false);
								break;
							}

							logDebug("Response without etag.. not caching: "~url.toString());

							logDiagnostic("Cache MISS (no etag): %s", url.toString());
							handled_uncached = true;
							callback(res.bodyReader.asInterface!InputStream);
							break;
					}
				}
			);

			if (handled_uncached) return;

			if (result) {
				callback(result);
				return;
			}
		}

		throw new Exception("Too many redirects for "~url.toString().black);
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
	@optional string redirectURL;
}

private URLCache s_cache;

void downloadCached(URL url, scope void delegate(scope InputStream str) @safe callback, bool cache_priority = false)
@safe {
	if (!s_cache) s_cache = new URLCache;
	s_cache.get(url, callback, cache_priority);
}

void downloadCached(string url, scope void delegate(scope InputStream str) @safe callback, bool cache_priority = false)
@safe {
	return downloadCached(URL.parse(url), callback, cache_priority);
}

void clearCacheEntry(URL url)
@safe {
	if (!s_cache) s_cache = new URLCache;
	s_cache.clearEntry(url);
}

void clearCacheEntry(string url)
@safe {
	clearCacheEntry(URL(url));
}
