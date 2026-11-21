package com.example.bankapp.service;

import com.example.bankapp.model.Account;
import com.example.bankapp.model.Transaction;
import com.example.bankapp.repository.AccountRepository;
import com.example.bankapp.repository.TransactionRepository;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Sort;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.core.userdetails.UsernameNotFoundException;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDateTime;
import java.util.List;

@Service
public class AccountService implements UserDetailsService {

    public static final int TRANSACTIONS_PAGE_SIZE = 10;
    private static final java.util.regex.Pattern USERNAME_PATTERN = java.util.regex.Pattern.compile("^[a-z0-9._-]{3,30}$");
    private static final String INVALID_AMOUNT = "Please enter a valid amount greater than zero.";

    private final AccountRepository accountRepository;
    private final TransactionRepository transactionRepository;
    private final PasswordEncoder passwordEncoder;

    public AccountService(AccountRepository accountRepository,
                          TransactionRepository transactionRepository,
                          PasswordEncoder passwordEncoder) {
        this.accountRepository = accountRepository;
        this.transactionRepository = transactionRepository;
        this.passwordEncoder = passwordEncoder;
    }

    @Override
    public UserDetails loadUserByUsername(String username) throws UsernameNotFoundException {
        return accountRepository.findByUsernameIgnoreCase(username == null ? "" : username.trim())
                .orElseThrow(() -> new UsernameNotFoundException("User not found: " + username));
    }

    /** Returns null on success, otherwise a message explaining what is wrong. */
    public String registerAccount(String rawUsername, String password) {
        String username = rawUsername == null ? "" : rawUsername.trim().toLowerCase();
        if (username.isEmpty()) {
            return "Username is required.";
        }
        if (!USERNAME_PATTERN.matcher(username).matches()) {
            return "Username must be 3-30 characters: letters, numbers, dot, underscore or hyphen.";
        }
        if (password == null || password.isBlank()) {
            return "Password is required.";
        }
        if (password.length() < 4) {
            return "Password must be at least 4 characters.";
        }
        if (password.length() > 72) { // BCrypt only uses the first 72 bytes
            return "Password must be at most 72 characters.";
        }
        if (accountRepository.findByUsernameIgnoreCase(username).isPresent()) {
            return "Username already taken. Please choose another.";
        }
        try {
            accountRepository.save(new Account(username, passwordEncoder.encode(password)));
        } catch (org.springframework.dao.DataIntegrityViolationException e) {
            // two people registering the same name at the same moment
            return "Username already taken. Please choose another.";
        }
        return null;
    }

    /**
     * Always reads the account from the database. The Account stored in the HTTP session
     * (the security principal) is only a snapshot from login time, so its balance goes
     * stale after any deposit, withdrawal or incoming transfer.
     */
    @Transactional(readOnly = true)
    public Account getFreshAccount(Account sessionAccount) {
        return accountRepository.findById(sessionAccount.getId())
                .orElseThrow(() -> new UsernameNotFoundException("User not found: " + sessionAccount.getUsername()));
    }

    /** Returns null on success, otherwise an error message. */
    @Transactional
    public String deposit(Account sessionAccount, BigDecimal rawAmount) {
        BigDecimal amount = normalize(rawAmount);
        if (amount == null) {
            return INVALID_AMOUNT;
        }
        Account account = lock(sessionAccount.getId());
        account.setBalance(account.getBalance().add(amount));
        accountRepository.save(account);

        transactionRepository.save(new Transaction(amount, "Deposit", LocalDateTime.now(), account));
        return null;
    }

    /** Returns null on success, otherwise an error message. */
    @Transactional
    public String withdraw(Account sessionAccount, BigDecimal rawAmount) {
        BigDecimal amount = normalize(rawAmount);
        if (amount == null) {
            return INVALID_AMOUNT;
        }
        Account account = lock(sessionAccount.getId());
        if (account.getBalance().compareTo(amount) < 0) {
            return "Insufficient funds.";
        }
        account.setBalance(account.getBalance().subtract(amount));
        accountRepository.save(account);

        transactionRepository.save(new Transaction(amount, "Withdrawal", LocalDateTime.now(), account));
        return null;
    }

    /** Returns null on success, otherwise an error message. */
    @Transactional
    public String transferAmount(Account sessionFrom, String toUsername, BigDecimal rawAmount) {
        BigDecimal amount = normalize(rawAmount);
        if (amount == null) {
            return INVALID_AMOUNT;
        }
        if (toUsername == null || toUsername.isBlank()) {
            return "Recipient username is required.";
        }
        String recipient = toUsername.trim();
        if (sessionFrom.getUsername().equalsIgnoreCase(recipient)) {
            return "Cannot transfer to yourself.";
        }
        Account toLookup = accountRepository.findByUsernameIgnoreCase(recipient).orElse(null);
        if (toLookup == null) {
            return "Recipient not found.";
        }

        // Lock both rows in a fixed (ascending id) order so two opposite transfers cannot deadlock.
        Long fromId = sessionFrom.getId();
        Long toId = toLookup.getId();
        Account from;
        Account to;
        if (fromId < toId) {
            from = lock(fromId);
            to = lock(toId);
        } else {
            to = lock(toId);
            from = lock(fromId);
        }

        if (from.getBalance().compareTo(amount) < 0) {
            return "Insufficient funds.";
        }

        from.setBalance(from.getBalance().subtract(amount));
        to.setBalance(to.getBalance().add(amount));
        accountRepository.save(from);
        accountRepository.save(to);

        LocalDateTime now = LocalDateTime.now();
        transactionRepository.save(new Transaction(amount, "Transfer Out", now, from));
        transactionRepository.save(new Transaction(amount, "Transfer In", now, to));

        return null; // null means success
    }

    /** One page of history, newest first. Out-of-range page numbers are clamped to the last page. */
    @Transactional(readOnly = true)
    public Page<Transaction> getTransactionPage(Account account, int page) {
        Sort newestFirst = Sort.by(Sort.Direction.DESC, "timestamp").and(Sort.by(Sort.Direction.DESC, "id"));
        int safePage = Math.max(page, 0);
        Page<Transaction> result = transactionRepository.findByAccountId(
                account.getId(), PageRequest.of(safePage, TRANSACTIONS_PAGE_SIZE, newestFirst));
        if (result.getTotalPages() > 0 && safePage >= result.getTotalPages()) {
            result = transactionRepository.findByAccountId(
                    account.getId(), PageRequest.of(result.getTotalPages() - 1, TRANSACTIONS_PAGE_SIZE, newestFirst));
        }
        return result;
    }

    /** The 5 newest transactions (for the AI assistant). */
    @Transactional(readOnly = true)
    public List<Transaction> getRecentTransactions(Account account) {
        return transactionRepository.findTop5ByAccountIdOrderByTimestampDescIdDesc(account.getId());
    }

    private Account lock(Long id) {
        return accountRepository.findByIdForUpdate(id)
                .orElseThrow(() -> new IllegalStateException("Account not found: " + id));
    }

    /** Rounds to 2 decimals (the column scale) and rejects null, zero and negative amounts. */
    private BigDecimal normalize(BigDecimal amount) {
        if (amount == null) {
            return null;
        }
        BigDecimal rounded = amount.setScale(2, RoundingMode.HALF_UP);
        return rounded.signum() > 0 ? rounded : null;
    }
}
