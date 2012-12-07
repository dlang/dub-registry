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
		string etag;
		auto be = m_entries.findOne(["url": url.toString()]);
		if( !be.isNull() ) etag = be.etag.get!string();
		auto res = requestHttp(url, (req){
				if( etag.length ) req.headers["If-None-Match"] = etag;
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
			auto data = BsonBinData(BsonBinData.Type.Generic, cast(immutable)rawdata);
			m_entries.update(["_id": be._id], ["$set": ["etag": Bson(*pet), "data": Bson(data)]]);
			return new MemoryStream(rawdata, false);
		}

		logDebug("Response without etag.. not caching: "~url.toString());
		return res.bodyReader;
	}
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