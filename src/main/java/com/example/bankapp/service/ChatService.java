package com.example.bankapp.service;

import com.example.bankapp.model.Account;
import com.example.bankapp.model.Transaction;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Service;
import org.springframework.web.client.HttpClientErrorException;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestTemplate;

import java.util.List;
import java.util.Map;

@Service
public class ChatService {

    private static final Logger log = LoggerFactory.getLogger(ChatService.class);

    @Value("${ollama.url}")
    private String ollamaUrl;

    @Value("${ollama.model}")
    private String model;

    private final RestTemplate restTemplate;
    private final AccountService accountService;

    public ChatService(AccountService accountService,
                       @Value("${ollama.connect-timeout-ms:5000}") int connectTimeoutMs,
                       @Value("${ollama.read-timeout-ms:120000}") int readTimeoutMs) {
        this.accountService = accountService;
        // Without timeouts a slow/unreachable Ollama leaves the chat stuck on "Thinking..." forever.
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(connectTimeoutMs);
        factory.setReadTimeout(readTimeoutMs);
        this.restTemplate = new RestTemplate(factory);
    }

    public String chat(Account sessionAccount, String userMessage) {
        if (userMessage == null || userMessage.isBlank()) {
            return "Please type a question and I'll do my best to help.";
        }

        // Use the current database state, not the stale copy cached in the login session.
        Account account = accountService.getFreshAccount(sessionAccount);
        List<Transaction> recent = accountService.getRecentTransactions(account);
        String context = buildContext(account, recent);

        // Small models follow the user turn far better than a long system prompt, so the
        // customer's data is placed in the user message and the system prompt only holds rules.
        String userContent = context + "\n\nMy question: " + userMessage.trim();

        Map<String, Object> request = Map.of(
            "model", model,
            "messages", List.of(
                Map.of("role", "system", "content", SYSTEM_PROMPT),
                Map.of("role", "user", "content", userContent)
            ),
            "stream", false,
            "options", Map.of("temperature", 0.2, "num_predict", 200)
        );

        try {
            Map<?, ?> response = restTemplate.postForObject(ollamaUrl + "/api/chat", request, Map.class);
            if (response != null && response.get("message") instanceof Map<?, ?> message) {
                Object content = message.get("content");
                if (content != null && !content.toString().isBlank()) {
                    return content.toString().trim();
                }
            }
            return "Sorry, I couldn't process that.";
        } catch (HttpClientErrorException.NotFound e) {
            log.error("Ollama model '{}' not found at {}: {}", model, ollamaUrl, e.getResponseBodyAsString());
            return "The AI model '" + model + "' is not installed. Run: ollama pull " + model;
        } catch (ResourceAccessException e) {
            log.error("Could not reach Ollama at {}: {}", ollamaUrl, e.getMessage());
            return "AI assistant is unavailable or took too long to respond. Please make sure Ollama is running and try again.";
        } catch (Exception e) {
            log.error("Ollama chat request failed", e);
            return "AI assistant ran into an error. Please try again.";
        }
    }

    private static final String SYSTEM_PROMPT =
        "You are Nexa AI, the banking assistant for NexaBank. "
        + "The customer's account details are given at the start of their message. "
        + "Answer the question directly in 1-3 short, friendly sentences. "
        + "Do NOT repeat or list the account details back unless asked for them. "
        + "Use only the details provided for names, balances and transactions; never invent or alter them. "
        + "If the details do not contain the answer, say you don't have that information. "
        + "You cannot move money; tell the customer to use the Deposit, Withdraw or Transfer forms on the dashboard.";

    private String buildContext(Account account, List<Transaction> transactions) {
        StringBuilder sb = new StringBuilder();
        sb.append("My account details (the customer's name is ").append(account.getUsername()).append("):");
        sb.append("\n- Name: ").append(account.getUsername());
        sb.append("\n- Current balance: $").append(account.getBalance());
        sb.append("\n- Account ID: ").append(account.getId());

        if (!transactions.isEmpty()) {
            sb.append("\n- Most recent transactions (newest first):");
            int limit = Math.min(transactions.size(), 5); // repository already returns at most 5
            for (int i = 0; i < limit; i++) {
                Transaction t = transactions.get(i);
                sb.append("\n  * ").append(t.getType())
                  .append(": $").append(t.getAmount())
                  .append(" on ").append(t.getTimestamp().toLocalDate());
            }
        } else {
            sb.append("\n- No transactions yet.");
        }

        return sb.toString();
    }
}
