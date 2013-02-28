/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.viewutils;

import std.datetime;
import std.string;
import vibe.data.json;

string formatDate(string iso_ext_date)
{
	auto date = SysTime.fromISOExtString(iso_ext_date);
	return (cast(Date)date).toSimpleString();
}

string formatDate(Json date)
{
	if( date.type == Json.Type.Undefined ) return "---";
	return formatDate(date.get!string);
}