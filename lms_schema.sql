-- =====================================================================
--  Library Management System (LMS) — MySQL 8.0 schema
--  University demonstration project: tables, keys, constraints,
--  views, triggers, stored procedures, sample data, demo queries.
-- =====================================================================

DROP DATABASE IF EXISTS lms;
CREATE DATABASE lms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE lms;

-- ---------------------------------------------------------------------
-- 1. LOOKUP / MASTER TABLES
-- ---------------------------------------------------------------------

CREATE TABLE publisher (
    publisher_id   INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name           VARCHAR(150) NOT NULL UNIQUE,
    address        VARCHAR(255),
    phone          VARCHAR(20)
) ENGINE=InnoDB;

CREATE TABLE author (
    author_id      INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    full_name      VARCHAR(150) NOT NULL,
    nationality    VARCHAR(60)
) ENGINE=InnoDB;

CREATE TABLE category (
    category_id    INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name           VARCHAR(100) NOT NULL UNIQUE,
    parent_id      INT UNSIGNED NULL,               -- self-reference: sub-categories
    CONSTRAINT fk_category_parent FOREIGN KEY (parent_id)
        REFERENCES category(category_id) ON DELETE SET NULL
) ENGINE=InnoDB;

CREATE TABLE member_type (                          -- borrowing rules per member type
    member_type_id TINYINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name           VARCHAR(30) NOT NULL UNIQUE,     -- Student, Faculty, Staff
    max_books      TINYINT UNSIGNED NOT NULL,
    loan_days      TINYINT UNSIGNED NOT NULL,
    fine_per_day   DECIMAL(6,2) NOT NULL
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 2. CATALOG: BOOK (title-level) vs BOOK_COPY (physical item)
-- ---------------------------------------------------------------------

CREATE TABLE book (
    book_id        INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    isbn           VARCHAR(17) NOT NULL UNIQUE,
    title          VARCHAR(255) NOT NULL,
    edition        VARCHAR(20),
    publish_year   YEAR,
    language       VARCHAR(30) DEFAULT 'English',
    publisher_id   INT UNSIGNED,
    category_id    INT UNSIGNED,
    CONSTRAINT fk_book_publisher FOREIGN KEY (publisher_id)
        REFERENCES publisher(publisher_id) ON DELETE SET NULL,
    CONSTRAINT fk_book_category  FOREIGN KEY (category_id)
        REFERENCES category(category_id) ON DELETE SET NULL,
    FULLTEXT INDEX ft_book_title (title)
) ENGINE=InnoDB;

-- Many-to-many: a book has many authors, an author writes many books
CREATE TABLE book_author (
    book_id        INT UNSIGNED NOT NULL,
    author_id      INT UNSIGNED NOT NULL,
    author_order   TINYINT UNSIGNED NOT NULL DEFAULT 1,
    PRIMARY KEY (book_id, author_id),
    CONSTRAINT fk_ba_book   FOREIGN KEY (book_id)   REFERENCES book(book_id)     ON DELETE CASCADE,
    CONSTRAINT fk_ba_author FOREIGN KEY (author_id) REFERENCES author(author_id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE book_copy (
    copy_id        INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    book_id        INT UNSIGNED NOT NULL,
    barcode        VARCHAR(30) NOT NULL UNIQUE,
    shelf_location VARCHAR(20),
    status         ENUM('AVAILABLE','ISSUED','RESERVED','LOST','DAMAGED')
                   NOT NULL DEFAULT 'AVAILABLE',
    acquired_on    DATE NOT NULL DEFAULT (CURRENT_DATE),
    price          DECIMAL(8,2),
    CONSTRAINT fk_copy_book FOREIGN KEY (book_id) REFERENCES book(book_id) ON DELETE RESTRICT,
    INDEX idx_copy_status (book_id, status)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 3. PEOPLE
-- ---------------------------------------------------------------------

CREATE TABLE member (
    member_id      INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    card_no        VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(150) NOT NULL,
    email          VARCHAR(150) NOT NULL UNIQUE,
    phone          VARCHAR(20),
    department     VARCHAR(80),
    member_type_id TINYINT UNSIGNED NOT NULL,
    joined_on      DATE NOT NULL DEFAULT (CURRENT_DATE),
    expires_on     DATE NOT NULL,
    is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT fk_member_type FOREIGN KEY (member_type_id) REFERENCES member_type(member_type_id),
    CONSTRAINT chk_member_dates CHECK (expires_on > joined_on)
) ENGINE=InnoDB;

CREATE TABLE staff (
    staff_id       INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    full_name      VARCHAR(150) NOT NULL,
    email          VARCHAR(150) NOT NULL UNIQUE,
    role           ENUM('ADMIN','LIBRARIAN','ASSISTANT') NOT NULL DEFAULT 'LIBRARIAN',
    password_hash  CHAR(64) NOT NULL                 -- SHA-256 hex (demo only)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 4. TRANSACTIONS: LOAN, RESERVATION, FINE
-- ---------------------------------------------------------------------

CREATE TABLE loan (
    loan_id        INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    copy_id        INT UNSIGNED NOT NULL,
    member_id      INT UNSIGNED NOT NULL,
    issued_by      INT UNSIGNED NOT NULL,
    issue_date     DATE NOT NULL DEFAULT (CURRENT_DATE),
    due_date       DATE NOT NULL,
    return_date    DATE NULL,                        -- NULL = still out
    renew_count    TINYINT UNSIGNED NOT NULL DEFAULT 0,
    CONSTRAINT fk_loan_copy   FOREIGN KEY (copy_id)   REFERENCES book_copy(copy_id),
    CONSTRAINT fk_loan_member FOREIGN KEY (member_id) REFERENCES member(member_id),
    CONSTRAINT fk_loan_staff  FOREIGN KEY (issued_by) REFERENCES staff(staff_id),
    CONSTRAINT chk_loan_due    CHECK (due_date >= issue_date),
    CONSTRAINT chk_loan_return CHECK (return_date IS NULL OR return_date >= issue_date),
    CONSTRAINT chk_loan_renew  CHECK (renew_count <= 2),
    INDEX idx_loan_open (member_id, return_date),
    INDEX idx_loan_due  (due_date, return_date)
) ENGINE=InnoDB;

CREATE TABLE reservation (
    reservation_id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    book_id        INT UNSIGNED NOT NULL,            -- reserve the TITLE, not a copy
    member_id      INT UNSIGNED NOT NULL,
    reserved_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status         ENUM('WAITING','READY','FULFILLED','CANCELLED','EXPIRED')
                   NOT NULL DEFAULT 'WAITING',
    CONSTRAINT fk_res_book   FOREIGN KEY (book_id)   REFERENCES book(book_id),
    CONSTRAINT fk_res_member FOREIGN KEY (member_id) REFERENCES member(member_id),
    INDEX idx_res_queue (book_id, status, reserved_at)
) ENGINE=InnoDB;

CREATE TABLE fine (
    fine_id        INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    loan_id        INT UNSIGNED NOT NULL UNIQUE,     -- one fine per loan (1:1)
    amount         DECIMAL(8,2) NOT NULL CHECK (amount >= 0),
    paid           BOOLEAN NOT NULL DEFAULT FALSE,
    paid_on        DATE NULL,
    CONSTRAINT fk_fine_loan FOREIGN KEY (loan_id) REFERENCES loan(loan_id)
) ENGINE=InnoDB;

-- Audit trail (filled by trigger)
CREATE TABLE copy_status_log (
    log_id         BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    copy_id        INT UNSIGNED NOT NULL,
    old_status     VARCHAR(10),
    new_status     VARCHAR(10),
    changed_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 5. TRIGGERS
-- ---------------------------------------------------------------------
DELIMITER $$

-- Log every status change of a physical copy
CREATE TRIGGER trg_copy_status_audit
AFTER UPDATE ON book_copy FOR EACH ROW
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO copy_status_log (copy_id, old_status, new_status)
        VALUES (NEW.copy_id, OLD.status, NEW.status);
    END IF;
END$$

-- Block issuing unless the copy is AVAILABLE, or RESERVED for this same member
CREATE TRIGGER trg_loan_before_insert
BEFORE INSERT ON loan FOR EACH ROW
BEGIN
    DECLARE v_status VARCHAR(10);
    DECLARE v_book INT UNSIGNED;
    SELECT status, book_id INTO v_status, v_book FROM book_copy WHERE copy_id = NEW.copy_id;
    IF v_status = 'RESERVED' THEN
        IF NOT EXISTS (SELECT 1 FROM reservation
                        WHERE book_id = v_book AND member_id = NEW.member_id
                          AND status = 'READY') THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Copy is reserved for another member';
        END IF;
    ELSEIF v_status <> 'AVAILABLE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Copy is not available';
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 6. STORED PROCEDURES (business logic inside the DB, in a transaction)
-- ---------------------------------------------------------------------

CREATE PROCEDURE sp_issue_book(IN p_copy_id INT UNSIGNED,
                               IN p_member_id INT UNSIGNED,
                               IN p_staff_id INT UNSIGNED)
BEGIN
    DECLARE v_max TINYINT; DECLARE v_days TINYINT;
    DECLARE v_open INT;    DECLARE v_active BOOLEAN; DECLARE v_exp DATE;
    DECLARE v_unpaid INT;  DECLARE v_lock INT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN ROLLBACK; RESIGNAL; END;

    START TRANSACTION;

    SELECT mt.max_books, mt.loan_days, m.is_active, m.expires_on
      INTO v_max, v_days, v_active, v_exp
      FROM member m JOIN member_type mt USING (member_type_id)
     WHERE m.member_id = p_member_id;

    IF v_active = FALSE OR v_exp < CURRENT_DATE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Membership inactive or expired';
    END IF;

    SELECT COUNT(*) INTO v_open FROM loan
     WHERE member_id = p_member_id AND return_date IS NULL;
    IF v_open >= v_max THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Borrow limit reached';
    END IF;

    SELECT COUNT(*) INTO v_unpaid FROM fine f JOIN loan l USING (loan_id)
     WHERE l.member_id = p_member_id AND f.paid = FALSE;
    IF v_unpaid > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Member has unpaid fines';
    END IF;

    -- lock the copy row so two librarians cannot issue it simultaneously
    SELECT copy_id INTO v_lock FROM book_copy WHERE copy_id = p_copy_id FOR UPDATE;

    INSERT INTO loan (copy_id, member_id, issued_by, issue_date, due_date)
    VALUES (p_copy_id, p_member_id, p_staff_id, CURRENT_DATE,
            DATE_ADD(CURRENT_DATE, INTERVAL v_days DAY));

    UPDATE book_copy SET status = 'ISSUED' WHERE copy_id = p_copy_id;

    -- close the member's READY reservation for this title, if any
    UPDATE reservation r JOIN book_copy c ON c.book_id = r.book_id
       SET r.status = 'FULFILLED'
     WHERE c.copy_id = p_copy_id AND r.member_id = p_member_id AND r.status = 'READY';

    COMMIT;
END$$

CREATE PROCEDURE sp_return_book(IN p_loan_id INT UNSIGNED, IN p_return_date DATE)
BEGIN
    DECLARE v_due DATE; DECLARE v_copy INT UNSIGNED; DECLARE v_rate DECIMAL(6,2);
    DECLARE v_late INT; DECLARE v_book INT UNSIGNED; DECLARE v_res INT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN ROLLBACK; RESIGNAL; END;

    START TRANSACTION;

    SELECT l.due_date, l.copy_id, mt.fine_per_day, bc.book_id
      INTO v_due, v_copy, v_rate, v_book
      FROM loan l
      JOIN member m       ON m.member_id = l.member_id
      JOIN member_type mt ON mt.member_type_id = m.member_type_id
      JOIN book_copy bc   ON bc.copy_id = l.copy_id
     WHERE l.loan_id = p_loan_id AND l.return_date IS NULL
       FOR UPDATE;

    IF v_copy IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan not found or already returned';
    END IF;

    UPDATE loan SET return_date = p_return_date WHERE loan_id = p_loan_id;

    SET v_late = DATEDIFF(p_return_date, v_due);
    IF v_late > 0 THEN
        INSERT INTO fine (loan_id, amount) VALUES (p_loan_id, v_late * v_rate);
    END IF;

    -- If someone is waiting for this title, hold the copy for them
    SELECT reservation_id INTO v_res FROM reservation
     WHERE book_id = v_book AND status = 'WAITING'
     ORDER BY reserved_at LIMIT 1;

    IF v_res IS NOT NULL THEN
        UPDATE reservation SET status = 'READY' WHERE reservation_id = v_res;
        UPDATE book_copy   SET status = 'RESERVED' WHERE copy_id = v_copy;
    ELSE
        UPDATE book_copy   SET status = 'AVAILABLE' WHERE copy_id = v_copy;
    END IF;

    COMMIT;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- 7. VIEWS (reporting)
-- ---------------------------------------------------------------------

CREATE VIEW v_book_availability AS
SELECT b.book_id, b.isbn, b.title,
       COUNT(c.copy_id)                         AS total_copies,
       SUM(c.status = 'AVAILABLE')              AS available_copies
FROM book b LEFT JOIN book_copy c ON c.book_id = b.book_id
GROUP BY b.book_id, b.isbn, b.title;

CREATE VIEW v_overdue_loans AS
SELECT l.loan_id, m.card_no, m.full_name, b.title, c.barcode,
       l.due_date, DATEDIFF(CURRENT_DATE, l.due_date)                   AS days_late,
       DATEDIFF(CURRENT_DATE, l.due_date) * mt.fine_per_day             AS fine_so_far
FROM loan l
JOIN member m       ON m.member_id = l.member_id
JOIN member_type mt ON mt.member_type_id = m.member_type_id
JOIN book_copy c    ON c.copy_id = l.copy_id
JOIN book b         ON b.book_id = c.book_id
WHERE l.return_date IS NULL AND l.due_date < CURRENT_DATE;

-- ---------------------------------------------------------------------
-- 8. SAMPLE DATA
-- ---------------------------------------------------------------------

INSERT INTO member_type (name, max_books, loan_days, fine_per_day) VALUES
 ('Student', 3, 14, 5.00), ('Faculty', 10, 60, 2.00), ('Staff', 5, 30, 3.00);

INSERT INTO publisher (name, address) VALUES
 ('Pearson', 'London'), ('O''Reilly Media', 'Sebastopol, CA'), ('McGraw-Hill', 'New York');

INSERT INTO category (name, parent_id) VALUES
 ('Computer Science', NULL), ('Mathematics', NULL);
INSERT INTO category (name, parent_id) VALUES
 ('Databases', 1), ('Algorithms', 1), ('Discrete Math', 2);

INSERT INTO author (full_name, nationality) VALUES
 ('Abraham Silberschatz','USA'), ('Henry F. Korth','USA'), ('S. Sudarshan','India'),
 ('Thomas H. Cormen','USA'), ('Charles E. Leiserson','USA'), ('Kenneth H. Rosen','USA'),
 ('Alan Beaulieu','USA');

INSERT INTO book (isbn, title, edition, publish_year, publisher_id, category_id) VALUES
 ('978-0078022159','Database System Concepts','7th',2019,3,3),
 ('978-0262046305','Introduction to Algorithms','4th',2022,1,4),
 ('978-1259676512','Discrete Mathematics and Its Applications','8th',2018,3,5),
 ('978-1492057611','Learning SQL','3rd',2020,2,3);

INSERT INTO book_author VALUES (1,1,1),(1,2,2),(1,3,3),(2,4,1),(2,5,2),(3,6,1),(4,7,1);

INSERT INTO book_copy (book_id, barcode, shelf_location, price) VALUES
 (1,'LIB-0001','CS-A1',4500),(1,'LIB-0002','CS-A1',4500),
 (2,'LIB-0003','CS-B2',6000),
 (3,'LIB-0004','MA-C1',3800),(3,'LIB-0005','MA-C1',3800),
 (4,'LIB-0006','CS-A2',2500);

INSERT INTO member (card_no, full_name, email, department, member_type_id, joined_on, expires_on) VALUES
 ('STU-1001','Rahim Uddin','rahim@uni.edu','CSE',1,'2025-01-10','2029-01-10'),
 ('STU-1002','Karima Akter','karima@uni.edu','EEE',1,'2025-01-10','2029-01-10'),
 ('FAC-2001','Dr. Hasan Ali','hasan@uni.edu','CSE',2,'2020-06-01','2030-06-01');

INSERT INTO staff (full_name, email, role, password_hash) VALUES
 ('Nusrat Jahan','nusrat@uni.edu','LIBRARIAN', SHA2('demo123',256));

-- Demo transactions through the procedures
CALL sp_issue_book(1, 1, 1);        -- Rahim borrows Database System Concepts (copy 1)
CALL sp_issue_book(3, 2, 1);        -- Karima borrows Intro to Algorithms (only copy)
INSERT INTO reservation (book_id, member_id) VALUES (2, 3);   -- Dr. Hasan waits for it

-- Back-date one loan so it shows as overdue
UPDATE loan SET issue_date = CURRENT_DATE - INTERVAL 30 DAY,
                due_date   = CURRENT_DATE - INTERVAL 16 DAY
 WHERE loan_id = 1;

-- ---------------------------------------------------------------------
-- 9. DEMO QUERIES (run these in class)
-- ---------------------------------------------------------------------
-- SELECT * FROM v_book_availability;
-- SELECT * FROM v_overdue_loans;
-- CALL sp_return_book(2, CURRENT_DATE);     -- copy goes RESERVED for Dr. Hasan
-- CALL sp_return_book(1, CURRENT_DATE);     -- creates a 16-day late fine
-- SELECT * FROM fine;  SELECT * FROM copy_status_log;
-- CALL sp_issue_book(3, 2, 1);              -- fails: reserved for another member (trigger)
-- CALL sp_issue_book(3, 3, 1);              -- works: Dr. Hasan collects his reservation
-- CALL sp_issue_book(2, 1, 1);              -- fails: Rahim has an unpaid fine
--
-- Full-text search:
-- SELECT title FROM book WHERE MATCH(title) AGAINST('database');
--
-- Top borrowers (GROUP BY + ORDER BY):
-- SELECT m.full_name, COUNT(*) AS loans FROM loan l JOIN member m USING(member_id)
--  GROUP BY m.member_id ORDER BY loans DESC;
--
-- Books with their authors (GROUP_CONCAT over M:N):
-- SELECT b.title, GROUP_CONCAT(a.full_name ORDER BY ba.author_order SEPARATOR ', ') AS authors
--   FROM book b JOIN book_author ba USING(book_id) JOIN author a USING(author_id)
--  GROUP BY b.book_id;
--
-- Most borrowed category (window function, MySQL 8):
-- SELECT cat, loans, RANK() OVER (ORDER BY loans DESC) AS rnk FROM (
--   SELECT c.name AS cat, COUNT(l.loan_id) AS loans FROM category c
--   LEFT JOIN book b ON b.category_id=c.category_id
--   LEFT JOIN book_copy bc ON bc.book_id=b.book_id
--   LEFT JOIN loan l ON l.copy_id=bc.copy_id GROUP BY c.category_id) t;
