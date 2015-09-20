/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.viewutils;

import std.datetime;
import std.string;
import vibe.data.json;

string formatDate(Json date)
{
	return formatDate(date.opt!string);
}

string formatDate(string iso_ext_date)
{
	if (iso_ext_date.length == 0) return "---";
	return formatDate(SysTime.fromISOExtString(iso_ext_date));
}

string formatDate(SysTime st)
{
	return (cast(Date)st).toSimpleString();
}

string formatDateTime(Json dateTime)
{
	return formatDateTime(dateTime.opt!string);
}

string formatDateTime(string iso_ext_date)
{
	if (iso_ext_date.length == 0) return "---";
	return formatDateTime(SysTime.fromISOExtString(iso_ext_date));
}

string formatDateTime(SysTime st)
{
	return st.toSimpleString();
}

string formatFuzzyDate(Json dateTime)
{
	return formatFuzzyDate(dateTime.opt!string);
}

string formatFuzzyDate(string iso_ext_date)
{
	if (iso_ext_date.length == 0) return "---";
	return formatFuzzyDate(SysTime.fromISOExtString(iso_ext_date));
}

string formatFuzzyDate(SysTime st)
{
	auto now = Clock.currTime(UTC());

	// TODO: proper singular forms etc. (probably done together with l8n)
	auto tm = now - st;
	if (tm < dur!"seconds"(0)) return "still going to happen";
	else if (tm < dur!"seconds"(1)) return "just now";
	else if (tm < dur!"minutes"(1)) return "less than a minute ago";
	else if (tm < dur!"minutes"(2)) return "a minute ago";
	else if (tm < dur!"hours"(1)) return format("%s minutes ago", tm.total!"minutes"());
	else if (tm < dur!"hours"(2)) return "an hour ago";
	else if (tm < dur!"days"(1)) return format("%s hours ago", tm.total!"hours"());
	else if (tm < dur!"days"(2)) return "a day ago";
	else if (tm < dur!"weeks"(5)) return format("%s days ago", tm.total!"days"());
	else if (tm < dur!"weeks"(52)) {
		auto m1 = st.month;
		auto m2 = now.month;
		auto months = (now.year - st.year) * 12 + m2 - m1;
		if (months == 1) return "a month ago";
		else return format("%s months ago", months);
	} else if (now.year - st.year <= 1) return "a year ago";
	else return format("%s years ago", now.year - st.year);
}

Json getBestVersion(Json versions)
{
	import dub.semver;
	Json ret;
	foreach (v; versions) {
		auto vstr = v["version"].get!string;
		if (ret.type == Json.Type.undefined) ret = v;
		else {
			auto curvstr = ret["version"].get!string;
			if (curvstr.startsWith("~")) {
				if (vstr == "~master" || !vstr.startsWith("~"))
					ret = v;
			} else if (!vstr.startsWith("~") && compareVersions(vstr, curvstr) > 0) {
				ret = v;
			}
		}
	}
	return ret;
}
