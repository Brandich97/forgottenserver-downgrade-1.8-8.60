// Copyright 2023 The Forgotten Server Authors. All rights reserved.
// Use of this source code is governed by the GPL-2.0 License that can be found in the LICENSE file.

#include "otpch.h"

#include "tasks.h"

#include "configmanager.h"
#include "logger.h"
#include "tools.h"

Task::Task(TaskFunc&& f, const std::string& description, const std::string& extraDescription) :
	description(description), extraDescription(extraDescription), func(std::move(f))
{
}

Task::Task(uint32_t ms, TaskFunc&& f, const std::string& description, const std::string& extraDescription) :
	description(description),
	extraDescription(extraDescription),
	expiration(std::chrono::steady_clock::now() + std::chrono::milliseconds(ms)),
	func(std::move(f))
{
}

bool Task::hasExpired() const
{
	if (expiration == SYSTEM_TIME_ZERO) {
		return false;
	}
	return expiration < std::chrono::steady_clock::now();
}

std::unique_ptr<Task> createTaskWithStats(TaskFunc&& f, const std::string& description, const std::string& extraDescription)
{
	if (g_stats.isEnabled()) {
		return std::make_unique<Task>(std::move(f), description, extraDescription);
	}
	return std::make_unique<Task>(std::move(f), "", "");
}

std::unique_ptr<Task> createTaskWithStats(uint32_t expiration, TaskFunc&& f, const std::string& description, const std::string& extraDescription)
{
	if (g_stats.isEnabled()) {
		return std::make_unique<Task>(expiration, std::move(f), description, extraDescription);
	}
	return std::make_unique<Task>(expiration, std::move(f), "", "");
}

Dispatcher::Dispatcher()
{
	static int id = 0;
	dispatcherId = id++;
}

void Dispatcher::start() noexcept
{
	state.store(THREAD_STATE_RUNNING, std::memory_order_relaxed);
	g_reactor.start();
}

void Dispatcher::stop() noexcept
{
	state.store(THREAD_STATE_CLOSING, std::memory_order_relaxed);
}

void Dispatcher::shutdown() noexcept
{
	state.store(THREAD_STATE_TERMINATED, std::memory_order_relaxed);
	g_reactor.shutdown();
}

void Dispatcher::addTask(std::unique_ptr<Task> task)
{
	if (!task || state.load(std::memory_order_relaxed) == THREAD_STATE_TERMINATED) {
		return;
	}

	auto sharedTask = std::make_shared<std::unique_ptr<Task>>(std::move(task));
	g_reactor.send([this, sharedTask]() { executeTask(std::move(*sharedTask)); });
}

void Dispatcher::executeTask(std::unique_ptr<Task> task)
{
	if (!task || task->hasExpired()) {
		return;
	}

	UPDATE_OTSYS_TIME();

#if defined(STATS_ENABLED) || defined(SLOW_TASK_DETECTION)
	const auto taskStart = std::chrono::steady_clock::now();
#endif

	dispatcherCycle.fetch_add(1, std::memory_order_relaxed);
	totalTasksProcessed.fetch_add(1, std::memory_order_relaxed);
	(*task)();

#ifdef SLOW_TASK_DETECTION
	const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
	    std::chrono::steady_clock::now() - taskStart).count();
	const uint64_t elapsedNs = elapsed > 0 ? static_cast<uint64_t>(elapsed) : 0;

	if (elapsedNs > SLOW_TASK_THRESHOLD_NS && !task->skipSlowDetection) {
		slowTaskCount.fetch_add(1, std::memory_order_relaxed);
		if (getBoolean(ConfigManager::SLOW_TASK_WARNING)) {
			const auto elapsedMs = elapsedNs / 1'000'000;
			if (!task->description.empty()) {
				LOG_WARN(">> Slow task detected: {}ms [{}] {}", elapsedMs, task->description, task->extraDescription);
			} else {
				LOG_WARN(">> Slow task detected: {}ms [unknown]", elapsedMs);
			}
		}
	}
#endif

#ifdef STATS_ENABLED
	if (g_stats.isEnabled() && g_stats.isRunning() && task->trackInStats) {
		const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
		    std::chrono::steady_clock::now() - taskStart).count();
		const uint64_t executionTime = elapsed > 0 ? static_cast<uint64_t>(elapsed) : 0;
		g_stats.addDispatcherStat(0, std::make_unique<Stat>(executionTime, task->description, task->extraDescription));
	}
#endif
}
