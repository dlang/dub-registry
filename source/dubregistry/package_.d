/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.package_;

class PackageVersion {
	string name;
	string description;
	string homepage;
	string copyright;
	string[] authors;
	string donationUrl;
	string donationDetail;
	string[string] dependencies;
	RepositoryInfo repository;
}

struct RepositoryInfo {
	string type;
	string url;
}