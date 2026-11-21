-- Speeds up the paginated transaction history and the AI assistant's 'latest 5' query.
CREATE INDEX idx_transactions_account_time ON transactions (account_id, `timestamp`);
