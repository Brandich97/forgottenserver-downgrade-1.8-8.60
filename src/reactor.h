// Copyright 2023 The Forgotten Server Authors. All rights reserved.
// Use of this source code is governed by the GPL-2.0 License that can be found in the LICENSE file.

#ifndef FS_REACTOR_H
#define FS_REACTOR_H

#include "enums.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <thread>
#include <unordered_set>
#include <vector>

using ReactorCallback = std::function<void()>;

class TaskReactor
{
public:
	void start() noexcept;
	void send(ReactorCallback&& callback);
	void send(uint32_t expirationTime, ReactorCallback&& callback);
	uint32_t schedule(uint32_t delay, ReactorCallback&& callback);
	void cancel(uint32_t taskIdentifier);

	void runLoop();
	void runOnce();
	void shutdown() noexcept;

	[[nodiscard]] bool isReactorThread() const noexcept;
	[[nodiscard]] ThreadState getState() const noexcept;

private:
	struct Task
	{
		std::chrono::steady_clock::time_point fireAt;
		std::chrono::steady_clock::time_point deadline;
		uint32_t identifier = 0;
		uint64_t sequence = 0;
		ReactorCallback function;

		[[nodiscard]] bool hasExpired(std::chrono::steady_clock::time_point now) const noexcept;
	};

	void drainInbox(std::vector<Task>& readyTasks);
	void drainReadyTasks(std::vector<Task>& readyTasks);
	void executeReadyTasks(std::vector<Task>& readyTasks);
	void waitForWork();
	static bool taskComesAfter(const Task& lhs, const Task& rhs) noexcept;

	std::mutex mutex;
	std::condition_variable conditionVariable;

	std::vector<Task> sendInbox;
	std::vector<Task> scheduleInbox;
	std::vector<uint32_t> cancelInbox;

	std::unordered_set<uint32_t> cancelled;
	std::unordered_set<uint32_t> activeIdentifiers;
	std::vector<Task> taskHeap;

	std::atomic<uint32_t> nextIdentifier{0};
	std::atomic<uint64_t> nextSequence{0};
	std::atomic<ThreadState> threadState{THREAD_STATE_TERMINATED};
	std::thread::id reactorThreadId;
};

extern TaskReactor g_reactor;

#endif // FS_REACTOR_H
