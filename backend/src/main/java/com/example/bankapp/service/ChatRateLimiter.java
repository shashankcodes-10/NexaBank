package com.example.bankapp.service;

import java.util.ArrayDeque;
import java.util.Deque;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import org.springframework.stereotype.Component;

/**
 * Per-user guard for the AI chat: at most one request in flight and at most MAX_PER_WINDOW requests
 * per minute. Each LLM call can take a long time on a CPU, so without this a single user could tie
 * up the assistant for everyone.
 */
@Component
public class ChatRateLimiter {

  public enum Result {
    OK,
    BUSY,
    TOO_MANY
  }

  private static final int MAX_PER_WINDOW = 10;
  private static final long WINDOW_MS = 60_000;

  private static final class UserState {
    final Deque<Long> recent = new ArrayDeque<>();
    boolean busy;
  }

  private final Map<String, UserState> states = new ConcurrentHashMap<>();

  public Result tryAcquire(String username) {
    UserState state = states.computeIfAbsent(username, k -> new UserState());
    synchronized (state) {
      long now = System.currentTimeMillis();
      while (!state.recent.isEmpty() && now - state.recent.peekFirst() > WINDOW_MS) {
        state.recent.pollFirst();
      }
      if (state.busy) {
        return Result.BUSY;
      }
      if (state.recent.size() >= MAX_PER_WINDOW) {
        return Result.TOO_MANY;
      }
      state.busy = true;
      state.recent.addLast(now);
      return Result.OK;
    }
  }

  public void release(String username) {
    UserState state = states.get(username);
    if (state != null) {
      synchronized (state) {
        state.busy = false;
      }
    }
  }
}
