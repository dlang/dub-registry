/**
	Copyright: © 2014 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.notificationcenter;

import dubregistry.scheduler;

import std.datetime;
import std.encoding : sanitize;
import std.string : format;
import userman.db.controller;
import vibe.core.log;
import vibe.mail.smtp;
import vibe.stream.memory;
import vibe.templ.diet;


class NotificationCenter {
	private {
		UserManController m_users;
		PersistentScheduler m_scheduler;
		string[][string][User.ID] m_deprecations;

		enum weeklyDeprecationEventName = "deprecation-warnings";
	}

	this(UserManController users)
	{
		m_users = users;
		m_scheduler = new PersistentScheduler(Path("notification-schedule.json"));
		if (!m_scheduler.existsEvent(weeklyDeprecationEventName))
			m_scheduler.scheduleWeeklyEvent(weeklyDeprecationEventName, SysTime(DateTime(2014, 01, 05, 12, 0, 0), UTC()));
	}

	void startRegularNotifications()
	{
		m_scheduler.setEventHandler(weeklyDeprecationEventName, &onSendDeprecationWarnings);
	}

	void notifyNewErrors(User.ID user_id, string package_name, string branch_or_version, string[] errors)
	{
		auto user = m_users.getUser(user_id);
		if (user.email != "sludwig@rejectedsoftware.com") return;

		auto settings = m_users.settings;

		auto mail = new Mail;
		mail.headers["From"] = format("%s <%s>", settings.serviceName, settings.serviceEmail);
		mail.headers["To"] = format("%s <%s>", user.fullName, user.email); // FIXME: sanitize/escape user.fullName
		mail.headers["Subject"] = format("[%s] Errors in new version %s", package_name, branch_or_version);

		auto dst = new MemoryOutputStream;
		dst.parseDietFile!("dubregistry.mail.package-version-errors.dt", user, settings, package_name, branch_or_version, errors);
		mail.bodyText = cast(string)dst.data;

		sendMail(settings.mailSettings, mail);
	}

	void setDeprecationWarnings(User.ID user_id, string package_name, string[] warnings)
	{
		auto pd = user_id in m_deprecations;
		if (!pd) {
			m_deprecations[user_id] = null;
			pd = user_id in m_deprecations;
		}
		if (warnings.length) (*pd)[package_name] = warnings;
		else if (package_name in *pd) (*pd).remove(package_name);
	}

	private void onSendDeprecationWarnings()
	{
		foreach (uid, deprecations; m_deprecations) {
			User user;
			try {
				user = m_users.getUser(uid);
				if (user.email != "sludwig@rejectedsoftware.com") continue;

				auto settings = m_users.settings;

				auto mail = new Mail;
				mail.headers["From"] = format("%s <%s>", settings.serviceName, settings.serviceEmail);
				mail.headers["To"] = format("%s <%s>", user.fullName, user.email); // FIXME: sanitize/escape user.fullName
				mail.headers["Subject"] = format("Weekly deprecation warnings reminder");

				auto dst = new MemoryOutputStream;
				dst.parseDietFile!("dubregistry.mail.package-deprecation-warnings.dt", user, settings, deprecations);
				mail.bodyText = cast(string)dst.data;

				sendMail(settings.mailSettings, mail);
			} catch (Exception e) {
				logDiagnostic("Failed to send deprecation mail to %s <%s>: %s", user.fullName, user.email, e.msg);
				logDebug("Full error: %s", e.toString().sanitize);
			}
		}
	}
}
