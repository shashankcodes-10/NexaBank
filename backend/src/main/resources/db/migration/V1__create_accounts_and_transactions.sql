-- Baseline schema (matches the JPA entities Account and Transaction).
CREATE TABLE IF NOT EXISTS accounts (
    id       BIGINT         NOT NULL AUTO_INCREMENT,
    username VARCHAR(255)   NOT NULL,
    password VARCHAR(255)   NOT NULL,
    balance  DECIMAL(19, 2) NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uk_accounts_username UNIQUE (username)
) ENGINE = InnoDB;

CREATE TABLE IF NOT EXISTS transactions (
    id         BIGINT         NOT NULL AUTO_INCREMENT,
    amount     DECIMAL(19, 2) NOT NULL,
    type       VARCHAR(255)   NOT NULL,
    `timestamp` DATETIME(6)   NOT NULL,
    account_id BIGINT,
    PRIMARY KEY (id),
    CONSTRAINT fk_transactions_account FOREIGN KEY (account_id) REFERENCES accounts (id)
) ENGINE = InnoDB;
