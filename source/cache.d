module cache;

import vibe.core.log;
import vibe.db.mongo.mongo;
import vibe.http.client;
import vibe.stream.memory;

import std.exception;


class UrlCache {
	private {
		MongoDB m_db;
		MongoCollection m_entries;
	}

	this()
	{
		m_db = connectMongoDB("127.0.0.1");
		m_entries = m_db["urlcache.entries"];
	}

	InputStream get(Url url)
	{
		auto be = m_entries.findOne(["url": url.toString()]);
		CacheEntry entry;
		if( !be.isNull() ) deserializeBson(entry, be);
		else {
			entry._id = BsonObjectID.generate();
			entry.url = url.toString();
		}
		auto res = requestHttp(url, (req){
				if( entry.etag.length ) req.headers["If-None-Match"] = entry.etag;
			});

		if( res.statusCode == HttpStatus.NotModified ){
			auto data = be["data"].get!BsonBinData().rawData();
			auto str = new MemoryStream(cast(ubyte[])data, false);
			return str;
		}
		enforce(res.statusCode == HttpStatus.OK, "Unexpeted reply for '"~url.toString()~"': "~httpStatusText(res.statusCode));

		if( auto pet = "ETag" in res.headers ){
			auto dst = new MemoryOutputStream;
			dst.write(res.bodyReader);
			auto rawdata = dst.data;
			entry.etag = *pet;
			entry.data = BsonBinData(BsonBinData.Type.Generic, cast(immutable)rawdata);
			m_entries.update(["_id": entry._id], entry, UpdateFlags.Upsert);
			return new MemoryStream(rawdata, false);
		}

		logDebug("Response without etag.. not caching: "~url.toString());
		return res.bodyReader;
	}
}

private struct CacheEntry {
	BsonObjectID _id;
	string url;
	string etag;
	BsonBinData data;
}

private UrlCache s_cache;

InputStream downloadCached(Url url)
{
	if( !s_cache ) s_cache = new UrlCache;
	return s_cache.get(url);
}

InputStream downloadCached(string url)
{
	return downloadCached(Url.parse(url));
}