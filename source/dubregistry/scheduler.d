/**
	Copyright: © 2014 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.scheduler;

import std.datetime;
import vibe.core.core;
import vibe.core.file;
import vibe.data.json;


/** Persistent event scheduler for low-frequency events.

	Any outstanding events that should have fired during a down-time will be
	triggered once the corresponding handler has been registered. Repeated events
	will only be fired once, though. So after a down-time of three days, a daily event
	will only be triggered a single time instead of three times.
*/
class PersistentScheduler {
	enum EventKind {
		singular,
		periodic,
		daily,
		weekly,
		monthly,
		yearly
	}

	struct Event {
		EventKind kind;
		SysTime next;
		Duration period;
		Timer timer;
		void delegate() handler;
	}

	private {
		Path m_persistentFilePath;
		Event[string] m_events;
		bool m_deferUpdates;
	}

	this(Path persistent_file)
	{
		m_persistentFilePath = persistent_file;

		if (existsFile(persistent_file)) {
			m_deferUpdates = true;
			auto data = readJsonFile(persistent_file);
			foreach (string name, desc; data) {
				auto tp = desc.kind.get!string.to!EventKind;
				auto next = SysTime.fromISOExtString(desc.next.get!string);
				final switch (tp) with (EventKind) {
					case singular: scheduleEvent(name, next); break;
					case periodic: scheduleEvent(name, next, desc.period.get!long.usecs); break;
					case daily: scheduleDailyEvent(name, next); break;
					case weekly: scheduleWeeklyEvent(name, next); break;
					case monthly: scheduleMonthlyEvent(name, next); break;
					case yearly: scheduleYearlyEvent(name, next); break;
				}
			}
			m_deferUpdates = false;
		}
	}

	void scheduleEvent(string name, SysTime time) { scheduleEvent(name, EventKind.singular, time); }
	void scheduleEvent(string name, SysTime first_time, Duration repeat_period) { scheduleEvent(name, EventKind.periodic, first_time, repeat_period); }
	void scheduleDailyEvent(string name, SysTime first_time) { scheduleEvent(name, EventKind.daily, first_time); }
	void scheduleWeeklyEvent(string name, SysTime first_time) { scheduleEvent(name, EventKind.weekly, first_time); }
	void scheduleMonthlyEvent(string name, SysTime first_time) { scheduleEvent(name, EventKind.monthly, first_time); }
	void scheduleYearlyEvent(string name, SysTime first_time) { scheduleEvent(name, EventKind.yearly, first_time); }
	
	void scheduleEvent(string name, EventKind kind, SysTime first_time, Duration repeat_period = 0.seconds)
	{
		auto now = Clock.currTime(UTC());
		if (name !in m_events) {
			auto timer = createTimer({ onTimerFired(name); });
			auto evt = Event(kind, first_time, repeat_period, timer, null);
			m_events[name] = evt; // direct assignment yields "Internal error: backend\cgcs.c 351"
		}

		auto pevt = name in m_events;

		pevt.kind = kind;
		pevt.next = first_time;
		pevt.period = repeat_period;

		writePersistentFile();

		if (pevt.handler) {
			if (pevt.next <= now) fireEvent(name, now);
			else pevt.timer.rearm(pevt.next - now);
		}
	}
	
	void deleteEvent(string name)
	{
		if (auto pevt = name in m_events) {
			m_events.remove(name);
			writePersistentFile();
		}
	}

	bool existsEvent(string name)
	const {
		return (name in m_events) !is null;
	}

	void setEventHandler(string name, void delegate() handler)
	{
		auto pevt = name in m_events;
		assert(pevt !is null, "Non-existent event: "~name);
		pevt.handler = handler;
		auto now = Clock.currTime(UTC());
		if (handler !is null) {
			if (pevt.next <= now) fireEvent(name, now);
			else pevt.timer.rearm(pevt.next - now);
		}
	}

	private void onTimerFired(string name)
	{
		auto pevt = name in m_events;
		if (!pevt || !pevt.handler) return;

		auto now = Clock.currTime(UTC());

		if (pevt.next <= now) fireEvent(name, now);
		else pevt.timer.rearm(pevt.next - now);
	}

	private void fireEvent(string name, SysTime now)
	{
		auto pevt = name in m_events;
		assert(pevt.next <= now);
		assert(pevt.handler !is null);
		auto handler = pevt.handler;

		final switch (pevt.kind) with (EventKind) {
			case singular: break;
			case periodic:
				do pevt.next += pevt.period;
				while (pevt.next <= now);
				break;
			case daily:
				do pevt.next.dayOfGregorianCal = pevt.next.dayOfGregorianCal + 1;
				while (pevt.next <= now);
				break;
			case weekly:
				do pevt.next.dayOfGregorianCal = pevt.next.dayOfGregorianCal + 7;
				while (pevt.next <= now);
				break;
			case monthly:
				// FIXME: retain the original day of month after an overflow happened!
				do pevt.next.add!"months"(1, AllowDayOverflow.no);
				while (pevt.next <= now);
				break;
			case yearly:
				// FIXME: retain the original day of month after an overflow happened!
				do pevt.next.add!"years"(1, AllowDayOverflow.no);
				while (pevt.next <= now);
				break;
		}

		if (pevt.kind == EventKind.singular) m_events.remove(name);
		else pevt.timer.rearm(pevt.next - now);

		writePersistentFile();

		handler();
	}

	private void writePersistentFile()
	{
		if (m_deferUpdates) return;

		Json jevents = Json.emptyObject;
		foreach (name, desc; m_events) {
			auto jdesc = Json.emptyObject;
			jdesc.kind = desc.kind.to!string;
			jdesc.next = desc.next.toISOExtString();
			if (desc.kind == EventKind.periodic)
				jdesc.period = desc.period.total!"usecs";
			jevents[name] = jdesc;
		}
		m_persistentFilePath.writeJsonFile(jevents);
	}
}

private Json readJsonFile(Path path)
{
	import vibe.stream.operations;

	auto fil = openFile(path);
	scope (exit) fil.close();
	return parseJsonString(fil.readAllUTF8());
}

private void writeJsonFile(Path path, Json data)
{
	auto fil = openFile(path, FileMode.createTrunc);
	scope (exit) fil.close();
	fil.writePrettyJsonString(data);
}
