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