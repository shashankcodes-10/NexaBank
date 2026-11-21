package com.example.bankapp.repository;

import com.example.bankapp.model.Transaction;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;

public interface TransactionRepository extends JpaRepository<Transaction, Long> {

    /** One page of an account's history (sorting comes from the Pageable). */
    Page<Transaction> findByAccountId(Long accountId, Pageable pageable);

    /** The 5 newest transactions, used by the AI assistant's context. */
    List<Transaction> findTop5ByAccountIdOrderByTimestampDescIdDesc(Long accountId);
}
