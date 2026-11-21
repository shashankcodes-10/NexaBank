
package com.example.bankapp.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.example.bankapp.model.Account;
import com.example.bankapp.model.Transaction;
import com.example.bankapp.repository.AccountRepository;
import com.example.bankapp.repository.TransactionRepository;
import java.math.BigDecimal;
import java.util.Optional;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.crypto.password.PasswordEncoder;

@ExtendWith(MockitoExtension.class)
class AccountServiceTest {

  @Mock private AccountRepository accountRepository;
  @Mock private TransactionRepository transactionRepository;
  @Mock private PasswordEncoder passwordEncoder;

  private AccountService accountService;

  @BeforeEach
  void setUp() {
    accountService =
        new AccountService(accountRepository, transactionRepository, passwordEncoder);
  }

  @Test
  void registerAccountRejectsBlankUsernameWithoutDatabaseWrite() {
    String result = accountService.registerAccount("  ", "password");

    assertEquals("Username is required.", result);
    verify(accountRepository, never()).save(any(Account.class));
  }

  @Test
  void registerAccountRejectsInvalidUsernameWithoutDatabaseWrite() {
    String result = accountService.registerAccount("Invalid Username!", "password");

    assertEquals(
        "Username must be 3-30 characters: letters, numbers, dot, underscore or hyphen.",
        result);
    verify(accountRepository, never()).save(any(Account.class));
  }

  @Test
  void registerAccountRejectsShortPasswordWithoutDatabaseWrite() {
    String result = accountService.registerAccount("shashank", "abc");

    assertEquals("Password must be at least 4 characters.", result);
    verify(accountRepository, never()).save(any(Account.class));
  }

  @Test
  void registerAccountRejectsPasswordLongerThanBcryptLimit() {
    String result = accountService.registerAccount("shashank", "x".repeat(73));

    assertEquals("Password must be at most 72 characters.", result);
    verify(accountRepository, never()).save(any(Account.class));
  }

  @Test
  void registerAccountRejectsExistingUsername() {
    when(accountRepository.findByUsernameIgnoreCase("shashank"))
        .thenReturn(Optional.of(new Account("shashank", "encoded")));

    String result = accountService.registerAccount(" Shashank ", "password");

    assertEquals("Username already taken. Please choose another.", result);
    verify(accountRepository, never()).save(any(Account.class));
  }

  @Test
  void registerAccountNormalizesUsernameAndEncodesPassword() {
    when(accountRepository.findByUsernameIgnoreCase("shashank")).thenReturn(Optional.empty());
    when(passwordEncoder.encode("password")).thenReturn("encoded-password");

    String result = accountService.registerAccount(" Shashank ", "password");

    assertNull(result);
    verify(accountRepository)
        .save(
            org.mockito.ArgumentMatchers.argThat(
                account ->
                    "shashank".equals(account.getUsername())
                        && "encoded-password".equals(account.getPassword())));
  }

  @Test
  void depositRejectsNullZeroAndNegativeAmounts() {
    Account account = account(1L, "alice", "100.00");

    assertEquals(
        "Please enter a valid amount greater than zero.",
        accountService.deposit(account, null));
    assertEquals(
        "Please enter a valid amount greater than zero.",
        accountService.deposit(account, new BigDecimal("0.00")));
    assertEquals(
        "Please enter a valid amount greater than zero.",
        accountService.deposit(account, new BigDecimal("-5.00")));

    verify(accountRepository, never()).findByIdForUpdate(any());
  }

  @Test
  void depositAddsAmountAndRoundsToTwoDecimalPlaces() {
    Account account = account(1L, "alice", "100.00");
    when(accountRepository.findByIdForUpdate(1L)).thenReturn(Optional.of(account));

    String result = accountService.deposit(account, new BigDecimal("10.126"));

    assertNull(result);
    assertEquals(new BigDecimal("110.13"), account.getBalance());
    verify(accountRepository).save(account);
    verify(transactionRepository).save(any(Transaction.class));
  }

  @Test
  void withdrawRejectsInsufficientFunds() {
    Account account = account(1L, "alice", "20.00");
    when(accountRepository.findByIdForUpdate(1L)).thenReturn(Optional.of(account));

    String result = accountService.withdraw(account, new BigDecimal("25.00"));

    assertEquals("Insufficient funds.", result);
    assertEquals(new BigDecimal("20.00"), account.getBalance());
    verify(accountRepository, never()).save(any(Account.class));
    verify(transactionRepository, never()).save(any(Transaction.class));
  }

  @Test
  void withdrawSubtractsAmountWhenFundsAreSufficient() {
    Account account = account(1L, "alice", "100.00");
    when(accountRepository.findByIdForUpdate(1L)).thenReturn(Optional.of(account));

    String result = accountService.withdraw(account, new BigDecimal("35.00"));

    assertNull(result);
    assertEquals(new BigDecimal("65.00"), account.getBalance());
    verify(accountRepository).save(account);
    verify(transactionRepository).save(any(Transaction.class));
  }

  @Test
  void transferRejectsTransferToSameAccount() {
    Account sender = account(1L, "alice", "100.00");

    String result = accountService.transferAmount(sender, " ALICE ", new BigDecimal("10.00"));

    assertEquals("Cannot transfer to yourself.", result);
    verify(accountRepository, never()).findByUsernameIgnoreCase(any());
    verify(accountRepository, never()).findByIdForUpdate(any());
  }

  @Test
  void transferRejectsUnknownRecipient() {
    Account sender = account(1L, "alice", "100.00");
    when(accountRepository.findByUsernameIgnoreCase("nobody")).thenReturn(Optional.empty());

    String result = accountService.transferAmount(sender, "nobody", new BigDecimal("10.00"));

    assertEquals("Recipient not found.", result);
    verify(accountRepository, never()).findByIdForUpdate(any());
  }

  @Test
  void transferRejectsInsufficientFunds() {
    Account sender = account(1L, "alice", "10.00");
    Account recipient = account(2L, "bob", "5.00");
    when(accountRepository.findByUsernameIgnoreCase("bob")).thenReturn(Optional.of(recipient));
    when(accountRepository.findByIdForUpdate(1L)).thenReturn(Optional.of(sender));
    when(accountRepository.findByIdForUpdate(2L)).thenReturn(Optional.of(recipient));

    String result = accountService.transferAmount(sender, "bob", new BigDecimal("20.00"));

    assertEquals("Insufficient funds.", result);
    assertEquals(new BigDecimal("10.00"), sender.getBalance());
    assertEquals(new BigDecimal("5.00"), recipient.getBalance());
    verify(accountRepository, never()).save(any(Account.class));
    verify(transactionRepository, never()).save(any(Transaction.class));
  }

  @Test
  void transferMovesMoneyAndRecordsBothSides() {
    Account sender = account(1L, "alice", "100.00");
    Account recipient = account(2L, "bob", "25.00");
    when(accountRepository.findByUsernameIgnoreCase("bob")).thenReturn(Optional.of(recipient));
    when(accountRepository.findByIdForUpdate(1L)).thenReturn(Optional.of(sender));
    when(accountRepository.findByIdForUpdate(2L)).thenReturn(Optional.of(recipient));

    String result = accountService.transferAmount(sender, "bob", new BigDecimal("30.00"));

    assertNull(result);
    assertEquals(new BigDecimal("70.00"), sender.getBalance());
    assertEquals(new BigDecimal("55.00"), recipient.getBalance());
    verify(accountRepository).save(sender);
    verify(accountRepository).save(recipient);
    verify(transactionRepository, org.mockito.Mockito.times(2))
        .save(any(Transaction.class));
  }

  private Account account(Long id, String username, String balance) {
    Account account = new Account(username, "encoded-password");
    account.setId(id);
    account.setBalance(new BigDecimal(balance));
    return account;
  }
}
