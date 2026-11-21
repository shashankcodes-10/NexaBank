package com.example.bankapp.controller;

import com.example.bankapp.model.Account;
import com.example.bankapp.service.ChatRateLimiter;
import com.example.bankapp.service.ChatService;
import java.util.Map;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api")
public class ChatController {

  private static final int MAX_MESSAGE_LENGTH = 1000;

  private final ChatService chatService;
  private final ChatRateLimiter rateLimiter;

  public ChatController(ChatService chatService, ChatRateLimiter rateLimiter) {
    this.chatService = chatService;
    this.rateLimiter = rateLimiter;
  }

  @PostMapping("/chat")
  public ResponseEntity<Map<String, String>> chat(
      @AuthenticationPrincipal Account account, @RequestBody Map<String, String> request) {
    String message = request.getOrDefault("message", "");
    if (message.length() > MAX_MESSAGE_LENGTH) {
      message = message.substring(0, MAX_MESSAGE_LENGTH);
    }

    ChatRateLimiter.Result permit = rateLimiter.tryAcquire(account.getUsername());
    if (permit == ChatRateLimiter.Result.BUSY) {
      return ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS)
          .body(
              Map.of(
                  "reply", "I'm still working on your previous question. Please wait a moment."));
    }
    if (permit == ChatRateLimiter.Result.TOO_MANY) {
      return ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS)
          .body(
              Map.of(
                  "reply",
                  "You're sending messages too quickly. Please wait a minute and try again."));
    }
    try {
      return ResponseEntity.ok(Map.of("reply", chatService.chat(account, message)));
    } finally {
      rateLimiter.release(account.getUsername());
    }
  }
}
