
package com.example.bankapp.service;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class ChatRateLimiterTest {

  @Test
  void allowsOneInFlightRequestPerUser() {
    ChatRateLimiter limiter = new ChatRateLimiter();

    assertEquals(ChatRateLimiter.Result.OK, limiter.tryAcquire("alice"));
    assertEquals(ChatRateLimiter.Result.BUSY, limiter.tryAcquire("alice"));

    limiter.release("alice");

    assertEquals(ChatRateLimiter.Result.OK, limiter.tryAcquire("alice"));
  }

  @Test
  void limitsUserToTenRequestsPerMinute() {
    ChatRateLimiter limiter = new ChatRateLimiter();

    for (int i = 0; i < 10; i++) {
      assertEquals(ChatRateLimiter.Result.OK, limiter.tryAcquire("alice"));
      limiter.release("alice");
    }

    assertEquals(ChatRateLimiter.Result.TOO_MANY, limiter.tryAcquire("alice"));
  }

  @Test
  void tracksLimitsSeparatelyForEachUser() {
    ChatRateLimiter limiter = new ChatRateLimiter();

    assertEquals(ChatRateLimiter.Result.OK, limiter.tryAcquire("alice"));
    assertEquals(ChatRateLimiter.Result.OK, limiter.tryAcquire("bob"));
  }
}
