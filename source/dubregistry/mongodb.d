module dubregistry.mongodb;

import vibe.core.log;
import vibe.db.mongo.client : MongoClient;
import vibe.db.mongo.mongo : connectMongoDB;
import vibe.db.mongo.settings : MongoClientSettings, MongoAuthMechanism, parseMongoDBUrl;
import std.exception : enforce;
import std.typecons : Nullable;

string databaseName = "vpmreg";
private Nullable!MongoClientSettings _mongoSettings;

@safe:

MongoClientSettings mongoSettings() {
	if (_mongoSettings.isNull) {
		import std.process : environment;
		auto mongodbURI = environment.get("MONGODB_URI", environment.get("MONGO_URI", "mongodb://127.0.0.1"));
		logInfo("Found mongodbURI: %s", mongodbURI);
		MongoClientSettings settings;
		enforce(parseMongoDBUrl(settings, mongodbURI),
				"Could not parse connection string (check MONGODB_URI or MONGO_URI): "
				~ mongodbURI);
		settings.authMechanism = MongoAuthMechanism.scramSHA1;
		if (settings.database.length > 0)
			databaseName = settings.database;
		settings.safe = true;
		_mongoSettings = settings;
	}
	return _mongoSettings.get;
}

MongoClient getMongoClient()
{
	return connectMongoDB(mongoSettings);
}
