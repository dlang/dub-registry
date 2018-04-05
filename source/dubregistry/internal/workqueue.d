/**
	Copyright: © 2017 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.internal.workqueue;

import std.algorithm.searching : canFind, countUntil;
import std.algorithm.mutation : swap;
import std.datetime : Clock, SysTime, UTC, msecs, hours;
import std.encoding : sanitize;
import vibe.core.core;
import vibe.core.log;
import vibe.core.sync;
import vibe.utils.array : FixedRingBuffer;

final class PackageWorkQueue {
@safe:

	private {
		FixedRingBuffer!string m_queue;
		string m_current;
		Task m_task;
		TaskMutex m_mutex;
		TaskCondition m_condition;
		void delegate(string) m_handler;
		SysTime m_lastSignOfLifeOfUpdateTask;
	}

	this(void delegate(string) @safe handler)
	{
		m_handler = handler;
		m_queue.capacity = 10000;
		m_mutex = new TaskMutex;
		m_condition = new TaskCondition(m_mutex);
		m_task = runTask(&processQueue);
	}

	bool isPending(string pack_name)
	{
		return getPosition(pack_name) >= 0;
	}

	sizediff_t getPosition(string pack_name)
	{
		if (m_current == pack_name) return 0;
		synchronized (m_mutex) {
			auto idx = m_queue[].countUntil(pack_name);
			return idx >= 0 ? idx + 1 : -1;
		}
	}

	void putFront(string pack_name)
	{
		import std.algorithm.comparison : min;
		synchronized (m_mutex) {
			// naive protection against spamming the queue
			if (!m_queue[0 .. min(10, $)].canFind(pack_name))
				m_queue.putFront(pack_name);
		}

		nudgeWorker;
	}

	void put(string pack_name)
	{
		synchronized (m_mutex) {
			if (!m_queue[].canFind(pack_name))
				m_queue.put(pack_name);
		}

		nudgeWorker;
	}

	private void nudgeWorker()
	{
		// watchdog for update task
		if (m_task.running && Clock.currTime(UTC()) - m_lastSignOfLifeOfUpdateTask > 2.hours) {
			logError("Update task has hung. Trying to interrupt.");
			() @trusted { m_task.interrupt(); } ();
		}

		if (!m_task.running)
			m_task = runTask(&processQueue);
		m_condition.notifyAll();
	}

	private void processQueue()
	{
		scope (exit) logWarn("Update task was killed!");
		while (true) {
			m_lastSignOfLifeOfUpdateTask = Clock.currTime(UTC());
			logDiagnostic("Getting new package to be updated...");
			string pack;
			synchronized (m_mutex) {
				while (m_queue.empty) {
					logDiagnostic("Waiting for package to be updated...");
					m_condition.wait();
				}
				pack = m_queue.front;
				m_queue.popFront();
				m_current = pack;
			}
			scope(exit) m_current = null;
			logDiagnostic("Processing package %s.", pack);
			try m_handler(pack);
			catch (Exception e) {
				logWarn("Failed to handle package %s: %s", pack, e.msg);
				() @trusted { logDiagnostic("Full error: %s", e.toString().sanitize); } ();
			}
		}
	}
}

unittest {
	size_t done = false;
	string expected;
	size_t cnt = 0;

	void handler(string pack)
	{
		assert(pack == expected);
		cnt++;
		sleep(100.msecs);
	}

	void test()
	{
		auto q = new PackageWorkQueue(&handler);
		assert(!q.isPending("foo"));
		assert(!q.isPending("bar"));
		assert(q.getPosition("foo") < 0);
		expected = "foo";
		q.put("foo");
		q.put("bar");
		assert(q.isPending("foo"));
		assert(q.isPending("bar"));
		assert(q.getPosition("bar") == q.getPosition("foo") + 1);
		yield();
		assert(q.getPosition("foo") == 0);
		assert(q.getPosition("bar") == 1);
		expected = "bar";
		sleep(300.msecs);
		assert(!q.isPending("foo"));
		assert(!q.isPending("bar"));
		assert(cnt == 2);
		done = true;
		exitEventLoop();
	}

	runTask(&test);
	runEventLoop();
	assert(done, "Test was skipped!?");
}
