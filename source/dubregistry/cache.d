/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.cache;

import vibe.core.log;
import vibe.db.mongo.mongo;
import vibe.http.client;
import vibe.stream.memory;

import std.exception;


class UrlCache {
	private {
		MongoClient m_db;
		MongoCollection m_entries;
	}

	this()
	{
		m_db = connectMongoDB("127.0.0.1");
		m_entries = m_db.getCollection("urlcache.entries");
	}

	void get(Url url, scope void delegate(scope InputStream str) callback)
	{
		auto be = m_entries.findOne(["url": url.toString()]);
		CacheEntry entry;
		if( !be.isNull() ) deserializeBson(entry, be);
		else {
			entry._id = BsonObjectID.generate();
			entry.url = url.toString();
		}

		InputStream result;

		requestHttp(url,
			(scope req){
				if( entry.etag.length ) req.headers["If-None-Match"] = entry.etag;
			},
			(scope res){
				if( res.statusCode == HttpStatus.NotModified ){
					auto data = be["data"].get!BsonBinData().rawData();
					result = new MemoryStream(cast(ubyte[])data, false);
					return;
				}

				enforce(res.statusCode == HttpStatus.OK, "Unexpected reply for '"~url.toString()~"': "~httpStatusText(res.statusCode));

				if( auto pet = "ETag" in res.headers ){
					auto dst = new MemoryOutputStream;
					dst.write(res.bodyReader);
					auto rawdata = dst.data;
					entry.etag = *pet;
					entry.data = BsonBinData(BsonBinData.Type.Generic, cast(immutable)rawdata);
					m_entries.update(["_id": entry._id], entry, UpdateFlags.Upsert);
					result = new MemoryStream(rawdata, false);
					return;
				}

				logDebug("Response without etag.. not caching: "~url.toString());

				callback(res.bodyReader);
			}
		);

		if( result ) callback(result);
	}
}

private struct CacheEntry {
	BsonObjectID _id;
	string url;
	string etag;
	BsonBinData data;
}

private UrlCache s_cache;

void downloadCached(Url url, scope void delegate(scope InputStream str) callback)
{
	if( !s_cache ) s_cache = new UrlCache;
	s_cache.get(url, callback);
}

void downloadCached(string url, scope void delegate(scope InputStream str) callback)
{
	return downloadCached(Url.parse(url), callback);
}